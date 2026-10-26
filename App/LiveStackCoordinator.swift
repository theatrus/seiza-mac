import Foundation

// MARK: - Run configuration

struct LiveStackRunConfiguration: Sendable {
    var watchFolder: String
    var sessionRootDirectory: URL
    var groupId = "live"
    var groupTitle = "Live stack"
    var targetFilter: LiveStackFilterIdentity? = nil
    var includeSubdirectories = false
    var resumeExisting = true
    var applyCalibrationOnResume = false
    var initialReferencePath: String? = nil
    var referenceImagePath: String? = nil
    var choosesReferenceAutomatically = false
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

    static let previewStretchTypes: [FITSStretchType] = [.autoMtf, .medianAnchor, .layered]

    static func previewProcessingJSON(for type: FITSStretchType) throws -> String {
        guard previewStretchTypes.contains(type) else {
            throw LiveStackRunError.invalidConfiguration("Choose an automatic live preview stretch.")
        }
        var stage = FITSStretchConfiguration.default
        stage.type = type
        var request = try JSONSerialization.jsonObject(with: Data(defaultPreviewProcessingJSON.utf8)) as! [String: Any]
        request["stretch"] = [try JSONSerialization.jsonObject(with: stage.jsonData)]
        return String(decoding: try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys]), as: UTF8.self)
    }

    func validationMessage() -> String? {
        if watchFolder.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Choose an existing capture folder."
        }
        if groupId.trimmingCharacters(in: .whitespaces).isEmpty
            || groupTitle.trimmingCharacters(in: .whitespaces).isEmpty {
            return "The live-stack group is not configured."
        }
        if options.canvasMode != .fixed { return "Live acquisition requires a fixed canvas." }
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
        if let referenceImagePath { excluded.append(LiveStackPath.normalize(referenceImagePath)) }
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
    var referenceImagePath: String? = nil
    var channelReferencePath: String? = nil
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
    /// Set when transient removal was requested but did not run, saying
    /// why; the live result was written instead.
    var transientNote: String? = nil
}

enum LiveStackRunError: LocalizedError {
    case invalidConfiguration(String)
    case invalidOperation(String)
    case unsafeOutputPath(String)
    case checkpointFailed(String)
    case calibrationPreparationFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message),
            .invalidOperation(let message),
            .unsafeOutputPath(let message),
            .calibrationPreparationFailed(let message):
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
    private var previewProcessingJSON: String
    private let sharedProcessingGate: AsyncGate?
    private let prepareCalibration: (@Sendable (CalibrationFrameProbe) async throws -> ImageStackCalibration)?
    private var calibrationPrepared = false
    private let referenceSelector: @Sendable ([URL]) throws -> StackReferenceSelection
    private let store: LiveStackSessionStore
    private let monitor: StackFolderMonitor
    private var savedOptionsJSON: String?
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
    private var activeReferenceImagePath: String?
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
    private var reintegrating = false
    private var initialized = false
    private var disposed = false

    private var ingestionTask: Task<Void, Never>?
    private var checkpointTimerTask: Task<Void, Never>?
    private let operationGate = AsyncGate()
    private let lifecycleGate = AsyncGate()

    private var snapshotContinuations: [UUID: AsyncStream<LiveStackRunSnapshot>.Continuation] = [:]

    private static let maximumAttentionItems = 50

    init(
        configuration: LiveStackRunConfiguration,
        sharedProcessingGate: AsyncGate? = nil,
        prepareCalibration: (@Sendable (CalibrationFrameProbe) async throws -> ImageStackCalibration)? = nil,
        referenceSelector: @escaping @Sendable ([URL]) throws -> StackReferenceSelection = { try StackReferenceSelector.choose($0) }
    ) throws {
        if let message = configuration.validationMessage() {
            throw LiveStackRunError.invalidConfiguration(message)
        }
        var normalized = configuration
        normalized.watchFolder = LiveStackPath.normalize(configuration.watchFolder)
        normalized.initialReferencePath = configuration.initialReferencePath
            .map { LiveStackPath.normalize($0) }
        normalized.referenceImagePath = StackInputProtection.referenceIdentity(configuration.referenceImagePath)
        self.configuration = normalized
        self.sharedProcessingGate = sharedProcessingGate
        self.prepareCalibration = prepareCalibration
        self.lockedFilter = normalized.targetFilter
        self.previewProcessingJSON = normalized.previewProcessingJSON
        self.activeReferenceImagePath = normalized.referenceImagePath
        self.referenceSelector = referenceSelector
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
            excludedDirectories: [normalized.sessionRootDirectory.path],
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
        snapshot.referenceImagePath = activeReferenceImagePath
        snapshot.channelReferencePath = frames.first { $0.disposition == .accepted }?.path
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
            await sharedProcessingGate?.acquire()
            defer { sharedProcessingGate?.release() }
            do {
                try await initialize()
                initialized = true
            } catch is CancellationError {
                if session != nil {
                    initialized = true
                    setState(.paused,
                        "Live-stack startup was cancelled; the open stack remains "
                            + "resumable.")
                } else {
                    if !Task.isCancelled, prepareCalibration != nil, !calibrationPrepared {
                        addAttention("Calibration preparation was cancelled; this filter is paused.")
                    }
                    setState(.paused, "Live-stack startup was cancelled before integrating a light.")
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
            let gpuJSON = try configuration.options.gpuJSON
            let updatedOptions = try configuration.options.applyingGPU(to: candidate.manifest.state.stackOptionsJSON)
            let restoredSession: LiveStackNativeSession
            let nativeState: LiveStackNativeState
            do {
                let contextPath = candidate.contextURL.path
                restoredSession = try await runBlocking {
                    try LiveStackNativeSession.resume(contextPath: contextPath, gpuJSON: gpuJSON)
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
            savedOptionsJSON = updatedOptions
            if updatedOptions != candidate.manifest.state.stackOptionsJSON {
                addAttention("Resumed with the current GPU mode and planning budget from Settings; saved frame history is retained.")
            }
            session = restoredSession
            do {
                try await restoreState(from: candidate.manifest, nativeState: nativeState)
            } catch {
                await restoredSession.close()
                session = nil
                throw error
            }
            if candidate.usedPreviousGeneration {
                addAttention(
                    "The current checkpoint was invalid; resumed the previous "
                        + "generation.")
            }
            restored = true
            break
        }

        if !restored, configuration.choosesReferenceAutomatically {
            if try await openAutomaticReference() { return }
        } else if !restored, let initialReference = configuration.initialReferencePath {
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
            && (configuration.targetFilter.map { $0.matches(.fromStoredName(state.filterName)) } ?? true)
            && state.includesSubdirectories == configuration.includeSubdirectories
            && ImageStackOptions.sameProcessingOptions(state.stackOptionsJSON, (try? optionsJSON()) ?? "")
            && (configuration.referenceImagePath == nil
                || StackInputProtection.referenceIdentity(state.referenceImagePath) == configuration.referenceImagePath)
    }

    private func optionsJSON() throws -> String {
        if let savedOptionsJSON { return savedOptionsJSON }
        return String(decoding: try configuration.options.jsonData, as: UTF8.self)
    }

    private func restoreState(
        from manifest: LiveStackGenerationManifest,
        nativeState: LiveStackNativeState
    ) async throws {
        let persisted = manifest.state
        guard StackInputProtection.referenceIdentity(persisted.referenceImagePath)
                == StackInputProtection.referenceIdentity(nativeState.referenceImagePath) else {
            throw LiveStackRunError.invalidOperation("The checkpoint alignment image does not match its native context.")
        }
        activeReferenceImagePath = StackInputProtection.referenceIdentity(nativeState.referenceImagePath)
        if let activeReferenceImagePath { monitor.reservePath(activeReferenceImagePath) }
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

    private func openAutomaticReference() async throws -> Bool {
        do {
            setState(.restoring, "Waiting for existing reference candidates to settle…")
            let config = configuration
            let observations = StackFolderMonitor(configuration: .init(
                watchFolder: config.watchFolder,
                includeSubdirectories: config.includeSubdirectories,
                excludedPaths: config.monitorExcludedPaths(),
                excludedDirectories: [config.sessionRootDirectory.path],
                tracker: .init(minimumStableDuration: config.monitorStabilityDuration)))
            _ = try await runBlocking { observations.observeReferenceCandidates() }
            try await Task.sleep(for: .seconds(max(0, config.monitorStabilityDuration)))
            let stable = try await runBlocking { observations.observeReferenceCandidates() }
            var eligible: [StackFileCandidate] = []
            var anchor: CalibrationFrameProbe?
            if let initial = config.initialReferencePath {
                anchor = try await runBlocking { try CalibrationService.probe(path: initial) }
            }
            for candidate in stable {
                try Task.checkCancellation()
                let probe = try await runBlocking { () -> CalibrationFrameProbe? in
                    guard StackFolderMonitor.isUnchanged(candidate),
                        let probe = try? CalibrationService.probe(path: candidate.path),
                        CalibrationLightEligibility.ineligibilityReason(probe) == nil,
                        StackFolderMonitor.isUnchanged(candidate)
                    else { return nil }
                    return probe
                }
                guard let probe else { continue }
                if let target = config.targetFilter, !target.matches(.fromProbe(probe)) { continue }
                if let anchor {
                    guard LiveStackFilterIdentity.fromProbe(anchor).matches(.fromProbe(probe)),
                        LiveStackCalibrationIdentity.mismatchReason(
                            reference: anchor.signature, candidate: probe.signature) == nil
                    else { continue }
                } else { anchor = probe }
                eligible.append(candidate)
            }
            guard !eligible.isEmpty else { return false }
            setState(.restoring, "Scoring \(eligible.count) reference candidates…")
            let urls = eligible.map { URL(fileURLWithPath: $0.path) }
            let selector = referenceSelector
            let selected = try await runBlocking { try selector(urls) }
            try selected.validate(paths: urls.map(\.path))
            try Task.checkCancellation()
            let candidate = eligible[selected.referenceIndex]
            let ranked = config.referenceImagePath == nil ? []
                : selected.candidateIndices.map { eligible[$0] }
            try await openInitialReference(candidate.path, expected: candidate, candidates: ranked)
            return true
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // A calibration failure is not an alignment-ranking failure.
            // Retrying through first-light ingestion would repeat preparation.
            if case LiveStackRunError.calibrationPreparationFailed = error { throw error }
            guard session == nil, configuration.referenceImagePath == nil else { throw error }
            addAttention("Could not choose a reference; waiting for the first stable light. "
                + error.localizedDescription)
            return false
        }
    }

    private func openInitialReference(
        _ referencePath: String, expected: StackFileCandidate? = nil, candidates: [StackFileCandidate] = []
    ) async throws {
        let probe = try await runBlocking {
            if let expected, !StackFolderMonitor.isUnchanged(expected) {
                throw LiveStackRunError.invalidOperation("The selected reference changed during scoring.")
            }
            return try CalibrationService.probe(path: referencePath)
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
        try Task.checkCancellation()
        try await openReference(probe: probe, reason: "Selected channel reference", expected: expected, candidates: candidates)
        seedCalibrationPaths()
        try await forcedCheckpoint()
        setState(.waitingForLight,
            "Channel reference ready; watching for more lights.")
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
        await sharedProcessingGate?.acquire()
        defer { sharedProcessingGate?.release() }
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
            if !Task.isCancelled, prepareCalibration != nil, !calibrationPrepared {
                addAttention("Calibration preparation was cancelled; this filter is paused.")
            }
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

        if let target = configuration.targetFilter, !target.matches(.fromProbe(probe)) {
            monitor.complete(candidate, disposition: .ignored)
            finishCandidate("Waiting for \(target.displayName) lights.")
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
                try await openReference(probe: probe, reason: "Reference frame", expected: candidate)
                monitor.complete(candidate, disposition: .accepted)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Preparation/review failure belongs to the filter, not the
                // light file. Stop it without retrying a modal review or
                // marking an otherwise readable light as unreadable.
                if prepareCalibration != nil, !calibrationPrepared { throw error }
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
        probe: CalibrationFrameProbe, reason: String, expected: StackFileCandidate? = nil,
        candidates: [StackFileCandidate] = []
    ) async throws {
        guard FileManager.default.fileExists(atPath: probe.path) else {
            throw LiveStackRunError.invalidOperation(
                "The reference frame is unavailable.")
        }
        if let target = configuration.targetFilter, !target.matches(.fromProbe(probe)) {
            throw LiveStackRunError.invalidConfiguration("The reference belongs to a different filter.")
        }
        if !calibrationPrepared, let prepareCalibration {
            setState(.processing, "Preparing calibration for \(configuration.targetFilter?.displayName ?? "this filter")…")
            do {
                calibration = try await prepareCalibration(probe)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw LiveStackRunError.calibrationPreparationFailed(error.localizedDescription)
            }
            calibrationPrepared = true
            seedCalibrationPaths()
        }
        let optionsJSONString = try optionsJSON()
        let referencePath = probe.path
        let referenceImagePath = activeReferenceImagePath
        let openCalibration = calibration
        let checkedCandidates = candidates.isEmpty ? [expected].compactMap { $0 } : candidates
        setState(.processing, referenceImagePath == nil
            ? "Opening channel reference…"
            : "Aligning channel reference to the shared image (up to \(max(1, candidates.count)) candidates)…")
        let opened = try await runBlocking {
            guard checkedCandidates.allSatisfy(StackFolderMonitor.isUnchanged) else {
                throw LiveStackRunError.invalidOperation("A channel reference changed during scoring.")
            }
            return try LiveStackNativeSession.open(
                referencePath: referencePath, optionsJSON: optionsJSONString,
                calibration: openCalibration, referenceImagePath: referenceImagePath,
                candidatePaths: candidates.map(\.path))
        }
        let selectedProbe: CalibrationFrameProbe
        do {
            guard checkedCandidates.allSatisfy(StackFolderMonitor.isUnchanged) else {
                throw LiveStackRunError.invalidOperation("A channel reference changed while opening.")
            }
            try Task.checkCancellation()
            let chosenPath = opened.channelReferencePath ?? probe.path
            selectedProbe = chosenPath == probe.path ? probe
                : try await runBlocking { try CalibrationService.probe(path: chosenPath) }
            if referenceImagePath != nil {
                let pushed = try await opened.push(path: chosenPath)
                guard pushed.disposition?.accepted == true else {
                    throw LiveStackRunError.invalidOperation(pushed.nativeError
                        ?? pushed.disposition?.reason ?? "The channel reference could not be integrated.")
                }
            }
            guard checkedCandidates.allSatisfy(StackFolderMonitor.isUnchanged) else {
                throw LiveStackRunError.invalidOperation("A channel reference changed while integrating.")
            }
            try Task.checkCancellation()
            let counts = try await opened.counts()
            guard counts.acceptedFrames == 1, counts.rejectedFrames == 0 else {
                throw LiveStackRunError.invalidOperation("The native live stack did not retain exactly one channel light.")
            }
        } catch {
            await opened.close()
            throw error
        }
        let probe = selectedProbe
        if let selection = opened.referenceSelection, !selection.skipped.isEmpty {
            addAttention(selection.summary)
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

    func setPreviewStretch(_ type: FITSStretchType) async throws {
        let json = try LiveStackRunConfiguration.previewProcessingJSON(for: type)
        await operationGate.acquire()
        defer { operationGate.release() }
        guard !disposed else { throw LiveStackSessionError.closed }
        previewProcessingJSON = json
        await tryRenderPreview(force: true)
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
                configJSON: previewProcessingJSON,
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
            snrSamples: snrSamples,
            referenceImagePath: activeReferenceImagePath)
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

    func validateOutputPath(_ path: String) throws {
        try ensureSafeOutputPath(path)
        let paths = frames.map(\.path) + calibrationHistory.flatMap {
            [$0.biasPath, $0.darkPath, $0.flatPath].compactMap { $0 }
        } + [configuration.initialReferencePath, activeReferenceImagePath].compactMap { $0 }
        try StackInputProtection.validate(output: URL(fileURLWithPath: path), sources: paths.map { URL(fileURLWithPath: $0) })
    }

    private func ensureSafeOutputPath(_ path: String) throws {
        let normalized = LiveStackPath.normalize(path)
        if let image = activeReferenceImagePath {
            try StackInputProtection.validate(output: URL(fileURLWithPath: path),
                sources: [URL(fileURLWithPath: image)])
        }
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
    func finish(to path: String, beforeRetiring: (@Sendable (LiveStackExportResult) async throws -> Void)? = nil) async throws -> LiveStackExportResult {
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
        let (reintegrated, transientNote) = await removeTransients(session)
        defer { reintegrated?.free() }

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

        let output = reintegrated ?? snapshot
        do {
            try await runBlocking {
                try output.writeFITS(to: normalized)
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
        if let beforeRetiring {
            do {
                try await beforeRetiring(.init(outputPath: normalized, acceptedFrames: acceptedAtFinish,
                    rejectedFrames: nativeRejectedFrames + policyRejectedFrames, transientNote: transientNote))
            } catch {
                setState(.needsAttention, "The output was saved, but session completion could not be recorded. Reopen the saved checkpoint.")
                throw error
            }
        }
        do {
            try await store.retire(sessionId: sessionId)
        } catch {
            addAttention(
                "The completed session could not be retired: "
                    + error.localizedDescription)
        }
        var completedMessage = "Saved the completed stack to "
            + "\(URL(fileURLWithPath: normalized).lastPathComponent)."
        if let transientNote {
            completedMessage += " \(transientNote)"
        }
        setState(.completed, completedMessage)
        return LiveStackExportResult(
            outputPath: normalized,
            acceptedFrames: acceptedAtFinish,
            rejectedFrames: nativeRejectedFrames + policyRejectedFrames,
            transientNote: transientNote)
    }

    /// Integrates every admitted frame again with leave-one-out rejection
    /// when the option is on and the stack can be replayed. Returns the new
    /// snapshot, or nil with a note saying why the live result must be used
    /// instead. Runs before `finish()` consumes the stacker.
    private func removeTransients(
        _ session: LiveStackNativeSession
    ) async -> (LiveStackFinishedSnapshot?, String?) {
        guard configuration.options.removesTransients else { return (nil, nil) }
        do {
            if let reason = try await session.state().reintegrationUnavailable {
                return (nil, "Transients were not removed: \(reason)")
            }
        } catch {
            return (nil, "Transients were not removed: \(error.localizedDescription)")
        }
        setState(.finishing, "Removing transients…")
        reintegrating = true
        defer { reintegrating = false }
        let sigmas = configuration.options.reintegrationSigmas
        do {
            let snapshot = try await session.reintegrate(
                lowSigma: sigmas.low,
                highSigma: sigmas.high
            ) { step in
                // About twenty status updates per pass is plenty.
                let stride = max(1, step.count / 20)
                guard step.index % stride == 0 else { return }
                Task { await self.reportReintegration(step) }
            }
            return (snapshot, nil)
        } catch {
            return (nil, "Transients were not removed: \(error.localizedDescription)")
        }
    }

    private func reportReintegration(_ step: LiveStackReintegrationProgress) {
        // Late updates must not overwrite the state that follows.
        guard reintegrating, state == .finishing else { return }
        setState(.finishing, step.message + "…")
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

// MARK: - A capture session with one independent accumulator per filter

struct LiveStackFilterGroupSnapshot: Identifiable, Sendable {
    var id: String { filter.key }
    var filter: LiveStackFilterIdentity
    var snapshot = LiveStackRunSnapshot()
    var completed = false
    var error: String?
    var outputPath: String?
    var displayTitle: String {
        "\(filter.displayName) · \(snapshot.acceptedFrames.formatted()) \(snapshot.acceptedFrames == 1 ? "frame" : "frames")\(completed ? " · Complete" : "")"
    }
}

struct LiveStackFilterSessionSnapshot: Sendable {
    var groups: [LiveStackFilterGroupSnapshot]
    var paused: Bool
    var status: String
}

/// Owns discovery and the registry. Child coordinators retain their own native
/// accumulator, admission gates, calibration history and checkpoint lease.
actor LiveStackFilterSession {
    private struct Entry: Codable {
        var name: String?
        var key: String
        var completed: Bool
        var acceptedFrames: Int
        var rejectedFrames: Int?
        var ignoredFrames: Int?
        var unreadableFrames: Int?
        var outputPath: String?
    }
    private struct Registry: Codable { var schemaVersion = 1; var filters: [Entry] }
    private let configuration: LiveStackRunConfiguration
    private let prepareCalibration: (@Sendable (CalibrationFrameProbe) async throws -> ImageStackCalibration)?
    private let calibrationGate = AsyncGate()
    // Assign children to two FIFO gates: at most two startup/ingestion calls
    // can enter native work, regardless of how many filters are discovered.
    private let processingGates = [AsyncGate(), AsyncGate()]
    private let monitor: StackFolderMonitor
    private let registryURL: URL
    private var lease: CalibrationFileLease?
    private var groups: [String: LiveStackFilterGroupSnapshot] = [:]
    private var children: [String: LiveStackCoordinator] = [:]
    private var observations: [String: Task<Void, Never>] = [:]
    private var starts: [String: Task<Void, Never>] = [:]
    private var discovery: Task<Void, Never>?
    private let lifecycleGate = AsyncGate()
    private var loaded = false
    private let previewGate = AsyncGate()
    private var disposed = false
    private var paused = true
    private var previewStretch: FITSStretchType?
    private var status = "Waiting for filter groups."
    private var continuations: [UUID: AsyncStream<LiveStackFilterSessionSnapshot>.Continuation] = [:]

    init(configuration: LiveStackRunConfiguration,
         prepareCalibration: (@Sendable (CalibrationFrameProbe) async throws -> ImageStackCalibration)? = nil) throws {
        if let message = configuration.validationMessage() { throw LiveStackRunError.invalidConfiguration(message) }
        self.configuration = configuration
        self.prepareCalibration = prepareCalibration
        registryURL = configuration.sessionRootDirectory.appendingPathComponent("filters.json")
        monitor = StackFolderMonitor(configuration: .init(watchFolder: configuration.watchFolder,
            includeSubdirectories: configuration.includeSubdirectories,
            excludedPaths: configuration.monitorExcludedPaths(),
            excludedDirectories: [configuration.sessionRootDirectory.path],
            scanInterval: configuration.monitorScanInterval,
            tracker: .init(minimumStableDuration: configuration.monitorStabilityDuration)))
    }

    func currentSnapshot() -> LiveStackFilterSessionSnapshot {
        .init(groups: groups.values.sorted { $0.filter.displayName.localizedStandardCompare($1.filter.displayName) == .orderedAscending },
              paused: paused, status: status)
    }

    func snapshots() -> AsyncStream<LiveStackFilterSessionSnapshot> {
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.yield(currentSnapshot())
            continuation.onTermination = { [weak self] _ in Task { await self?.removeContinuation(id) } }
        }
    }
    private func removeContinuation(_ id: UUID) { continuations[id] = nil }
    private func publish() { let snapshot = currentSnapshot(); for continuation in continuations.values { continuation.yield(snapshot) } }
    func coordinator(for key: String) -> LiveStackCoordinator? { children[key] }

    private func addGroup(_ filter: LiveStackFilterIdentity, completed: Bool = false,
                          acceptedFrames: Int = 0, outputPath: String? = nil) throws {
        guard children[filter.key] == nil else { return }
        var config = configuration
        config.groupId = "filter-" + filter.key
        config.groupTitle = filter.displayName
        config.targetFilter = filter
        if let previewStretch { config.previewProcessingJSON = try LiveStackRunConfiguration.previewProcessingJSON(for: previewStretch) }
        config.initialReferencePath = nil
        config.applyCalibrationOnResume = prepareCalibration == nil && configuration.applyCalibrationOnResume
        let gate = calibrationGate
        let callback: (@Sendable (CalibrationFrameProbe) async throws -> ImageStackCalibration)?
        if let operation = prepareCalibration {
            callback = { probe in
                await gate.acquire()
                defer { gate.release() }
                try Task.checkCancellation()
                return try await operation(probe)
            }
        } else {
            callback = nil
        }
        let child = try LiveStackCoordinator(configuration: config,
            sharedProcessingGate: processingGates[children.count % processingGates.count], prepareCalibration: callback)
        children[filter.key] = child
        var value = LiveStackFilterGroupSnapshot(filter: filter, completed: completed, outputPath: outputPath)
        if completed { value.snapshot.state = .completed; value.snapshot.acceptedFrames = acceptedFrames; value.snapshot.statusMessage = "Completed stack" }
        groups[filter.key] = value
        if !completed {
            observations[filter.key] = Task { [weak self] in
                for await snapshot in await child.snapshots() { await self?.update(filter.key, snapshot: snapshot) }
            }
        }
    }

    private func update(_ key: String, snapshot: LiveStackRunSnapshot) {
        guard !disposed, groups[key] != nil else { return }
        groups[key]?.snapshot = snapshot
        publish()
    }
    private func recordError(_ key: String, _ message: String) { groups[key]?.error = message; publish() }
    private func startChild(_ key: String) {
        guard let child = children[key], groups[key]?.completed == false, starts[key] == nil else { return }
        groups[key]?.error = nil
        starts[key] = Task { [weak self] in
            do { try await child.start() }
            catch is CancellationError {}
            catch { await self?.recordError(key, error.localizedDescription) }
            await self?.finishedStarting(key)
        }
    }
    private func finishedStarting(_ key: String) { starts[key] = nil }

    func start() async throws {
        await lifecycleGate.acquire(); defer { lifecycleGate.release() }
        guard !disposed else { throw LiveStackSessionError.closed }
        guard paused else { return }
        if lease == nil {
            try FileManager.default.createDirectory(at: configuration.sessionRootDirectory, withIntermediateDirectories: true)
            guard let acquired = CalibrationFileLease.tryAcquireExclusive(at: configuration.sessionRootDirectory.appendingPathComponent("filters.lock")) else {
                throw LiveStackRunError.invalidOperation("This multi-filter capture session is already open in another window.")
            }
            lease = acquired
        }
        if !loaded {
            if configuration.resumeExisting, FileManager.default.fileExists(atPath: registryURL.path) {
                let registry = try JSONDecoder().decode(Registry.self, from: Data(contentsOf: registryURL))
                guard registry.schemaVersion == 1 else { throw LiveStackRunError.invalidConfiguration("Unsupported live filter registry.") }
                var keys = Set<String>()
                for entry in registry.filters {
                    let filter = LiveStackFilterIdentity.fromStoredName(entry.name)
                    guard filter.key == entry.key, keys.insert(entry.key).inserted else {
                        throw LiveStackRunError.invalidConfiguration("The saved filter registry is inconsistent.")
                    }
                }
                for entry in registry.filters {
                    let filter = LiveStackFilterIdentity.fromStoredName(entry.name)
                    try addGroup(filter, completed: entry.completed,
                                 acceptedFrames: entry.acceptedFrames, outputPath: entry.outputPath)
                    if entry.completed {
                        groups[filter.key]?.snapshot.rejectedFrames = entry.rejectedFrames ?? 0
                        groups[filter.key]?.snapshot.ignoredFrames = entry.ignoredFrames ?? 0
                        groups[filter.key]?.snapshot.unreadableFrames = entry.unreadableFrames ?? 0
                    }
                }
            }
            loaded = true
        }
        paused = false
        for key in children.keys { startChild(key) }
        let candidates = monitor.candidates()
        discovery = Task { [weak self] in
            for await candidate in candidates {
                if Task.isCancelled { break }
                await self?.discover(candidate)
            }
        }
        status = "Watching all filters; new groups appear as complete lights arrive."
        publish()
    }

    private func discover(_ candidate: StackFileCandidate) async {
        guard !disposed, !paused else { return }
        do {
            let probe = try await runBlocking { try CalibrationService.probe(path: candidate.path) }
            guard !disposed, !paused, monitor.isCandidateCurrent(candidate), StackFolderMonitor.isUnchanged(candidate) else { return }
            if CalibrationLightEligibility.ineligibilityReason(probe) == nil {
                let filter = LiveStackFilterIdentity.fromProbe(probe)
                if children[filter.key] == nil { try addGroup(filter) }
                if groups[filter.key]?.completed == false, groups[filter.key]?.snapshot.state == .created, starts[filter.key] == nil {
                    // Persist before starting a native accumulator.
                    try saveRegistry()
                    startChild(filter.key)
                    status = "Discovered \(filter.displayName); watching \(groups.count) filter groups."
                    publish()
                }
            }
            monitor.complete(candidate, disposition: .accepted)
        } catch {
            monitor.complete(candidate, disposition: .retryableFailure)
            status = "Could not inspect \(URL(fileURLWithPath: candidate.path).lastPathComponent): \(error.localizedDescription)"
            publish()
        }
    }

    private func saveRegistry() throws {
        let entries = currentSnapshot().groups.map {
            Entry(name: $0.filter.source == .unspecified ? nil : $0.filter.displayName,
                  key: $0.filter.key, completed: $0.completed,
                  acceptedFrames: $0.snapshot.acceptedFrames, rejectedFrames: $0.snapshot.rejectedFrames,
                  ignoredFrames: $0.snapshot.ignoredFrames, unreadableFrames: $0.snapshot.unreadableFrames,
                  outputPath: $0.outputPath)
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(Registry(filters: entries)).write(to: registryURL, options: .atomic)
    }

    func pauseAndSave() async throws {
        await lifecycleGate.acquire(); defer { lifecycleGate.release() }
        paused = true
        discovery?.cancel(); monitor.stop()
        await discovery?.value; discovery = nil
        let starting = Array(starts.values)
        for task in starting { task.cancel() }
        for task in starting { await task.value }
        var failures: [String] = []
        for (key, child) in children where groups[key]?.completed == false {
            do { try await child.pauseAndSave() }
            catch { failures.append("\(groups[key]?.filter.displayName ?? key): \(error.localizedDescription)") }
            let snapshot = await child.currentSnapshot()
            groups[key]?.snapshot = snapshot
        }
        try saveRegistry()
        status = failures.isEmpty ? "All filter stacks paused and saved." : failures.joined(separator: "\n")
        publish()
        if !failures.isEmpty { throw LiveStackRunError.checkpointFailed(status) }
    }

    private func validateOutputPath(_ path: String) async throws {
        let root = URL(fileURLWithPath: configuration.watchFolder).resolvingSymlinksInPath().standardizedFileURL.path
        let output = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        guard output != root, !output.hasPrefix(root + "/") else {
            throw LiveStackRunError.unsafeOutputPath("Save outputs outside the capture folder so no filter ingests an exported stack.")
        }
        let sessionRoot = configuration.sessionRootDirectory.resolvingSymlinksInPath().standardizedFileURL.path
        guard output != sessionRoot, !output.hasPrefix(sessionRoot + "/") else {
            throw LiveStackRunError.unsafeOutputPath("Choose an output outside the session checkpoint folder.")
        }
        var metadata = [registryURL]
        if let files = FileManager.default.enumerator(at: configuration.sessionRootDirectory,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) {
            while let url = files.nextObject() as? URL {
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                if values?.isSymbolicLink == true { files.skipDescendants() }
                if values?.isRegularFile == true { metadata.append(url) }
            }
        }
        try StackInputProtection.validate(output: URL(fileURLWithPath: path), sources: metadata)
        for child in children.values { try await child.validateOutputPath(path) }
    }

    func saveSnapshot(for key: String, to path: String) async throws -> LiveStackExportResult {
        guard let child = children[key], groups[key]?.completed == false else { throw LiveStackSessionError.closed }
        try await validateOutputPath(path)
        return try await child.saveSnapshot(to: path)
    }

    func finish(_ key: String, to path: String) async throws -> LiveStackExportResult {
        await lifecycleGate.acquire(); defer { lifecycleGate.release() }
        guard let child = children[key], groups[key]?.completed == false else { throw LiveStackSessionError.closed }
        try await validateOutputPath(path)
        let result = try await child.finish(to: path) { result in try await self.recordCompletion(key, result: result) }
        let snapshot = await child.currentSnapshot()
        groups[key]?.snapshot = snapshot
        publish()
        return result
    }

    private func recordCompletion(_ key: String, result: LiveStackExportResult) throws {
        groups[key]?.completed = true
        groups[key]?.outputPath = result.outputPath
        groups[key]?.snapshot.state = .completed
        groups[key]?.snapshot.acceptedFrames = result.acceptedFrames
        do { try saveRegistry() }
        catch { groups[key]?.completed = false; publish(); throw error }
        publish()
    }

    func setPreviewStretch(_ type: FITSStretchType) async throws {
        await previewGate.acquire(); defer { previewGate.release() }
        _ = try LiveStackRunConfiguration.previewProcessingJSON(for: type)
        previewStretch = type
        for (key, child) in children where groups[key]?.completed == false { try await child.setPreviewStretch(type) }
    }

    func dispose() async {
        await lifecycleGate.acquire(); defer { lifecycleGate.release() }
        guard !disposed else { return }
        paused = true; discovery?.cancel(); monitor.stop()
        await discovery?.value; discovery = nil
        let starting = Array(starts.values)
        for task in starting { task.cancel() }
        for task in starting { await task.value }
        for child in children.values { await child.dispose() }
        for task in observations.values { task.cancel() }
        observations.removeAll(); children.removeAll()
        lease?.release(); lease = nil; disposed = true
        for continuation in continuations.values { continuation.finish() }
        continuations.removeAll()
    }
}
