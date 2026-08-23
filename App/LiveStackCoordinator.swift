import Foundation

// MARK: - Run configuration

struct LiveStackRunConfiguration: Sendable {
    var watchFolder: String
    var sessionRootDirectory: URL
    var groupId = "live"
    var groupTitle = "Live stack"
    var includeSubdirectories = false
    var resumeExisting = true
    var applyCalibrationOnResume = false
    var initialReferencePath: String? = nil
    var options = ImageStackOptions()
    var calibration = ImageStackCalibration()
    var previewProcessingJSON = LiveStackRunConfiguration.defaultPreviewProcessingJSON
    var previewMaxDimension: UInt32 = 1600
    var previewInterval: TimeInterval = 2
    var checkpointInterval: TimeInterval = 120
    var checkpointAcceptedFrameInterval = 5
    var maximumReadAttempts = 4
    var monitorScanInterval: TimeInterval = 2
    var monitorStabilityDuration: TimeInterval = 2

    /// The live accumulator holds physical linear data, so previews map it
    /// through a robust-percentile physical domain before the display
    /// stretch.
    static let defaultPreviewProcessingJSON = """
        {"sample_domain":{"type":"physical-linear","normalization":\
        {"type":"robust-percentile","black_percentile":0.001,\
        "white_percentile":0.999,"max_analysis_samples":200000}},\
        "stretch":[{"model":{"type":"auto-mtf","target_median":0.2,\
        "shadows_clip":-2.8},"color_strategy":"unlinked",\
        "max_analysis_samples":200000}]}
        """

    func validationMessage() -> String? {
        if watchFolder.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Choose an existing capture folder."
        }
        if groupId.trimmingCharacters(in: .whitespaces).isEmpty
            || groupTitle.trimmingCharacters(in: .whitespaces).isEmpty {
            return "The live-stack group is not configured."
        }
        if let message = options.validationMessage { return message }
        if let message = calibration.validationMessage(for: []) { return message }
        if previewProcessingJSON.trimmingCharacters(in: .whitespaces).isEmpty {
            return "The preview processing configuration is empty."
        }
        if previewMaxDimension == 0 || previewMaxDimension > 8192 {
            return "The preview dimension must be between 1 and 8192."
        }
        if previewInterval < 0 || checkpointInterval <= 0 {
            return "The preview and checkpoint intervals must be positive."
        }
        if checkpointAcceptedFrameInterval <= 0 {
            return "The checkpoint frame interval must be positive."
        }
        if !(1...20).contains(maximumReadAttempts) {
            return "Read attempts must be between 1 and 20."
        }
        return nil
    }

    /// Paths the monitor must never offer as lights. The initial reference
    /// is deliberately not excluded: a restored session may not contain it,
    /// making it a legitimate new capture.
    func monitorExcludedPaths() -> [String] {
        var excluded: [String] = []
        for url in [calibration.bias, calibration.dark, calibration.flat] {
            if let url {
                excluded.append(LiveStackPath.normalize(url.path))
            }
        }
        return excluded
    }
}

// MARK: - Run state and snapshot

enum LiveStackRunState: String, Sendable {
    case created
    case restoring
    case waitingForLight
    case watching
    case processing
    case checkpointing
    case pausing
    case paused
    case savingSnapshot
    case finishing
    case completed
    case needsAttention
    case faulted
    case disposed

    var isRunning: Bool {
        switch self {
        case .restoring, .waitingForLight, .watching, .processing, .checkpointing:
            return true
        default:
            return false
        }
    }

    var title: String {
        switch self {
        case .created: "Starting"
        case .restoring: "Restoring"
        case .waitingForLight: "Waiting for a light"
        case .watching: "Watching"
        case .processing: "Processing"
        case .checkpointing: "Checkpointing"
        case .pausing: "Pausing"
        case .paused: "Paused"
        case .savingSnapshot: "Saving snapshot"
        case .finishing: "Finishing"
        case .completed: "Completed"
        case .needsAttention: "Needs attention"
        case .faulted: "Faulted"
        case .disposed: "Disposed"
        }
    }
}

struct LiveStackAttention: Equatable, Sendable {
    var message: String
    var path: String? = nil
    var occurredAtUTC = Date()
}

enum LiveStackAttentionPresentation {
    static func recentMessages(
        _ attention: [LiveStackAttention], limit: Int = 8
    ) -> [String] {
        attention
            .filter {
                !$0.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            .suffix(limit)
            .map { item in
                if let path = item.path {
                    let name = URL(fileURLWithPath: path).lastPathComponent
                    if !name.isEmpty {
                        return "\(name) — \(item.message)"
                    }
                }
                return item.message
            }
    }
}

/// One immutable view of the run, published after every meaningful change.
struct LiveStackRunSnapshot: Sendable {
    var state: LiveStackRunState = .created
    var statusMessage = "Ready to watch a folder."
    var currentFileName = ""
    var acceptedFrames = 0
    var rejectedFrames = 0
    var ignoredFrames = 0
    var unreadableFrames = 0
    var filter: LiveStackFilterIdentity? = nil
    var calibrationHistory: [LiveStackCalibrationEpoch] = []
    var checkpointGeneration: Int64? = nil
    var lastCheckpointAtUTC: Date? = nil
    var monitorStatus = ""
    var snrSamples: [LiveStackPersistedSnrSample] = []
    var attention: [LiveStackAttention] = []
    var preview: LiveStackPreview? = nil
    var previewRevision = 0
    var requiresReopenToResume = false

    var hasStack: Bool { acceptedFrames > 0 }
    var skippedFrames: Int { ignoredFrames + unreadableFrames }

    var snrPlot: [StackSnrPlotPoint] {
        let usable = snrSamples.filter(\.isUsable).map { sample in
            StackSnrMeasurement(
                frames: UInt32(sample.acceptedFrames),
                noise: sample.noise,
                background: sample.background,
                signal: sample.signal,
                exposureSeconds: sample.cumulativeExposureSeconds ?? 0)
        }
        return StackSnrAnalyzer.analyze(usable).points
    }
}

struct LiveStackExportResult: Sendable {
    var outputPath: String
    var acceptedFrames: Int
    var rejectedFrames: Int
}

enum LiveStackRunError: LocalizedError {
    case invalidConfiguration(String)
    case invalidOperation(String)
    case unsafeOutputPath(String)
    case checkpointFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message),
            .invalidOperation(let message),
            .unsafeOutputPath(let message):
            return message
        case .checkpointFailed(let message):
            return "The checkpoint could not be saved: \(message)"
        }
    }
}

// MARK: - Async gate

/// A FIFO mutex usable across suspension points, serializing multi-await
/// critical sections that actor reentrancy would otherwise interleave.
final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        let acquired: Bool = lock.withLock {
            if !isHeld {
                isHeld = true
                return true
            }
            return false
        }
        if acquired { return }
        await withCheckedContinuation { continuation in
            let resumeNow: Bool = lock.withLock {
                if !isHeld {
                    isHeld = true
                    return true
                }
                waiters.append(continuation)
                return false
            }
            if resumeNow {
                continuation.resume()
            }
        }
    }

    func release() {
        let next: CheckedContinuation<Void, Never>? = lock.withLock {
            if waiters.isEmpty {
                isHeld = false
                return nil
            }
            return waiters.removeFirst()
        }
        next?.resume()
    }
}

// MARK: - Coordinator

/// Orchestrates one resumable live stack: folder monitoring, admission
/// gates, native ingestion, previews, SNR telemetry, generation
/// checkpoints, snapshots, and finalization.
///
/// Data-safety invariants carried over from the Windows implementation:
/// a successful native push is always followed by a non-cancellable ledger
/// update; every native mutation that changes resumable meaning is followed
/// by a forced checkpoint; retirement happens only after the final export
/// is on disk.
actor LiveStackCoordinator {
    private let configuration: LiveStackRunConfiguration
    private let store: LiveStackSessionStore
    private let monitor: StackFolderMonitor
    private var session: LiveStackNativeSession?
    private var sessionId = UUID().uuidString
        .replacingOccurrences(of: "-", with: "").lowercased()

    private var state: LiveStackRunState = .created
    private var statusMessage = "Ready to watch a folder."
    private var currentPath: String?
    private var acceptedFrames = 0
    private var nativeRejectedFrames = 0
    private var policyRejectedFrames = 0
    private var ignoredFrames = 0
    private var unreadableFrames = 0
    private var lockedFilter: LiveStackFilterIdentity?
    private var referenceSignature: CalibrationFrameSignature?
    private var restoredReferenceUnavailable = false
    private var calibration: ImageStackCalibration
    private var outputPath: String?
    private var createdAtUTC = Date()
    private var frames: [LiveStackPersistedFrame] = []
    private var snrSamples: [LiveStackPersistedSnrSample] = []
    private var calibrationHistory: [LiveStackCalibrationEpoch] = []
    private var exportedPaths: [String] = []
    private var attention: [LiveStackAttention] = []
    private var preview: LiveStackPreview?
    private var previewRevision = 0
    private var lastPreviewAtUTC: Date?
    private var lastCheckpointAtUTC: Date?
    private var lastCheckpointGeneration: Int64?
    private var acceptedFramesAtCheckpoint = 0
    private var checkpointDirty = false
    private var persistenceRevision = 0
    private var checkpointBlocked = false
    private var nativeFinalized = false
    private var initialized = false
    private var disposed = false

    private var ingestionTask: Task<Void, Never>?
    private var checkpointTimerTask: Task<Void, Never>?
    private let operationGate = AsyncGate()
    private let lifecycleGate = AsyncGate()

    private var snapshotContinuations: [UUID: AsyncStream<LiveStackRunSnapshot>.Continuation] = [:]

    private static let maximumAttentionItems = 50

    init(configuration: LiveStackRunConfiguration) throws {
        if let message = configuration.validationMessage() {
            throw LiveStackRunError.invalidConfiguration(message)
        }
        var normalized = configuration
        normalized.watchFolder = LiveStackPath.normalize(configuration.watchFolder)
        normalized.initialReferencePath = configuration.initialReferencePath
            .map { LiveStackPath.normalize($0) }
        self.configuration = normalized
        self.calibration = normalized.calibration
        self.store = try LiveStackSessionStore(
            sessionRootDirectory: normalized.sessionRootDirectory,
            groupId: normalized.groupId)
        var trackerConfiguration = StackFileCandidateTracker.Configuration()
        trackerConfiguration.minimumStableDuration = normalized.monitorStabilityDuration
        self.monitor = StackFolderMonitor(configuration: .init(
            watchFolder: normalized.watchFolder,
            includeSubdirectories: normalized.includeSubdirectories,
            excludedPaths: normalized.monitorExcludedPaths(),
            excludedDirectories: [store.groupDirectory.path],
            scanInterval: normalized.monitorScanInterval,
            tracker: trackerConfiguration))
    }

    // MARK: Snapshots

    /// A stream of immutable run snapshots for presentation. Multiple
    /// observers each get the current snapshot immediately.
    func snapshots() -> AsyncStream<LiveStackRunSnapshot> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            snapshotContinuations[id] = continuation
            continuation.yield(makeSnapshot())
            continuation.onTermination = { _ in
                Task { await self.removeSnapshotContinuation(id) }
            }
        }
    }

    private func removeSnapshotContinuation(_ id: UUID) {
        snapshotContinuations[id] = nil
    }

    func currentSnapshot() -> LiveStackRunSnapshot {
        makeSnapshot()
    }

    private func makeSnapshot() -> LiveStackRunSnapshot {
        var snapshot = LiveStackRunSnapshot()
        snapshot.state = state
        snapshot.statusMessage = statusMessage
        snapshot.currentFileName = currentPath
            .map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
        snapshot.acceptedFrames = acceptedFrames
        snapshot.rejectedFrames = nativeRejectedFrames + policyRejectedFrames
        snapshot.ignoredFrames = ignoredFrames
        snapshot.unreadableFrames = unreadableFrames
        snapshot.filter = lockedFilter
        snapshot.calibrationHistory = calibrationHistory
        snapshot.checkpointGeneration = lastCheckpointGeneration
        snapshot.lastCheckpointAtUTC = lastCheckpointAtUTC
        snapshot.monitorStatus = monitor.statusDescription
        snapshot.snrSamples = snrSamples
        snapshot.attention = attention
        snapshot.preview = preview
        snapshot.previewRevision = previewRevision
        snapshot.requiresReopenToResume = nativeFinalized && state != .completed
        return snapshot
    }

    private func publish() {
        let snapshot = makeSnapshot()
        for continuation in snapshotContinuations.values {
            continuation.yield(snapshot)
        }
    }

    private func cumulativeExposure() -> Double? {
        let acceptedExposures = frames
            .filter { $0.disposition == .accepted }
            .map(\.exposureSeconds)
        return LiveStackExposureMath.cumulativeExposure(acceptedExposures)
    }

    // MARK: State helpers

    private func setState(_ newState: LiveStackRunState, _ message: String) {
        state = newState
        statusMessage = message
        publish()
    }

    private func addAttention(_ message: String, path: String? = nil) {
        attention.append(LiveStackAttention(message: message, path: path))
        if attention.count > Self.maximumAttentionItems {
            attention.removeFirst(attention.count - Self.maximumAttentionItems)
        }
    }

    private func markCheckpointDirty() {
        persistenceRevision += 1
        checkpointDirty = true
    }

    private func runningStateAfterOperation() -> (LiveStackRunState, String) {
        if checkpointBlocked {
            return (.needsAttention,
                "Checkpoint failed. Free disk space or choose a writable session "
                    + "location, then resume.")
        }
        switch state {
        case .completed, .faulted, .disposed, .needsAttention:
            return (state, statusMessage)
        default:
            break
        }
        if ingestionTask != nil {
            return session == nil
                ? (.waitingForLight, "Waiting for the first stable light frame.")
                : (.watching, "Watching for new light frames.")
        }
        return (.paused, "Live stacking is paused and resumable.")
    }

    // MARK: Lifecycle

    func start() async throws {
        await lifecycleGate.acquire()
        defer { lifecycleGate.release() }
        guard !disposed else {
            throw LiveStackRunError.invalidOperation("The live-stack session is closed.")
        }
        guard state != .completed else {
            throw LiveStackRunError.invalidOperation("The live stack is already complete.")
        }
        guard !nativeFinalized else {
            throw LiveStackRunError.invalidOperation(
                "This run was finalized. Create a new coordinator to resume its "
                    + "checkpoint.")
        }
        if ingestionTask != nil { return }

        if !initialized {
            do {
                try await initialize()
                initialized = true
            } catch is CancellationError {
                if session != nil {
                    initialized = true
                    setState(.paused,
                        "Live-stack startup was cancelled; the open stack remains "
                            + "resumable.")
                }
                throw CancellationError()
            } catch {
                if state != .needsAttention {
                    setFault(
                        "Live stacking stopped because of an error.",
                        detail: error.localizedDescription)
                }
                throw error
            }
        }

        if session != nil, checkpointBlocked || (checkpointDirty && lastCheckpointGeneration == nil) {
            try await forcedCheckpoint()
        }
        checkpointBlocked = false

        if session == nil {
            setState(.waitingForLight, "Waiting for the first stable light frame.")
        } else if let generation = lastCheckpointGeneration {
            setState(.watching,
                "Resumed checkpoint generation \(generation); watching for new "
                    + "light frames.")
        } else {
            setState(.watching, "Watching for new light frames.")
        }
        startIngestion()
    }

    private func startIngestion() {
        let candidateStream = monitor.candidates()
        checkpointTimerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if Task.isCancelled { break }
                await self?.checkpointIfDueByTime()
            }
        }
        ingestionTask = Task { [weak self] in
            for await candidate in candidateStream {
                guard let self else { return }
                let shouldContinue = await self.ingest(candidate)
                if !shouldContinue { break }
            }
            await self?.ingestionEnded()
        }
    }

    private func stopIngestion() async {
        checkpointTimerTask?.cancel()
        checkpointTimerTask = nil
        let task = ingestionTask
        ingestionTask = nil
        monitor.stop()
        if let task {
            await task.value
        }
    }

    private func ingestionEnded() {
        ingestionTask = nil
        checkpointTimerTask?.cancel()
        checkpointTimerTask = nil
        switch state {
        case .completed, .needsAttention, .faulted, .disposed, .pausing, .finishing:
            break
        default:
            setState(.paused, "Live stacking is paused.")
        }
    }

    private func checkpointIfDueByTime() async {
        guard checkpointDirty, session != nil, !checkpointBlocked else { return }
        let due = lastCheckpointAtUTC.map {
            Date().timeIntervalSince($0) >= configuration.checkpointInterval
        } ?? true
        guard due else { return }
        await operationGate.acquire()
        defer { operationGate.release() }
        do {
            try await checkpointCore()
            let (nextState, nextMessage) = runningStateAfterOperation()
            setState(nextState, nextMessage)
        } catch is CancellationError {
            // A pause or stop cancelled the checkpoint mid-write; the next
            // forced checkpoint publishes a fresh generation.
        } catch {
            blockOnCheckpointFailure(error)
        }
    }

    // MARK: Restore

    private func initialize() async throws {
        setState(.restoring, "Looking for a resumable live stack…")
        let candidates = configuration.resumeExisting
            ? await store.restoreCandidates()
            : []
        var restored = false
        for candidate in candidates {
            guard manifestMatchesConfiguration(candidate.manifest.state) else {
                addAttention(
                    "Saved generation \(candidate.generation) did not match this run.")
                continue
            }
            let restoredSession: LiveStackNativeSession
            let nativeState: LiveStackNativeState
            do {
                let contextPath = candidate.contextURL.path
                restoredSession = try await runBlocking {
                    try LiveStackNativeSession.resume(contextPath: contextPath)
                }
                nativeState = try await restoredSession.state()
            } catch {
                addAttention(
                    "Saved generation \(candidate.generation) could not be reopened: "
                        + error.localizedDescription)
                continue
            }
            guard await store.tryAcceptRestoredGeneration(candidate, actual: nativeState)
            else {
                await restoredSession.close()
                addAttention(
                    "Saved generation \(candidate.generation) did not describe its "
                        + "own checkpoint.")
                continue
            }
            session = restoredSession
            try await restoreState(
                from: candidate.manifest, nativeState: nativeState)
            if candidate.usedPreviousGeneration {
                addAttention(
                    "The current checkpoint was invalid; resumed the previous "
                        + "generation.")
            }
            restored = true
            break
        }

        if !restored, let initialReference = configuration.initialReferencePath {
            try await openInitialReference(initialReference)
            return
        }
        if restored {
            if configuration.applyCalibrationOnResume {
                await applyConfiguredCalibrationAfterRestore()
            }
            setState(.paused, "The saved live stack is ready to resume.")
        } else {
            seedCalibrationPaths()
            setState(.waitingForLight,
                "No checkpoint found; waiting for the first stable light frame.")
        }
    }

    private func manifestMatchesConfiguration(_ state: LiveStackPersistedState) -> Bool {
        state.groupId == configuration.groupId
            && LiveStackPath.equals(state.watchFolder, configuration.watchFolder)
            && state.includesSubdirectories == configuration.includeSubdirectories
            && state.stackOptionsJSON == (try? optionsJSON()) ?? ""
    }

    private func optionsJSON() throws -> String {
        String(decoding: try configuration.options.jsonData, as: UTF8.self)
    }

    private func restoreState(
        from manifest: LiveStackGenerationManifest,
        nativeState: LiveStackNativeState
    ) async throws {
        let persisted = manifest.state
        sessionId = persisted.sessionId
        createdAtUTC = persisted.createdAtUTC
        outputPath = persisted.outputPath.isEmpty ? nil : persisted.outputPath
        lockedFilter = LiveStackFilterIdentity.fromStoredName(persisted.filterName)
        frames = persisted.frames
        snrSamples = persisted.snrSamples
        calibrationHistory = persisted.calibrationHistory
        exportedPaths = persisted.exportedPaths.map { LiveStackPath.normalize($0) }
        if let epoch = calibrationHistory.last {
            calibration = ImageStackCalibration(
                bias: epoch.biasPath.map { URL(fileURLWithPath: $0) },
                dark: epoch.darkPath.map { URL(fileURLWithPath: $0) },
                flat: epoch.flatPath.map { URL(fileURLWithPath: $0) },
                overridesDarkExposure: epoch.darkExposureSeconds != nil,
                darkExposureSeconds: epoch.darkExposureSeconds ?? 300)
        }
        acceptedFrames = nativeState.acceptedFrames
        nativeRejectedFrames = nativeState.rejectedFrames
        let persistedRejected = frames.filter { $0.disposition == .rejected }.count
        policyRejectedFrames = max(0, persistedRejected - nativeRejectedFrames)
        ignoredFrames = frames.filter { $0.disposition == .ignored }.count
        unreadableFrames = frames.filter { $0.disposition == .unreadable }.count
        lastCheckpointAtUTC = persisted.updatedAtUTC
        lastCheckpointGeneration = manifest.generation
        acceptedFramesAtCheckpoint = acceptedFrames
        persistenceRevision = 0
        checkpointDirty = false
        checkpointBlocked = false

        referenceSignature = await deriveRestoredReferenceSignature(
            nativeState: nativeState, persisted: persisted)
        restoredReferenceUnavailable = referenceSignature == nil
        if restoredReferenceUnavailable {
            addAttention(
                "The restored reference identity is unavailable; new lights cannot "
                    + "be admitted to this stack.")
        }

        seedCalibrationPaths()
        monitor.seedProcessedPaths(
            nativeState.inputPaths + exportedPaths
                + (outputPath.map { [$0] } ?? []))
        monitor.seedPersistedFrames(frames)
        await tryMeasureDepth()
        await tryRenderPreview(force: true)
        publish()
    }

    /// Decides whether new lights may be admitted after a resume. The
    /// native reference probe is authoritative; the fallback re-probes the
    /// first ledger entry and cross-checks its recorded identity.
    private func deriveRestoredReferenceSignature(
        nativeState: LiveStackNativeState,
        persisted: LiveStackPersistedState
    ) async -> CalibrationFrameSignature? {
        if let referenceFrame = nativeState.referenceFrame {
            guard referenceFrame.role == CalibrationFrameRole.light,
                !referenceFrame.isMaster
            else {
                addAttention("The restored reference is not a raw light frame.")
                return nil
            }
            if let filter = referenceFrame.signature.filter,
                !filter.trimmingCharacters(in: .whitespaces).isEmpty,
                let storedName = persisted.filterName {
                let restoredIdentity = LiveStackFilterIdentity.fromName(
                    filter, source: .header)
                let storedIdentity = LiveStackFilterIdentity.fromStoredName(storedName)
                guard restoredIdentity.matches(storedIdentity) else {
                    addAttention(
                        "The restored reference filter does not match the saved "
                            + "session.")
                    return nil
                }
            }
            return referenceFrame.signature
        }

        guard let firstInput = nativeState.inputPaths.first else { return nil }
        let referencePath = LiveStackPath.normalize(firstInput)
        guard let ledgerEntry = frames.first(where: {
            LiveStackPath.equals($0.path, referencePath)
                && $0.disposition == .accepted
        }) else {
            addAttention(
                "The restored reference is missing from the session ledger.",
                path: referencePath)
            return nil
        }
        guard let fileStat = StackFileIdentity.snapshot(forPath: referencePath),
            fileStat.length == ledgerEntry.length,
            fileStat.modifiedUnixNanoseconds == ledgerEntry.lastWriteUnixNanoseconds
        else {
            addAttention(
                "The restored reference file changed or is unavailable.",
                path: referencePath)
            return nil
        }
        if let recordedIdentity = ledgerEntry.fileIdentity,
            recordedIdentity != fileStat.identity {
            addAttention(
                "The restored reference file identity changed.", path: referencePath)
            return nil
        }
        guard let probe = try? await runBlocking({
            try CalibrationService.probe(path: referencePath)
        }) else {
            addAttention(
                "The restored reference could not be probed.", path: referencePath)
            return nil
        }
        guard probe.role == CalibrationFrameRole.light, !probe.isMaster else {
            addAttention(
                "The restored reference is no longer a raw light frame.",
                path: referencePath)
            return nil
        }
        if let storedName = persisted.filterName {
            let probeIdentity = LiveStackFilterIdentity.fromProbe(probe)
            let storedIdentity = LiveStackFilterIdentity.fromStoredName(storedName)
            guard probeIdentity.matches(storedIdentity) else {
                addAttention(
                    "The restored reference filter no longer matches the saved "
                        + "session.", path: referencePath)
                return nil
            }
        }
        return probe.signature
    }

    private func seedCalibrationPaths() {
        monitor.seedProcessedPaths(configuration.monitorExcludedPaths())
        let historical = calibrationHistory.flatMap { epoch in
            [epoch.biasPath, epoch.darkPath, epoch.flatPath].compactMap { $0 }
        }
        if !historical.isEmpty {
            monitor.seedProcessedPaths(historical)
        }
    }

    private func openInitialReference(_ referencePath: String) async throws {
        let probe = try await runBlocking {
            try CalibrationService.probe(path: referencePath)
        }
        guard probe.role == CalibrationFrameRole.light else {
            throw LiveStackRunError.invalidOperation(
                "The initial reference is not a light frame.")
        }
        if hasAnyMasters(calibration),
            let reason = CalibrationLightEligibility.ineligibilityReason(probe) {
            throw LiveStackRunError.invalidOperation(
                "The initial reference cannot be calibrated; \(reason).")
        }
        try await openReference(probe: probe, reason: "Selected reference frame")
        seedCalibrationPaths()
        try await forcedCheckpoint()
        setState(.waitingForLight,
            "Calibration is ready; waiting for the first stable light frame.")
    }

    private func applyConfiguredCalibrationAfterRestore() async {
        let configured = configuration.calibration
        guard !calibrationsAreEquivalent(configured, calibration) else { return }
        do {
            try await updateCalibrationCore(configured)
            addAttention(
                "The selected calibration replaced the checkpoint calibration for "
                    + "new frames.")
        } catch {
            addAttention(
                "The selected calibration could not be applied: "
                    + error.localizedDescription)
        }
    }

    private func calibrationsAreEquivalent(
        _ a: ImageStackCalibration, _ b: ImageStackCalibration
    ) -> Bool {
        func path(_ url: URL?) -> String? {
            url.map { LiveStackPath.normalize($0.path).lowercased() }
        }
        let exposureA = a.overridesDarkExposure ? a.darkExposureSeconds : nil
        let exposureB = b.overridesDarkExposure ? b.darkExposureSeconds : nil
        return path(a.bias) == path(b.bias)
            && path(a.dark) == path(b.dark)
            && path(a.flat) == path(b.flat)
            && exposureA == exposureB
    }

    private func hasAnyMasters(_ calibration: ImageStackCalibration) -> Bool {
        calibration.bias != nil || calibration.dark != nil || calibration.flat != nil
    }

    // MARK: Ingestion

    /// Handles one candidate; returns false when ingestion must stop.
    private func ingest(_ candidate: StackFileCandidate) async -> Bool {
        await operationGate.acquire()
        defer { operationGate.release() }
        guard !checkpointBlocked else {
            monitor.retryNow(candidate.path)
            return false
        }
        guard monitor.isCandidateCurrent(candidate) else { return true }
        do {
            try await processCandidate(candidate)
            return true
        } catch is CancellationError {
            monitor.retryNow(candidate.path)
            return false
        } catch {
            monitor.retryNow(candidate.path)
            setFault(
                "Live stacking stopped because of an error.",
                detail: error.localizedDescription)
            return false
        }
    }

    private func processCandidate(_ candidate: StackFileCandidate) async throws {
        currentPath = candidate.path
        setState(.processing, "Inspecting the stable image header…")

        let probe: CalibrationFrameProbe
        do {
            probe = try await runBlocking {
                try CalibrationService.probe(path: candidate.path)
            }
        } catch {
            completeReadFailure(candidate, message: error.localizedDescription)
            return
        }

        // Role gate: only lights are stacked.
        let role = probe.role.trimmingCharacters(in: .whitespaces).lowercased()
        guard role == CalibrationFrameRole.light else {
            let reason = switch role {
            case CalibrationFrameRole.bias: "Bias calibration frame"
            case CalibrationFrameRole.dark: "Dark calibration frame"
            case CalibrationFrameRole.darkFlat: "Dark-flat calibration frame"
            case CalibrationFrameRole.flat: "Flat calibration frame"
            default: "Frame role is \(role)"
            }
            recordTerminalFrame(
                candidate, probe: probe, disposition: .ignored, reason: reason)
            monitor.complete(candidate, disposition: .ignored)
            addAttention(reason, path: candidate.path)
            finishCandidate("Ignored \(candidate.fileName).")
            return
        }

        // Calibration eligibility gate.
        if hasAnyMasters(calibration),
            let reason = CalibrationLightEligibility.ineligibilityReason(probe) {
            recordTerminalFrame(
                candidate, probe: probe, disposition: .rejected,
                reason: "Cannot calibrate: \(reason)")
            policyRejectedFrames += 1
            monitor.complete(candidate, disposition: .rejected)
            addAttention(
                "Rejected \(candidate.fileName): \(reason).", path: candidate.path)
            finishCandidate("Rejected \(candidate.fileName).")
            return
        }

        // Filter lock gate.
        let candidateFilter = LiveStackFilterIdentity.fromProbe(probe)
        if let lockedFilter, !candidateFilter.matches(lockedFilter) {
            recordTerminalFrame(
                candidate, probe: probe, disposition: .ignored,
                reason: "Filter \(candidateFilter.displayName) does not match "
                    + lockedFilter.displayName)
            monitor.complete(candidate, disposition: .ignored)
            finishCandidate("Ignored a \(candidateFilter.displayName) frame.")
            return
        }

        // Camera and geometry lock gate.
        if session != nil {
            guard let referenceSignature, !restoredReferenceUnavailable else {
                recordTerminalFrame(
                    candidate, probe: probe, disposition: .rejected,
                    reason: "The restored reference identity is unavailable.")
                policyRejectedFrames += 1
                monitor.complete(candidate, disposition: .rejected)
                finishCandidate("Rejected \(candidate.fileName).")
                return
            }
            if let mismatch = LiveStackCalibrationIdentity.mismatchReason(
                reference: referenceSignature, candidate: probe.signature) {
                recordTerminalFrame(
                    candidate, probe: probe, disposition: .rejected, reason: mismatch)
                policyRejectedFrames += 1
                monitor.complete(candidate, disposition: .rejected)
                addAttention(
                    "Rejected \(candidate.fileName): \(mismatch)",
                    path: candidate.path)
                finishCandidate("Rejected \(candidate.fileName).")
                return
            }
        }

        if session == nil {
            do {
                try await openReference(probe: probe, reason: "Reference frame")
                monitor.complete(candidate, disposition: .accepted)
            } catch {
                completeReadFailure(candidate, message: error.localizedDescription)
                return
            }
            await afterAcceptedFrame()
            finishCandidate("Accepted the reference \(candidate.fileName).")
            return
        }

        try await pushFrame(candidate, probe: probe)
    }

    private func openReference(
        probe: CalibrationFrameProbe, reason: String
    ) async throws {
        guard FileManager.default.fileExists(atPath: probe.path) else {
            throw LiveStackRunError.invalidOperation(
                "The reference frame is unavailable.")
        }
        let optionsJSONString = try optionsJSON()
        let referencePath = probe.path
        let openCalibration = calibration
        let opened = try await runBlocking {
            try LiveStackNativeSession.open(
                referencePath: referencePath,
                optionsJSON: optionsJSONString,
                calibration: openCalibration)
        }
        let counts = try await opened.counts()
        guard counts.acceptedFrames == 1 else {
            await opened.close()
            throw LiveStackRunError.invalidOperation(
                "The native live stack did not retain exactly one reference frame.")
        }
        session = opened
        acceptedFrames = 1
        nativeRejectedFrames = 0
        lockedFilter = LiveStackFilterIdentity.fromProbe(probe)
        referenceSignature = probe.signature
        restoredReferenceUnavailable = false
        calibrationHistory.append(LiveStackCalibrationEpoch(
            startsAtAcceptedFrame: 1,
            biasPath: calibration.bias.map { LiveStackPath.normalize($0.path) },
            darkPath: calibration.dark.map { LiveStackPath.normalize($0.path) },
            flatPath: calibration.flat.map { LiveStackPath.normalize($0.path) },
            darkExposureSeconds: calibration.overridesDarkExposure
                ? calibration.darkExposureSeconds
                : nil))
        recordFrame(
            path: probe.path,
            disposition: .accepted,
            reason: reason,
            exposureSeconds: probe.signature.exposureSeconds)
        monitor.seedProcessedPaths([probe.path])
        markCheckpointDirty()
    }

    private func pushFrame(
        _ candidate: StackFileCandidate, probe: CalibrationFrameProbe
    ) async throws {
        guard let session else { return }
        setState(.processing, "Registering \(candidate.fileName)…")
        let outcome = try await session.push(path: candidate.path)
        guard let disposition = outcome.disposition else {
            completeReadFailure(
                candidate,
                message: outcome.nativeError ?? "The frame could not be read.")
            return
        }
        // The accumulator has crossed its commit boundary; the managed
        // ledger update below must not be skipped for any reason. If the
        // counters cannot be read back, the disposition itself says which
        // counter the native side advanced.
        let accepted = disposition.accepted
        let counts = (try? await session.counts())
            ?? LiveStackSessionCounts(
                acceptedFrames: acceptedFrames + (accepted ? 1 : 0),
                rejectedFrames: nativeRejectedFrames + (accepted ? 0 : 1))
        acceptedFrames = counts.acceptedFrames
        nativeRejectedFrames = counts.rejectedFrames
        recordFrame(
            path: candidate.path,
            disposition: accepted ? .accepted : .rejected,
            reason: disposition.reason,
            exposureSeconds: probe.signature.exposureSeconds,
            candidate: candidate)
        markCheckpointDirty()
        monitor.complete(candidate, disposition: accepted ? .accepted : .rejected)
        if accepted {
            await afterAcceptedFrame()
            finishCandidate("Accepted \(candidate.fileName).")
        } else {
            if let reason = disposition.reason,
                !reason.trimmingCharacters(in: .whitespaces).isEmpty {
                addAttention(
                    "Rejected \(candidate.fileName): \(reason)", path: candidate.path)
            }
            finishCandidate("Rejected \(candidate.fileName).")
        }
    }

    private func afterAcceptedFrame() async {
        await tryMeasureDepth()
        await tryRenderPreview(force: acceptedFrames == 1)
        let checkpointDue = acceptedFrames == 1
            || acceptedFrames - acceptedFramesAtCheckpoint
                >= configuration.checkpointAcceptedFrameInterval
        if checkpointDue {
            do {
                try await checkpointCore()
            } catch is CancellationError {
                // A pause cancelled the checkpoint; the pause's own forced
                // checkpoint publishes the durable generation.
            } catch {
                blockOnCheckpointFailure(error)
            }
        }
    }

    private func finishCandidate(_ message: String) {
        currentPath = nil
        if !checkpointBlocked {
            let (nextState, _) = runningStateAfterOperation()
            setState(nextState, message)
        }
    }

    private func completeReadFailure(
        _ candidate: StackFileCandidate, message: String
    ) {
        if candidate.attempt < configuration.maximumReadAttempts {
            monitor.complete(candidate, disposition: .retryableFailure)
            finishCandidate(
                "Will retry \(candidate.fileName) "
                    + "(\(candidate.attempt)/\(configuration.maximumReadAttempts)).")
        } else {
            recordFrame(
                path: candidate.path,
                disposition: .unreadable,
                reason: message,
                exposureSeconds: nil,
                candidate: candidate)
            unreadableFrames += 1
            markCheckpointDirty()
            monitor.complete(candidate, disposition: .unreadable)
            addAttention(
                "Could not read \(candidate.fileName) after "
                    + "\(candidate.attempt) attempts: \(message)",
                path: candidate.path)
            finishCandidate("Skipped \(candidate.fileName).")
        }
    }

    private func recordTerminalFrame(
        _ candidate: StackFileCandidate,
        probe: CalibrationFrameProbe,
        disposition: LiveStackFrameDisposition,
        reason: String
    ) {
        if disposition == .ignored {
            ignoredFrames += 1
        }
        recordFrame(
            path: candidate.path,
            disposition: disposition,
            reason: reason,
            exposureSeconds: probe.signature.exposureSeconds,
            candidate: candidate)
        markCheckpointDirty()
    }

    private func recordFrame(
        path: String,
        disposition: LiveStackFrameDisposition,
        reason: String?,
        exposureSeconds: Double?,
        candidate: StackFileCandidate? = nil
    ) {
        // A file that recovered from an earlier unreadable terminal is not
        // reported as skipped forever. Ledger paths are stored normalized,
        // so one case-folded pass finds every stale entry.
        let normalizedPath = LiveStackPath.normalize(path)
        let normalizedKey = normalizedPath.lowercased()
        let countBefore = frames.count
        frames.removeAll {
            $0.disposition == .unreadable && $0.path.lowercased() == normalizedKey
        }
        unreadableFrames = max(0, unreadableFrames - (countBefore - frames.count))
        let normalizedExposure = exposureSeconds.flatMap {
            $0.isFinite && $0 > 0 ? $0 : nil
        }
        let fileStat = candidate == nil
            ? StackFileIdentity.snapshot(forPath: normalizedPath)
            : nil
        frames.append(LiveStackPersistedFrame(
            path: normalizedPath,
            disposition: disposition,
            reason: reason,
            exposureSeconds: normalizedExposure,
            length: candidate?.length ?? fileStat?.length ?? 0,
            lastWriteUnixNanoseconds: candidate?.lastWriteUnixNanoseconds
                ?? fileStat?.modifiedUnixNanoseconds ?? 0,
            processedAtUTC: Date(),
            fileIdentity: candidate?.fileIdentity ?? fileStat?.identity))
    }

    // MARK: SNR and preview

    private func tryMeasureDepth(includeCurrentDepth: Bool = false) async {
        guard let session else { return }
        let measuredDepths = Set(snrSamples.map(\.acceptedFrames))
        guard StackSnrMeasurementSchedule.isLiveMeasurementDue(
            acceptedFrames: acceptedFrames,
            measuredDepths: measuredDepths,
            includeCurrentDepth: includeCurrentDepth)
        else { return }
        do {
            guard let sample = try await session.measureDepth() else { return }
            guard Int(sample.frames) == acceptedFrames else { return }
            snrSamples.append(LiveStackPersistedSnrSample(
                acceptedFrames: acceptedFrames,
                cumulativeExposureSeconds: cumulativeExposure(),
                noise: sample.noise,
                background: sample.background,
                signal: sample.signal,
                channelNoise: sample.channelNoise,
                measuredAtUTC: Date()))
            markCheckpointDirty()
            publish()
        } catch {
            addAttention("SNR measurement was unavailable: \(error.localizedDescription)")
        }
    }

    private func tryRenderPreview(force: Bool) async {
        guard let session else { return }
        if !force, let lastPreviewAtUTC,
            Date().timeIntervalSince(lastPreviewAtUTC)
                < configuration.previewInterval {
            return
        }
        do {
            let rendered = try await session.renderPreview(
                configJSON: configuration.previewProcessingJSON,
                maxDimension: configuration.previewMaxDimension)
            preview = rendered
            previewRevision += 1
            lastPreviewAtUTC = Date()
            publish()
        } catch {
            addAttention(
                "The live preview could not be refreshed: "
                    + error.localizedDescription)
        }
    }

    // MARK: Checkpoints

    private func checkpointCore() async throws {
        guard let session else { return }
        setState(.checkpointing, "Saving a resumable checkpoint…")
        let revisionAtStart = persistenceRevision
        let persisted = buildPersistedState()
        let stored = try await store.publish(state: persisted) { path in
            try await session.saveContext(to: path)
        }
        lastCheckpointGeneration = stored.generation
        lastCheckpointAtUTC = Date()
        acceptedFramesAtCheckpoint = acceptedFrames
        checkpointDirty = persistenceRevision != revisionAtStart
        publish()
    }

    private func buildPersistedState() -> LiveStackPersistedState {
        LiveStackPersistedState(
            sessionId: sessionId,
            groupId: configuration.groupId,
            groupTitle: configuration.groupTitle,
            filterName: lockedFilter.flatMap {
                $0.source == .unspecified ? nil : $0.displayName
            },
            watchFolder: configuration.watchFolder,
            includesSubdirectories: configuration.includeSubdirectories,
            outputPath: outputPath ?? "",
            stackOptionsJSON: (try? optionsJSON()) ?? "",
            createdAtUTC: createdAtUTC,
            updatedAtUTC: Date(),
            calibrationHistory: calibrationHistory,
            exportedPaths: exportedPaths,
            frames: frames,
            snrSamples: snrSamples)
    }

    /// The forced-checkpoint pattern every resumable-state mutation relies
    /// on: acquire the operation gate, checkpoint, and on failure block the
    /// run before rethrowing. Cancellation is not a checkpoint failure.
    private func forcedCheckpoint() async throws {
        await operationGate.acquire()
        do {
            try await checkpointCore()
            operationGate.release()
        } catch is CancellationError {
            operationGate.release()
            throw CancellationError()
        } catch {
            operationGate.release()
            blockOnCheckpointFailure(error)
            throw error
        }
    }

    private func blockOnCheckpointFailure(_ error: Error) {
        checkpointBlocked = true
        ingestionTask?.cancel()
        addAttention(
            "The checkpoint at \(store.groupDirectory.path) failed: "
                + error.localizedDescription)
        setState(.needsAttention,
            "Checkpoint failed. Free disk space or choose a writable session "
                + "location, then resume.")
    }

    private func setFault(_ message: String, detail: String) {
        addAttention(detail)
        setState(.faulted, message)
    }

    // MARK: Pause, calibration, snapshot, finish, dispose

    func pauseAndSave() async throws {
        await lifecycleGate.acquire()
        defer { lifecycleGate.release() }
        guard !disposed else {
            throw LiveStackRunError.invalidOperation("The live-stack session is closed.")
        }
        guard state != .completed else { return }
        setState(.pausing, "Pausing and saving the live stack…")
        await stopIngestion()
        do {
            try await forcedCheckpoint()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw LiveStackRunError.checkpointFailed(error.localizedDescription)
        }
        checkpointBlocked = false
        setState(.paused, "Live stacking is paused and resumable.")
    }

    func updateCalibration(_ newCalibration: ImageStackCalibration) async throws {
        await lifecycleGate.acquire()
        defer { lifecycleGate.release() }
        try await updateCalibrationCore(newCalibration)
    }

    private func updateCalibrationCore(
        _ newCalibration: ImageStackCalibration
    ) async throws {
        if let message = newCalibration.validationMessage(for: []) {
            throw LiveStackRunError.invalidConfiguration(message)
        }
        guard let session else {
            calibration = newCalibration
            monitor.seedProcessedPaths(
                [newCalibration.bias, newCalibration.dark, newCalibration.flat]
                    .compactMap { $0?.path })
            addAttention("Calibration will apply when the first light arrives.")
            publish()
            return
        }
        await operationGate.acquire()
        do {
            setState(.checkpointing, "Updating calibration masters…")
            try await session.setCalibration(newCalibration)
            calibration = newCalibration
            calibrationHistory.append(LiveStackCalibrationEpoch(
                startsAtAcceptedFrame: acceptedFrames + 1,
                biasPath: newCalibration.bias.map { LiveStackPath.normalize($0.path) },
                darkPath: newCalibration.dark.map { LiveStackPath.normalize($0.path) },
                flatPath: newCalibration.flat.map { LiveStackPath.normalize($0.path) },
                darkExposureSeconds: newCalibration.overridesDarkExposure
                    ? newCalibration.darkExposureSeconds
                    : nil))
            monitor.seedProcessedPaths(
                [newCalibration.bias, newCalibration.dark, newCalibration.flat]
                    .compactMap { $0?.path })
            markCheckpointDirty()
            try await checkpointCore()
            operationGate.release()
            let (nextState, nextMessage) = runningStateAfterOperation()
            setState(nextState, nextMessage)
        } catch {
            operationGate.release()
            throw error
        }
    }

    private func ensureSafeOutputPath(_ path: String) throws {
        let normalized = LiveStackPath.normalize(path)
        for frame in frames where LiveStackPath.equals(frame.path, normalized) {
            throw LiveStackRunError.unsafeOutputPath(
                "Choose an output file that is not one of the stacked frames.")
        }
        if let initialReference = configuration.initialReferencePath,
            LiveStackPath.equals(initialReference, normalized) {
            throw LiveStackRunError.unsafeOutputPath(
                "Choose an output file that is not the reference frame.")
        }
        for epoch in calibrationHistory {
            for master in [epoch.biasPath, epoch.darkPath, epoch.flatPath] {
                if let master, LiveStackPath.equals(master, normalized) {
                    throw LiveStackRunError.unsafeOutputPath(
                        "Choose an output file that is not a calibration master.")
                }
            }
        }
        if LiveStackPath.isWithinDirectory(
            normalized, directory: store.groupDirectory.path) {
            throw LiveStackRunError.unsafeOutputPath(
                "Choose an output file outside the session checkpoint folder.")
        }
    }

    /// Writes a non-destructive FITS snapshot of the current accumulator.
    /// The export copy is taken under the gate; the write happens outside
    /// it so ingestion can continue.
    func saveSnapshot(to path: String) async throws -> LiveStackExportResult {
        await lifecycleGate.acquire()
        defer { lifecycleGate.release() }
        let normalized = LiveStackPath.normalize(path)
        try ensureSafeOutputPath(normalized)
        monitor.reservePath(normalized)

        await operationGate.acquire()
        let export: LiveStackExportSnapshot
        let rejectedAtSnapshot = nativeRejectedFrames + policyRejectedFrames
        do {
            guard let session else {
                throw LiveStackRunError.invalidOperation(
                    "There is no live stack to snapshot yet.")
            }
            setState(.savingSnapshot, "Saving a live-stack snapshot…")
            export = try await session.exportSnapshot()
            operationGate.release()
        } catch {
            operationGate.release()
            monitor.releaseReservedPath(normalized)
            let (nextState, nextMessage) = runningStateAfterOperation()
            setState(nextState, nextMessage)
            throw error
        }

        do {
            try await runBlocking {
                try export.writeFITS(to: normalized)
            }
            export.free()
        } catch {
            export.free()
            monitor.releaseReservedPath(normalized)
            let (nextState, nextMessage) = runningStateAfterOperation()
            setState(nextState, nextMessage)
            throw error
        }

        monitor.commitReservedPath(normalized)
        exportedPaths.append(normalized)
        markCheckpointDirty()
        do {
            try await forcedCheckpoint()
        } catch {
            throw LiveStackRunError.checkpointFailed(
                "The snapshot was saved to "
                    + "\(URL(fileURLWithPath: normalized).lastPathComponent), but its "
                    + "resumable checkpoint could not be updated. Live ingestion has "
                    + "been paused.")
        }
        let (nextState, _) = runningStateAfterOperation()
        setState(nextState,
            "Saved \(URL(fileURLWithPath: normalized).lastPathComponent).")
        return LiveStackExportResult(
            outputPath: normalized,
            acceptedFrames: export.acceptedFrames,
            rejectedFrames: rejectedAtSnapshot)
    }

    /// Finalizes the accumulator into its published FITS output, then
    /// retires the session. A failure after finalization leaves the
    /// pre-finalization checkpoint recoverable in a reopened window.
    func finish(to path: String) async throws -> LiveStackExportResult {
        await lifecycleGate.acquire()
        defer { lifecycleGate.release() }
        guard state != .completed else {
            throw LiveStackRunError.invalidOperation("The live stack is already complete.")
        }
        guard session != nil else {
            throw LiveStackRunError.invalidOperation(
                "There is no live stack to finish yet.")
        }
        await stopIngestion()
        let normalized = LiveStackPath.normalize(path)
        try ensureSafeOutputPath(normalized)
        outputPath = normalized
        markCheckpointDirty()
        await tryMeasureDepth(includeCurrentDepth: true)

        do {
            try await forcedCheckpoint()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw LiveStackRunError.checkpointFailed(error.localizedDescription)
        }
        try Task.checkCancellation()

        guard let session else {
            throw LiveStackRunError.invalidOperation(
                "There is no live stack to finish yet.")
        }
        setState(.finishing, "Finalizing the live stack…")
        nativeFinalized = true
        let snapshot: LiveStackFinishedSnapshot
        do {
            snapshot = try await session.finish()
        } catch {
            self.session = nil
            setState(.needsAttention,
                "Finalization failed; resume from the saved checkpoint.")
            throw error
        }
        self.session = nil

        do {
            try await runBlocking {
                try snapshot.writeFITS(to: normalized)
            }
        } catch {
            snapshot.free()
            setState(.needsAttention,
                "Export failed after finalization. Reopen this run from its "
                    + "checkpoint.")
            throw error
        }
        let acceptedAtFinish = snapshot.acceptedFrames
        snapshot.free()

        monitor.seedProcessedPaths([normalized])
        exportedPaths.append(normalized)
        do {
            try await store.retire(sessionId: sessionId)
        } catch {
            addAttention(
                "The completed session could not be retired: "
                    + error.localizedDescription)
        }
        setState(.completed,
            "Saved the completed stack to "
                + "\(URL(fileURLWithPath: normalized).lastPathComponent).")
        return LiveStackExportResult(
            outputPath: normalized,
            acceptedFrames: acceptedAtFinish,
            rejectedFrames: nativeRejectedFrames + policyRejectedFrames)
    }

    func dispose() async {
        await lifecycleGate.acquire()
        defer { lifecycleGate.release() }
        guard !disposed else { return }
        disposed = true
        await stopIngestion()
        if session != nil, checkpointDirty, !nativeFinalized {
            await operationGate.acquire()
            do {
                try await checkpointCore()
            } catch {
                addAttention(
                    "The final checkpoint could not be saved: "
                        + error.localizedDescription)
            }
            operationGate.release()
        }
        if let session {
            await session.close()
        }
        session = nil
        await store.close()
        setState(.disposed, "The live-stack session is closed.")
        for continuation in snapshotContinuations.values {
            continuation.finish()
        }
        snapshotContinuations.removeAll()
    }
}

private extension StackFileCandidate {
    var fileName: String {
        URL(fileURLWithPath: path).lastPathComponent
    }
}
