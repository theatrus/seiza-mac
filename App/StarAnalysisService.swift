import Foundation

/// The seam between the analysis service and the native detector, so tests
/// can count and script native calls.
protocol StarAnalysisNativeClient: Sendable {
    var coreVersion: String { get }
    func detectPath(_ path: String, optionsJSON: String) throws -> String
}

struct SeizaStarAnalysisClient: StarAnalysisNativeClient {
    var coreVersion: String { SeizaCore.version }

    func detectPath(_ path: String, optionsJSON: String) throws -> String {
        var errorPointer: UnsafeMutablePointer<CChar>?
        let response = path.withCString { pathPointer in
            optionsJSON.withCString { optionsPointer in
                seiza_stars_detect_path_json(
                    pathPointer, optionsPointer, &errorPointer)
            }
        }
        guard let response else {
            throw StarAnalysisError.core(
                CalibrationService.takeOwnedError(&errorPointer, fallback:
                    "The Seiza native core could not analyze stars in the image."))
        }
        defer { seiza_string_free(response) }
        CalibrationService.discardError(&errorPointer)
        return String(cString: response)
    }
}

/// Solve-independent measured-star analysis with a bounded LRU cache, one
/// native detector job at a time, in-flight coalescing, and file-stamp
/// freshness: a source that changes while it is being analyzed is never
/// cached or returned.
actor StarAnalysisService {
    static let shared = StarAnalysisService()

    private struct CacheKey: Hashable, Sendable {
        var path: String
        var length: Int64
        var modifiedUnixNanoseconds: Int64
        var coreVersion: String
        var optionsJSON: String
    }

    private struct SourceStamp: Equatable, Sendable {
        var path: String
        var length: Int64
        var modifiedUnixNanoseconds: Int64
    }

    private final class InflightEntry: @unchecked Sendable {
        var task: Task<StarAnalysisResult, Error>!
        var waiterCount = 1
        var nativeStarted = false
        var abandoned = false
    }

    private let client: StarAnalysisNativeClient
    private let cacheCapacity: Int
    private let nativeGate = AsyncGate()
    private var cache: [CacheKey: StarAnalysisResult] = [:]
    private var cacheOrder: [CacheKey] = []
    private var inflight: [CacheKey: InflightEntry] = [:]

    init(
        client: StarAnalysisNativeClient = SeizaStarAnalysisClient(),
        cacheCapacity: Int = 4
    ) {
        precondition(cacheCapacity > 0, "Cache capacity must be positive.")
        self.client = client
        self.cacheCapacity = cacheCapacity
    }

    func analyze(
        path: String,
        options: StarAnalysisOptions? = nil
    ) async throws -> StarAnalysisResult {
        try Task.checkCancellation()
        let stamp = try readStamp(path)
        try ensureSupported(stamp.path)
        let resolvedOptions = options ?? StarAnalysisOptions()
        let optionsJSON = try resolvedOptions.jsonString()
        let coreVersion = normalizedCoreVersion()
        let key = CacheKey(
            path: stamp.path,
            length: stamp.length,
            modifiedUnixNanoseconds: stamp.modifiedUnixNanoseconds,
            coreVersion: coreVersion,
            optionsJSON: optionsJSON)

        if let hit = lookupCache(key) {
            try Task.checkCancellation()
            try ensureUnchanged(stamp)
            return hit
        }

        let entry: InflightEntry
        if let existing = inflight[key] {
            existing.waiterCount += 1
            entry = existing
        } else {
            entry = startOperation(
                key: key,
                stamp: stamp,
                optionsJSON: optionsJSON,
                requestedTriangleAngle: resolvedOptions.triangleAngleDegrees)
        }
        defer { releaseWaiter(key: key, entry: entry) }

        let result = try await awaitCancellable(entry.task)
        try Task.checkCancellation()
        try ensureUnchanged(stamp)
        return result
    }

    // MARK: Operation lifecycle

    private func startOperation(
        key: CacheKey,
        stamp: SourceStamp,
        optionsJSON: String,
        requestedTriangleAngle: Double?
    ) -> InflightEntry {
        let entry = InflightEntry()
        inflight[key] = entry
        let client = client
        entry.task = Task {
            await self.nativeGate.acquire()
            defer { self.nativeGate.release() }
            // Linearize abandon-versus-grant: a queued job every waiter has
            // left is dropped here, before the native detector starts.
            guard self.markNativeStarted(key: key, entry: entry) else {
                throw CancellationError()
            }
            try Self.check(stamp)
            let path = stamp.path
            let json = try await runBlocking {
                try client.detectPath(path, optionsJSON: optionsJSON)
            }
            let result = try StarAnalysisContract.decode(
                json, requestedTriangleAngle: requestedTriangleAngle)
            // A source that changed mid-analysis is discarded, not cached.
            try Self.check(stamp)
            self.finishOperation(key: key, entry: entry, result: result)
            return result
        }
        return entry
    }

    private func markNativeStarted(key: CacheKey, entry: InflightEntry) -> Bool {
        guard !entry.abandoned else { return false }
        entry.nativeStarted = true
        return true
    }

    private func finishOperation(
        key: CacheKey, entry: InflightEntry, result: StarAnalysisResult
    ) {
        addToCache(key, result)
        if inflight[key] === entry {
            inflight[key] = nil
        }
    }

    private func releaseWaiter(key: CacheKey, entry: InflightEntry) {
        entry.waiterCount -= 1
        guard entry.waiterCount <= 0, !entry.nativeStarted else { return }
        // Every waiter left before the native detector started: drop the
        // queued job so it never delays the next image.
        entry.abandoned = true
        if inflight[key] === entry {
            inflight[key] = nil
        }
        entry.task.cancel()
    }

    /// Awaits an unstructured task but returns promptly with a cancellation
    /// error when the caller is cancelled, without cancelling the shared
    /// operation itself. A detached bridge forwards the eventual result; a
    /// one-shot latch makes cancellation and completion race safely.
    private nonisolated func awaitCancellable(
        _ task: Task<StarAnalysisResult, Error>
    ) async throws -> StarAnalysisResult {
        let latch = OneShotLatch()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard latch.store(continuation) else { return }
                Task.detached {
                    let outcome: Result<StarAnalysisResult, Error>
                    do {
                        outcome = .success(try await task.value)
                    } catch {
                        outcome = .failure(error)
                    }
                    latch.resume(with: outcome)
                }
            }
        } onCancel: {
            latch.cancel()
        }
    }

    private final class OneShotLatch: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<StarAnalysisResult, Error>?
        private var finished = false
        private var cancelledEarly = false

        /// Returns false when cancellation already happened; the
        /// continuation is then resumed with a cancellation error in place.
        func store(
            _ continuation: CheckedContinuation<StarAnalysisResult, Error>
        ) -> Bool {
            lock.lock()
            if cancelledEarly || finished {
                finished = true
                lock.unlock()
                continuation.resume(throwing: CancellationError())
                return false
            }
            self.continuation = continuation
            lock.unlock()
            return true
        }

        func resume(with outcome: Result<StarAnalysisResult, Error>) {
            lock.lock()
            guard !finished, let continuation else {
                finished = true
                lock.unlock()
                return
            }
            finished = true
            self.continuation = nil
            lock.unlock()
            continuation.resume(with: outcome)
        }

        func cancel() {
            lock.lock()
            if finished {
                lock.unlock()
                return
            }
            guard let continuation else {
                cancelledEarly = true
                lock.unlock()
                return
            }
            finished = true
            self.continuation = nil
            lock.unlock()
            continuation.resume(throwing: CancellationError())
        }
    }

    // MARK: Cache

    private func lookupCache(_ key: CacheKey) -> StarAnalysisResult? {
        guard let hit = cache[key] else { return nil }
        if let index = cacheOrder.firstIndex(of: key) {
            cacheOrder.remove(at: index)
        }
        cacheOrder.insert(key, at: 0)
        return hit
    }

    private func addToCache(_ key: CacheKey, _ result: StarAnalysisResult) {
        if cache[key] != nil, let index = cacheOrder.firstIndex(of: key) {
            cacheOrder.remove(at: index)
        }
        cache[key] = result
        cacheOrder.insert(key, at: 0)
        while cacheOrder.count > cacheCapacity, let evicted = cacheOrder.popLast() {
            cache[evicted] = nil
        }
    }

    // MARK: Source identity

    private func readStamp(_ path: String) throws -> SourceStamp {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw StarAnalysisError.missingSource(path)
        }
        let fullPath = LiveStackPath.normalize(trimmed)
        guard let snapshot = StackFileIdentity.snapshot(forPath: fullPath) else {
            throw StarAnalysisError.missingSource(fullPath)
        }
        return SourceStamp(
            path: fullPath,
            length: snapshot.length,
            modifiedUnixNanoseconds: snapshot.modifiedUnixNanoseconds)
    }

    private func ensureSupported(_ path: String) throws {
        let supported = ["fits", "fit", "fts", "xisf"]
        guard supported.contains(
            URL(fileURLWithPath: path).pathExtension.lowercased())
        else {
            throw StarAnalysisError.unsupportedSource
        }
    }

    private func ensureUnchanged(_ stamp: SourceStamp) throws {
        try Self.check(stamp)
    }

    private static func check(_ stamp: SourceStamp) throws {
        guard let snapshot = StackFileIdentity.snapshot(forPath: stamp.path),
            snapshot.length == stamp.length,
            snapshot.modifiedUnixNanoseconds == stamp.modifiedUnixNanoseconds
        else {
            throw StarAnalysisError.sourceChanged(stamp.path)
        }
    }

    private func normalizedCoreVersion() -> String {
        let version = client.coreVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        return version.isEmpty ? "unknown" : version
    }
}
