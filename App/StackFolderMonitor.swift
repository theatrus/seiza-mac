import Foundation

// MARK: - Candidates and dispositions

/// One stable revision of a watched file, offered for ingestion. `revision`
/// identifies the file contents at the moment of the offer; any change on
/// disk makes the candidate stale.
struct StackFileCandidate: Equatable, Sendable {
    var path: String
    var attempt: Int
    var revision: Int
    var length: Int64
    var lastWriteUnixNanoseconds: Int64
    var fileIdentity: String?
}

/// How ingestion disposed of a candidate. The first three are durable
/// terminals; `unreadable` reopens on identity change or after the maximum
/// retry delay; `retryableFailure` schedules a backed-off retry.
enum StackFileDispositionKind: Sendable {
    case accepted
    case rejected
    case ignored
    case unreadable
    case retryableFailure
}

/// The `(device, inode)` identity of a file, stable across renames, plus
/// the stat-derived facts every subsystem records about a file.
enum StackFileIdentity {
    struct Snapshot: Equatable, Sendable {
        var identity: String
        var length: Int64
        var modifiedUnixNanoseconds: Int64
    }

    static func snapshot(forPath path: String) -> Snapshot? {
        var status = stat()
        guard stat(path, &status) == 0 else { return nil }
        return Snapshot(
            identity: String(
                format: "%llX:%llX", UInt64(status.st_dev), UInt64(status.st_ino)),
            length: Int64(status.st_size),
            modifiedUnixNanoseconds: Int64(status.st_mtimespec.tv_sec) * 1_000_000_000
                + Int64(status.st_mtimespec.tv_nsec))
    }

    static func identity(forPath path: String) -> String? {
        snapshot(forPath: path)?.identity
    }
}

// MARK: - Tracker

/// The stability and disposition state machine for every path seen in the
/// capture folder. Thread-safe; the monitor's scan loop and the coordinator
/// both talk to it.
final class StackFileCandidateTracker: @unchecked Sendable {
    struct Configuration: Sendable {
        var minimumStableDuration: TimeInterval = 2
        var initialRetryDelay: TimeInterval = 2
        var maximumRetryDelay: TimeInterval = 120
    }

    private struct Entry {
        /// The on-disk path with its original case; the dictionary key is
        /// its case-folded form.
        var path = ""
        var length: Int64 = -1
        var lastWriteUnixNanoseconds: Int64 = 0
        var fileIdentity: String?
        var observations = 0
        var stableSince: Date?
        var revision = 0
        var attempt = 1
        var failedAttempts = 0
        var terminal: StackFileDispositionKind?
        var processedAt: Date?
        var nextRetryAt: Date?
        var awaitingDisposition = false
        var reserved = false
        var seenThisScan = false
    }

    private let lock = NSLock()
    private let configuration: Configuration
    private var entries: [String: Entry] = [:]
    private var terminalIdentities: Set<String> = []
    private var cachedPendingCount = 0

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    private static func key(_ path: String) -> String {
        LiveStackPath.normalize(path).lowercased()
    }

    private func entryForUpdate(path: String) -> (key: String, entry: Entry) {
        let normalized = LiveStackPath.normalize(path)
        let key = normalized.lowercased()
        var entry = entries[key] ?? Entry()
        if entry.path.isEmpty {
            entry.path = normalized
        }
        return (key, entry)
    }

    // MARK: Observation

    func observe(
        path: String,
        length: Int64,
        lastWriteUnixNanoseconds: Int64,
        fileIdentity: String?,
        now: Date
    ) {
        lock.withLock {
            let (key, existing) = entryForUpdate(path: path)
            var entry = existing
            entry.seenThisScan = true

            if entry.terminal == .unreadable {
                let identityChanged = fileIdentity != nil
                    && entry.fileIdentity != nil
                    && fileIdentity != entry.fileIdentity
                let identityAppeared = entry.fileIdentity == nil && fileIdentity != nil
                let delayElapsed = entry.processedAt.map {
                    now.timeIntervalSince($0) >= configuration.maximumRetryDelay
                } ?? true
                if identityChanged || identityAppeared {
                    entry.terminal = nil
                    entry.attempt = 1
                    entry.failedAttempts = 0
                    entry.observations = 0
                    entry.stableSince = nil
                    entry.nextRetryAt = nil
                } else if delayElapsed {
                    entry.terminal = nil
                    entry.observations = 0
                    entry.stableSince = nil
                    entry.nextRetryAt = nil
                }
            }

            let changed = entry.length != length
                || entry.lastWriteUnixNanoseconds != lastWriteUnixNanoseconds
                || (fileIdentity != nil && entry.fileIdentity != nil
                    && entry.fileIdentity != fileIdentity)
            if changed {
                entry.revision += 1
                entry.observations = 1
                entry.stableSince = now
                entry.awaitingDisposition = false
            } else {
                entry.observations += 1
                if entry.stableSince == nil {
                    entry.stableSince = now
                }
            }
            entry.length = length
            entry.lastWriteUnixNanoseconds = lastWriteUnixNanoseconds
            if let fileIdentity {
                entry.fileIdentity = fileIdentity
            }
            entries[key] = entry
        }
    }

    /// Every stable, unreserved, non-terminal entry whose retry delay has
    /// elapsed. A path whose identity is already terminal elsewhere (a
    /// rename or hard-link alias) becomes terminal-ignored instead. Also
    /// refreshes the cached pending count for status reporting.
    func dueCandidates(now: Date) -> [StackFileCandidate] {
        lock.withLock {
            var due: [StackFileCandidate] = []
            for (key, var entry) in entries {
                guard entry.terminal == nil, !entry.reserved,
                    !entry.awaitingDisposition
                else { continue }
                if let identity = entry.fileIdentity,
                    terminalIdentities.contains(identity) {
                    entry.terminal = .ignored
                    entries[key] = entry
                    continue
                }
                guard entry.observations >= 2,
                    let stableSince = entry.stableSince,
                    now.timeIntervalSince(stableSince)
                        >= configuration.minimumStableDuration
                else { continue }
                if let nextRetryAt = entry.nextRetryAt, now < nextRetryAt {
                    continue
                }
                entry.awaitingDisposition = true
                entries[key] = entry
                due.append(StackFileCandidate(
                    path: entry.path,
                    attempt: entry.attempt,
                    revision: entry.revision,
                    length: entry.length,
                    lastWriteUnixNanoseconds: entry.lastWriteUnixNanoseconds,
                    fileIdentity: entry.fileIdentity))
            }
            cachedPendingCount = entries.values.filter { entry in
                entry.terminal == nil && !entry.reserved && entry.seenThisScan
            }.count
            return due.sorted { $0.path < $1.path }
        }
    }

    func isCandidateCurrent(_ candidate: StackFileCandidate) -> Bool {
        lock.withLock {
            guard let entry = entries[Self.key(candidate.path)] else { return false }
            return entry.revision == candidate.revision && !entry.reserved
        }
    }

    func complete(
        _ candidate: StackFileCandidate,
        disposition: StackFileDispositionKind,
        now: Date
    ) {
        lock.withLock {
            let key = Self.key(candidate.path)
            guard var entry = entries[key] else { return }
            entry.awaitingDisposition = false
            guard entry.revision == candidate.revision else {
                entries[key] = entry
                return
            }
            switch disposition {
            case .accepted, .rejected, .ignored:
                entry.terminal = disposition
                entry.processedAt = now
                if let identity = entry.fileIdentity {
                    terminalIdentities.insert(identity)
                }
            case .unreadable:
                entry.terminal = .unreadable
                entry.processedAt = now
            case .retryableFailure:
                entry.failedAttempts += 1
                entry.attempt += 1
                let backoff = min(
                    configuration.initialRetryDelay
                        * pow(2, Double(entry.failedAttempts - 1)),
                    configuration.maximumRetryDelay)
                entry.nextRetryAt = now.addingTimeInterval(backoff)
            }
            entries[key] = entry
        }
    }

    /// Reopens an unreadable terminal immediately, and clears the backoff of
    /// a pending retry. Durable terminals stay terminal.
    func retryNow(_ path: String) {
        lock.withLock {
            let key = Self.key(path)
            guard var entry = entries[key] else { return }
            switch entry.terminal {
            case .unreadable:
                entry.terminal = nil
                entry.failedAttempts = 0
                entry.observations = 0
                entry.stableSince = nil
                entry.nextRetryAt = nil
            case .accepted, .rejected, .ignored:
                return
            case nil, .retryableFailure:
                entry.awaitingDisposition = false
                entry.nextRetryAt = nil
            }
            entries[key] = entry
        }
    }

    /// Clears every pending offer so candidates that were yielded but never
    /// completed (a stopped stream, a cancelled ingestion loop) are offered
    /// again by the next scan.
    func clearPendingDispositions() {
        lock.withLock {
            for (key, var entry) in entries
            where entry.terminal == nil && entry.awaitingDisposition {
                entry.awaitingDisposition = false
                entries[key] = entry
            }
        }
    }

    // MARK: Reservations

    func reserve(_ path: String) {
        lock.withLock {
            let (key, existing) = entryForUpdate(path: path)
            var entry = existing
            entry.reserved = true
            entry.awaitingDisposition = false
            entries[key] = entry
        }
    }

    func releaseReservation(_ path: String) {
        lock.withLock {
            let key = Self.key(path)
            guard var entry = entries[key] else { return }
            entry.reserved = false
            entries[key] = entry
        }
    }

    func commitReservation(_ path: String, now: Date) {
        lock.withLock {
            let (key, existing) = entryForUpdate(path: path)
            var entry = existing
            entry.reserved = false
            entry.terminal = .accepted
            entry.processedAt = now
            if let identity = entry.fileIdentity
                ?? StackFileIdentity.identity(forPath: entry.path) {
                entry.fileIdentity = identity
                terminalIdentities.insert(identity)
            }
            entries[key] = entry
        }
    }

    // MARK: Seeding

    /// Marks already-processed paths (restored ledger entries, outputs,
    /// masters) as terminal so they are never offered again.
    func seedProcessedPaths(_ paths: [String]) {
        lock.withLock {
            for path in paths {
                let (key, existing) = entryForUpdate(path: path)
            var entry = existing
                entry.terminal = .accepted
                if let identity = StackFileIdentity.identity(forPath: entry.path) {
                    entry.fileIdentity = identity
                    terminalIdentities.insert(identity)
                }
                entries[key] = entry
            }
        }
    }

    /// Restores the persisted ledger. Accepted, rejected, and ignored frames
    /// stay terminal; unreadable frames keep their recorded identity and
    /// processed time so the reopen rules apply to them.
    func seedPersistedFrames(_ frames: [LiveStackPersistedFrame]) {
        lock.withLock {
            for frame in frames {
                let (key, existing) = entryForUpdate(path: frame.path)
                var entry = existing
                switch frame.disposition {
                case .accepted:
                    entry.terminal = .accepted
                case .rejected:
                    entry.terminal = .rejected
                case .ignored:
                    entry.terminal = .ignored
                case .unreadable:
                    entry.terminal = .unreadable
                }
                entry.length = frame.length
                entry.lastWriteUnixNanoseconds = frame.lastWriteUnixNanoseconds
                entry.fileIdentity = frame.fileIdentity
                entry.processedAt = frame.processedAtUTC
                if entry.terminal != .unreadable, let identity = frame.fileIdentity {
                    terminalIdentities.insert(identity)
                }
                entries[key] = entry
            }
        }
    }

    // MARK: Introspection

    var pendingCount: Int {
        lock.withLock { cachedPendingCount }
    }

    func beginScan() {
        lock.withLock {
            for key in entries.keys {
                entries[key]?.seenThisScan = false
            }
        }
    }
}

// MARK: - Monitor

/// Watches a capture folder by periodic enumeration: every scan observes
/// each stackable file's size, timestamp, and identity, and yields a
/// candidate only after the file has stayed unchanged across observations
/// for the stability window. Enumeration is the source of truth, so files
/// that arrive while the app is closed are found on the first scan.
final class StackFolderMonitor: @unchecked Sendable {
    struct Configuration: Sendable {
        var watchFolder: String
        var includeSubdirectories = false
        var excludedPaths: [String] = []
        var excludedDirectories: [String] = []
        var scanInterval: TimeInterval = 2
        var tracker = StackFileCandidateTracker.Configuration()
        var now: @Sendable () -> Date = { Date() }
    }

    let tracker: StackFileCandidateTracker
    private let configuration: Configuration
    /// Case-folded normalized directory paths, precomputed so the scan loop
    /// never re-normalizes constants.
    private let excludedDirectoryPrefixes: [String]
    private let lock = NSLock()
    private var excludedPaths: Set<String>
    private var lastScanError: String?
    private var scanTask: Task<Void, Never>?
    private var continuation: AsyncStream<StackFileCandidate>.Continuation?
    /// Identifies the stream a scan task and continuation belong to, so a
    /// stale stream's termination can never tear down a fresh restart.
    private var streamGeneration = 0

    init(configuration: Configuration) {
        self.configuration = configuration
        self.tracker = StackFileCandidateTracker(configuration: configuration.tracker)
        self.excludedPaths = Set(
            configuration.excludedPaths.map {
                LiveStackPath.normalize($0).lowercased()
            })
        self.excludedDirectoryPrefixes = configuration.excludedDirectories.map {
            LiveStackPath.normalize($0).lowercased() + "/"
        }
    }

    /// The single-consumer candidate stream. Starts the scan loop; ending
    /// the stream stops it.
    func candidates() -> AsyncStream<StackFileCandidate> {
        AsyncStream { continuation in
            let generation: Int = lock.withLock {
                streamGeneration += 1
                self.continuation = continuation
                return streamGeneration
            }
            let interval = configuration.scanInterval
            let task = Task { [weak self] in
                while !Task.isCancelled {
                    self?.scanOnce()
                    try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                }
            }
            lock.withLock {
                if streamGeneration == generation {
                    scanTask = task
                } else {
                    task.cancel()
                }
            }
            continuation.onTermination = { [weak self] _ in
                self?.stop(generation: generation)
            }
        }
    }

    func stop() {
        stop(generation: lock.withLock { streamGeneration })
    }

    private func stop(generation: Int) {
        let (task, continuation): (Task<Void, Never>?, AsyncStream<StackFileCandidate>.Continuation?) =
            lock.withLock {
                guard generation == streamGeneration else { return (nil, nil) }
                let current = (scanTask, self.continuation)
                scanTask = nil
                self.continuation = nil
                return current
            }
        task?.cancel()
        continuation?.finish()
        if task != nil || continuation != nil {
            // Offers that never completed are re-offered on the next start.
            tracker.clearPendingDispositions()
        }
    }

    /// One enumeration pass: observe every eligible file, then emit the
    /// candidates that became due. Exposed for tests.
    func scanOnce() {
        let now = configuration.now()
        tracker.beginScan()
        var scanError: String?
        let root = URL(fileURLWithPath: configuration.watchFolder)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(
            atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue {
            enumerate(root, now: now)
        } else {
            scanError = "The capture folder is unavailable."
        }
        lock.withLock { lastScanError = scanError }
        let due = tracker.dueCandidates(now: now)
        guard !due.isEmpty else { return }
        let continuation = lock.withLock { self.continuation }
        guard let continuation else {
            tracker.clearPendingDispositions()
            return
        }
        for candidate in due {
            continuation.yield(candidate)
        }
    }

    private func enumerate(_ directory: URL, now: Date) {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])) ?? []
        for url in contents {
            let values = try? url.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true { continue }
            if values?.isDirectory == true {
                guard configuration.includeSubdirectories else { continue }
                let path = LiveStackPath.normalize(url.path).lowercased() + "/"
                let isExcluded = excludedDirectoryPrefixes.contains {
                    path.hasPrefix($0)
                }
                if !isExcluded {
                    enumerate(url, now: now)
                }
                continue
            }
            observeFile(url, now: now)
        }
    }

    private func observeFile(_ url: URL, now: Date) {
        let name = url.lastPathComponent
        guard !name.hasPrefix("."),
            ImageCollection.isStackableImage(url)
        else { return }
        let path = LiveStackPath.normalize(url.path)
        if excludedPaths.contains(path.lowercased()) { return }

        guard let snapshot = StackFileIdentity.snapshot(forPath: path) else { return }
        tracker.observe(
            path: path,
            length: snapshot.length,
            lastWriteUnixNanoseconds: snapshot.modifiedUnixNanoseconds,
            fileIdentity: snapshot.identity,
            now: now)
    }

    // MARK: Coordinator surface

    func isCandidateCurrent(_ candidate: StackFileCandidate) -> Bool {
        tracker.isCandidateCurrent(candidate)
    }

    func complete(
        _ candidate: StackFileCandidate, disposition: StackFileDispositionKind
    ) {
        tracker.complete(candidate, disposition: disposition, now: configuration.now())
    }

    func retryNow(_ path: String) {
        tracker.retryNow(path)
    }

    func reservePath(_ path: String) {
        lock.withLock {
            _ = excludedPaths.insert(LiveStackPath.normalize(path).lowercased())
        }
        tracker.reserve(path)
    }

    func releaseReservedPath(_ path: String) {
        lock.withLock {
            _ = excludedPaths.remove(LiveStackPath.normalize(path).lowercased())
        }
        tracker.releaseReservation(path)
    }

    func commitReservedPath(_ path: String) {
        tracker.commitReservation(path, now: configuration.now())
    }

    func seedProcessedPaths(_ paths: [String]) {
        tracker.seedProcessedPaths(paths)
    }

    func seedPersistedFrames(_ frames: [LiveStackPersistedFrame]) {
        tracker.seedPersistedFrames(frames)
    }

    var statusDescription: String {
        let error = lock.withLock { lastScanError }
        if let error {
            return "watching — \(error)"
        }
        let pending = tracker.pendingCount
        return pending > 0 ? "watching · \(pending) pending" : "watching"
    }
}
