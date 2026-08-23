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

/// The `(device, inode)` identity of a file, stable across renames.
enum StackFileIdentity {
    static func identity(forPath path: String) -> String? {
        var status = stat()
        guard stat(path, &status) == 0 else { return nil }
        return String(
            format: "%llX:%llX", UInt64(status.st_dev), UInt64(status.st_ino))
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

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    private static func key(_ path: String) -> String {
        LiveStackPath.normalize(path).lowercased()
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
            let key = Self.key(path)
            var entry = entries[key] ?? Entry()
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
    /// rename or hard-link alias) becomes terminal-ignored instead.
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
                    path: key,
                    attempt: entry.attempt,
                    revision: entry.revision,
                    length: entry.length,
                    lastWriteUnixNanoseconds: entry.lastWriteUnixNanoseconds,
                    fileIdentity: entry.fileIdentity))
            }
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

    // MARK: Reservations

    func reserve(_ path: String) {
        lock.withLock {
            let key = Self.key(path)
            var entry = entries[key] ?? Entry()
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
            let key = Self.key(path)
            var entry = entries[key] ?? Entry()
            entry.reserved = false
            entry.terminal = .accepted
            entry.processedAt = now
            if let identity = entry.fileIdentity
                ?? StackFileIdentity.identity(forPath: path) {
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
                let key = Self.key(path)
                var entry = entries[key] ?? Entry()
                entry.terminal = .accepted
                if let identity = StackFileIdentity.identity(forPath: key) {
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
                let key = Self.key(frame.path)
                var entry = entries[key] ?? Entry()
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
        lock.withLock {
            entries.values.count { entry in
                entry.terminal == nil && !entry.reserved && entry.seenThisScan
            }
        }
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
    private let lock = NSLock()
    private var excludedPaths: Set<String>
    private var lastScanError: String?
    private var scanTask: Task<Void, Never>?
    private var continuation: AsyncStream<StackFileCandidate>.Continuation?

    init(configuration: Configuration) {
        self.configuration = configuration
        self.tracker = StackFileCandidateTracker(configuration: configuration.tracker)
        self.excludedPaths = Set(
            configuration.excludedPaths.map {
                LiveStackPath.normalize($0).lowercased()
            })
    }

    /// The single-consumer candidate stream. Starts the scan loop; ending
    /// the stream stops it.
    func candidates() -> AsyncStream<StackFileCandidate> {
        AsyncStream { continuation in
            lock.withLock { self.continuation = continuation }
            let interval = configuration.scanInterval
            scanTask = Task { [weak self] in
                while !Task.isCancelled {
                    self?.scanOnce()
                    try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                }
            }
            continuation.onTermination = { [weak self] _ in
                self?.stop()
            }
        }
    }

    func stop() {
        scanTask?.cancel()
        scanTask = nil
        let continuation = lock.withLock {
            let current = self.continuation
            self.continuation = nil
            return current
        }
        continuation?.finish()
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
        for candidate in due {
            continuation?.yield(candidate)
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
                let path = url.path
                let isExcluded = configuration.excludedDirectories.contains {
                    LiveStackPath.isWithinDirectory(path, directory: $0)
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
        guard !name.hasPrefix(LiveStackAtomicFITS.stagingPrefix),
            !name.hasPrefix("."),
            ImageCollection.isStackableImage(url)
        else { return }
        let path = LiveStackPath.normalize(url.path)
        if excludedPaths.contains(path.lowercased()) { return }
        let isInExcludedDirectory = configuration.excludedDirectories.contains {
            LiveStackPath.isWithinDirectory(path, directory: $0)
        }
        if isInExcludedDirectory { return }

        var status = stat()
        guard stat(path, &status) == 0 else { return }
        let identity = String(
            format: "%llX:%llX", UInt64(status.st_dev), UInt64(status.st_ino))
        let modified = Int64(status.st_mtimespec.tv_sec) * 1_000_000_000
            + Int64(status.st_mtimespec.tv_nsec)
        tracker.observe(
            path: path,
            length: Int64(status.st_size),
            lastWriteUnixNanoseconds: modified,
            fileIdentity: identity,
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
