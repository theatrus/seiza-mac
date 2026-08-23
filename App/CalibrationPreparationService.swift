import CryptoKit
import Foundation

// MARK: - Request, options, progress, result

struct CalibrationPreparationOptions: Sendable {
    var minimumBiasFrames = 2
    var minimumDarkFrames = 2
    var minimumDarkFlatFrames = 2
    var minimumFlatFrames = 2
    var tolerances = CalibrationPlanTolerances()
    var flatDefectSuppression: CalibrationDefectSuppression? = CalibrationDefectSuppression()
    var maximumProbeConcurrency = 4
    var maximumCacheBytes: Int64? = 8 * 1024 * 1024 * 1024
    var maximumCacheAge: TimeInterval? = 30 * 24 * 60 * 60
}

struct CalibrationPreparationRequest: Sendable {
    var reference: CalibrationFrameProbe
    /// Every light the prepared set must satisfy. The reference is always
    /// included; an empty list prepares for the reference alone.
    var targetLights: [CalibrationFrameProbe] = []
    var sourcePaths: [String]
    var cacheDirectory: URL
    /// Masters produced earlier in the same batch, protected from pruning.
    var protectedMasterPaths: [String] = []
    var options = CalibrationPreparationOptions()
}

struct CalibrationPreparationProgress: Sendable {
    enum Stage: Sendable {
        case discovering
        case probing
        case planning
        case building
        case completed
    }

    var stage: Stage
    var message: String
    var completed = 0
    var total = 0
}

struct CalibrationPreparationKindSummary: Sendable {
    var kind: String
    var masterPath: String? = nil
    var cacheReused = false
    var warning: String? = nil
    var fingerprint: String? = nil
    var build: CalibrationMasterBuildResult? = nil
}

/// The prepared master set. Holds retention leases that pin the cached
/// masters against pruning while the result is alive; release it when the
/// stack that uses the masters has finished.
final class CalibrationPreparationResult: @unchecked Sendable {
    let calibration: ImageStackCalibration
    let summaries: [CalibrationPreparationKindSummary]
    let warnings: [String]
    private let leaseStore: CalibrationLeaseStore

    init(
        calibration: ImageStackCalibration,
        summaries: [CalibrationPreparationKindSummary],
        warnings: [String],
        leases: [CalibrationFileLease]
    ) {
        self.calibration = calibration
        self.summaries = summaries
        self.warnings = warnings
        self.leaseStore = CalibrationLeaseStore(leases: leases)
    }

    func release() {
        leaseStore.release()
    }
}

private final class CalibrationLeaseStore: @unchecked Sendable {
    private let lock = NSLock()
    private var leases: [CalibrationFileLease]

    init(leases: [CalibrationFileLease]) {
        self.leases = leases
    }

    func release() {
        let released = lock.withLock {
            let current = leases
            leases = []
            return current
        }
        for lease in released {
            lease.release()
        }
    }

    deinit {
        release()
    }
}

enum CalibrationPreparationError: LocalizedError {
    case invalidRequest(String)

    var errorDescription: String? {
        switch self {
        case .invalidRequest(let message):
            return message
        }
    }
}

// MARK: - File leases

/// A `flock`-backed lease on a marker file. Exclusive leases guard builds
/// and deletions; shared leases retain cache entries against pruning.
final class CalibrationFileLease: @unchecked Sendable {
    private var descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    static func acquireShared(at url: URL) async throws -> CalibrationFileLease {
        while true {
            if let lease = try acquire(at: url, operation: LOCK_SH) {
                return lease
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    static func acquireExclusive(at url: URL) async throws -> CalibrationFileLease {
        while true {
            if let lease = try acquire(at: url, operation: LOCK_EX) {
                return lease
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    static func tryAcquireExclusive(at url: URL) -> CalibrationFileLease? {
        try? acquire(at: url, operation: LOCK_EX)
    }

    private static func acquire(
        at url: URL, operation: Int32
    ) throws -> CalibrationFileLease? {
        let descriptor = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else {
            throw CalibrationServiceError.core(
                "Could not open the calibration lease file at \(url.path).")
        }
        if flock(descriptor, operation | LOCK_NB) != 0 {
            let failure = errno
            close(descriptor)
            if failure == EWOULDBLOCK || failure == EAGAIN {
                return nil
            }
            throw CalibrationServiceError.core(
                "Could not lease the calibration file at \(url.path).")
        }
        return CalibrationFileLease(descriptor: descriptor)
    }

    func release() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }

    deinit {
        release()
    }
}

/// In-process exclusive locks keyed by master path, so two preparations in
/// one app instance never race a build or a prune of the same master.
actor CalibrationCacheLocks {
    static let shared = CalibrationCacheLocks()

    private var busy: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    static func key(for masterPath: String) -> String {
        LiveStackPath.normalize(masterPath).lowercased()
    }

    func acquire(_ key: String) async {
        if !busy.contains(key) {
            busy.insert(key)
            return
        }
        await withCheckedContinuation { continuation in
            waiters[key, default: []].append(continuation)
        }
    }

    func tryAcquire(_ key: String) -> Bool {
        guard !busy.contains(key) else { return false }
        busy.insert(key)
        return true
    }

    func release(_ key: String) {
        if var pending = waiters[key], !pending.isEmpty {
            let next = pending.removeFirst()
            if pending.isEmpty {
                waiters[key] = nil
            } else {
                waiters[key] = pending
            }
            next.resume()
        } else {
            busy.remove(key)
        }
    }
}

// MARK: - Cache report

struct CalibrationMasterCacheReport: Codable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion = CalibrationMasterCacheReport.currentSchemaVersion
    var kind: String
    var fingerprint: String
    var coreVersion: String
    var masterPath: String
    var masterLength: Int64
    var masterLastWriteUnixNanoseconds: Int64
    var build: CalibrationMasterBuildResult
}

// MARK: - Preparation service

/// Prepares a common safe master set for a group of target lights: probes a
/// raw calibration library, delegates matching to the native planner, builds
/// bias, dark, dark-flat, and flat masters in dependency order, refuses an
/// unsafe flat, and caches masters under a content fingerprint.
struct CalibrationPreparationService {
    static let flatPedestalWarning =
        "Matched flat frames were found, but no verified pedestal-removal path is "
        + "available. A master bias, or an uncalibrated master dark-flat/dark with "
        + "known exposure matching every flat, is required. The master flat was withheld."

    private struct InputIdentity: Equatable {
        var path: String
        var length: Int64
        var modifiedNanoseconds: Int64
    }

    private struct KindOutcome {
        var summary: CalibrationPreparationKindSummary
        var warnings: [String] = []
        var lease: CalibrationFileLease? = nil
    }

    func prepare(
        _ request: CalibrationPreparationRequest,
        progress: @escaping @Sendable (CalibrationPreparationProgress) -> Void = { _ in }
    ) async throws -> CalibrationPreparationResult {
        try validate(request)
        var warnings: [String] = []

        let targets = try normalizedTargets(for: request)
        let tolerances = request.options.tolerances
        let resolvedTolerances = CalibrationMatchTolerances.resolve(tolerances)

        try FileManager.default.createDirectory(
            at: request.cacheDirectory, withIntermediateDirectories: true)

        progress(CalibrationPreparationProgress(
            stage: .discovering, message: "Finding calibration frames."))
        let discovered = discoverFiles(request, warnings: &warnings)
        try Task.checkCancellation()

        let probeOutcome = await probeCandidates(
            discovered,
            concurrency: request.options.maximumProbeConcurrency,
            progress: progress)
        try Task.checkCancellation()
        warnings.append(contentsOf: probeOutcome.warnings)

        var candidates = probeOutcome.probes
        let ignoredMasters = candidates.filter(\.isMaster).count
        if ignoredMasters > 0 {
            let plural = ignoredMasters == 1 ? "" : "s"
            warnings.append(
                "Ignored \(ignoredMasters) existing calibration master\(plural); "
                    + "automatic preparation uses raw frames only.")
        }
        let ignoredPreprocessed = candidates
            .filter { !$0.isMaster && !$0.calibrationState.isRaw }
            .count
        if ignoredPreprocessed > 0 {
            let plural = ignoredPreprocessed == 1 ? "" : "s"
            warnings.append(
                "Ignored \(ignoredPreprocessed) preprocessed calibration frame\(plural); "
                    + "automatic preparation uses raw frames only.")
        }
        candidates = candidates.filter(\.isRawCandidate)
        let candidateRecords = candidates.map(CalibrationPlanRecord.init)
        let candidatesByPath = Dictionary(
            candidates.map { (LiveStackPath.normalize($0.path).lowercased(), $0) },
            uniquingKeysWith: { first, _ in first })

        let targetRecords = targets.map(CalibrationPlanRecord.init)
        let referenceRecord = targetRecords[0]
        let coreVersion = SeizaCore.version
        var leases: [CalibrationFileLease] = []
        var summaries: [CalibrationPreparationKindSummary] = []
        func adopt(_ outcome: KindOutcome) {
            summaries.append(outcome.summary)
            warnings.append(contentsOf: outcome.warnings)
            if let warning = outcome.summary.warning {
                warnings.append(warning)
            }
            if let lease = outcome.lease {
                leases.append(lease)
            }
        }

        do {
            // Bias.
            let bias = try await prepareKind(
                kind: CalibrationFrameRole.bias,
                nativeKind: CalibrationFrameRole.bias,
                planReference: referenceRecord,
                planReferences: targetRecords,
                candidates: candidateRecords,
                candidatesByPath: candidatesByPath,
                minimum: request.options.minimumBiasFrames,
                biasAvailable: false,
                biasSummary: nil,
                darkSummary: nil,
                defectSuppression: nil,
                request: request,
                tolerances: tolerances,
                coreVersion: coreVersion,
                progress: progress)
            adopt(bias)

            // Dark.
            let biasAvailable = bias.summary.masterPath != nil
            let dark = try await prepareKind(
                kind: CalibrationFrameRole.dark,
                nativeKind: CalibrationFrameRole.dark,
                planReference: referenceRecord,
                planReferences: targetRecords,
                candidates: candidateRecords,
                candidatesByPath: candidatesByPath,
                minimum: request.options.minimumDarkFrames,
                biasAvailable: biasAvailable,
                biasSummary: bias.summary,
                darkSummary: nil,
                defectSuppression: nil,
                request: request,
                tolerances: tolerances,
                coreVersion: coreVersion,
                progress: progress)
            adopt(dark)

            // Flat plan, dark-flat, pedestal gate, flat build, verification.
            let unresolvedFilterTargets = targets.contains { target in
                let filter = target.signature.filter?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return filter.isEmpty
            }
            if unresolvedFilterTargets {
                adopt(KindOutcome(summary: CalibrationPreparationKindSummary(
                    kind: CalibrationFrameRole.darkFlat,
                    warning: "Dark-flat preparation was skipped because no flat "
                        + "master can be built.")))
                adopt(KindOutcome(summary: CalibrationPreparationKindSummary(
                    kind: CalibrationFrameRole.flat,
                    warning: "The master flat was withheld because at least one "
                        + "target light has no FILTER header or recognized filename "
                        + "filter. Seiza cannot prove which optical response belongs "
                        + "to that light.")))
            } else {
                let (flatPlan, flatPlanWarnings) = await planKind(
                    kind: CalibrationFrameRole.flat,
                    reference: referenceRecord,
                    references: targetRecords,
                    candidates: candidateRecords,
                    minimum: request.options.minimumFlatFrames,
                    biasAvailable: biasAvailable,
                    tolerances: tolerances,
                    progress: progress,
                    progressMessage: "Matching raw flat frames to every target light.")
                warnings.append(contentsOf: flatPlanWarnings)
                try Task.checkCancellation()

                let selectedFlatProbes = flatPlan.selectedPaths.compactMap { path in
                    candidatesByPath[LiveStackPath.normalize(path).lowercased()]
                }
                let selectedFlatsAreRaw =
                    selectedFlatProbes.count == flatPlan.selectedPaths.count
                    && selectedFlatProbes.allSatisfy {
                        $0.role == CalibrationFrameRole.flat && $0.isRawCandidate
                    }

                var darkFlat = KindOutcome(summary: CalibrationPreparationKindSummary(
                    kind: CalibrationFrameRole.darkFlat))
                if flatPlan.ready && selectedFlatsAreRaw,
                    let firstFlat = selectedFlatProbes.first {
                    darkFlat = try await prepareKind(
                        kind: CalibrationFrameRole.darkFlat,
                        nativeKind: CalibrationFrameRole.dark,
                        planReference: CalibrationPlanRecord(probe: firstFlat),
                        planReferences: selectedFlatProbes.map(CalibrationPlanRecord.init),
                        candidates: candidateRecords,
                        candidatesByPath: candidatesByPath,
                        minimum: request.options.minimumDarkFlatFrames,
                        biasAvailable: biasAvailable,
                        biasSummary: bias.summary,
                        darkSummary: nil,
                        defectSuppression: nil,
                        request: request,
                        tolerances: tolerances,
                        coreVersion: coreVersion,
                        progress: progress,
                        planProgressMessage:
                            "Matching raw dark-flat frames to the selected flat.")
                } else if flatPlan.ready {
                    darkFlat.summary.warning =
                        "Dark-flat preparation was skipped because the selected flat "
                        + "was invalid."
                } else {
                    darkFlat.summary.warning =
                        "Dark-flat preparation was skipped because no flat master "
                        + "can be built."
                }
                adopt(darkFlat)

                let flatOutcome = try await buildFlat(
                    flatPlan: flatPlan,
                    selectedFlatProbes: selectedFlatProbes,
                    bias: bias.summary,
                    dark: dark.summary,
                    darkFlat: darkFlat.summary,
                    targets: targets,
                    candidatesByPath: candidatesByPath,
                    request: request,
                    resolvedTolerances: resolvedTolerances,
                    coreVersion: coreVersion,
                    progress: progress)
                adopt(flatOutcome)
            }

            let pruneWarnings = await pruneCache(
                request: request,
                producedMasterPaths: summaries.compactMap(\.masterPath))
            warnings.append(contentsOf: pruneWarnings)

            progress(CalibrationPreparationProgress(
                stage: .completed,
                message: "Calibration preparation is complete.",
                completed: discovered.count,
                total: discovered.count))

            let calibration = ImageStackCalibration(
                bias: summaries.first { $0.kind == CalibrationFrameRole.bias }?
                    .masterPath.map { URL(fileURLWithPath: $0) },
                dark: summaries.first { $0.kind == CalibrationFrameRole.dark }?
                    .masterPath.map { URL(fileURLWithPath: $0) },
                flat: summaries.first { $0.kind == CalibrationFrameRole.flat }?
                    .masterPath.map { URL(fileURLWithPath: $0) })
            return CalibrationPreparationResult(
                calibration: calibration,
                summaries: summaries,
                warnings: warnings,
                leases: leases)
        } catch {
            for lease in leases {
                lease.release()
            }
            throw error
        }
    }

    // MARK: Validation and targets

    private func validate(_ request: CalibrationPreparationRequest) throws {
        func requireEligible(_ probe: CalibrationFrameProbe) throws {
            if let reason = CalibrationLightEligibility.ineligibilityReason(probe) {
                throw CalibrationPreparationError.invalidRequest(
                    "Automatic calibration requires a raw light frame; \(reason).")
            }
        }
        try requireEligible(request.reference)
        for target in request.targetLights {
            try requireEligible(target)
        }
        guard !request.sourcePaths.isEmpty else {
            throw CalibrationPreparationError.invalidRequest(
                "Choose at least one calibration folder or file.")
        }
        guard !request.cacheDirectory.path.trimmingCharacters(in: .whitespaces).isEmpty
        else {
            throw CalibrationPreparationError.invalidRequest(
                "Choose a calibration cache directory.")
        }
        for (kind, minimum) in [
            (CalibrationFrameRole.bias, request.options.minimumBiasFrames),
            (CalibrationFrameRole.dark, request.options.minimumDarkFrames),
            (CalibrationFrameRole.darkFlat, request.options.minimumDarkFlatFrames),
            (CalibrationFrameRole.flat, request.options.minimumFlatFrames),
        ] where minimum < 2 {
            throw CalibrationPreparationError.invalidRequest(
                "The minimum \(kind) frame count must be at least two.")
        }
        guard (1...64).contains(request.options.maximumProbeConcurrency) else {
            throw CalibrationPreparationError.invalidRequest(
                "Probe concurrency must be between 1 and 64.")
        }
        if let maximumBytes = request.options.maximumCacheBytes, maximumBytes <= 0 {
            throw CalibrationPreparationError.invalidRequest(
                "The calibration cache size limit must be positive.")
        }
        if let maximumAge = request.options.maximumCacheAge, maximumAge <= 0 {
            throw CalibrationPreparationError.invalidRequest(
                "The calibration cache age limit must be positive.")
        }
    }

    private func normalizedTargets(
        for request: CalibrationPreparationRequest
    ) throws -> [CalibrationFrameProbe] {
        var ordered: [CalibrationFrameProbe] = []
        var byPath: [String: CalibrationFrameProbe] = [:]
        for probe in [request.reference] + request.targetLights {
            var normalized = probe
            normalized.path = LiveStackPath.normalize(probe.path)
            let key = normalized.path.lowercased()
            if let existing = byPath[key] {
                let sameMetadata = existing.role == normalized.role
                    && existing.isMaster == normalized.isMaster
                    && existing.signature == normalized.signature
                    && existing.calibrationState == normalized.calibrationState
                guard sameMetadata else {
                    throw CalibrationPreparationError.invalidRequest(
                        "Target light \(normalized.path) was supplied with "
                            + "conflicting metadata.")
                }
                continue
            }
            byPath[key] = normalized
            ordered.append(normalized)
        }
        return ordered.map(CalibrationTargetMetadata.enrich)
    }

    // MARK: Discovery and probing

    private func discoverFiles(
        _ request: CalibrationPreparationRequest,
        warnings: inout [String]
    ) -> [String] {
        var results: Set<String> = []
        let cachePath = request.cacheDirectory.path
        for sourcePath in request.sourcePaths {
            let trimmed = sourcePath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                warnings.append("Ignored an empty calibration source path.")
                continue
            }
            let source = LiveStackPath.normalize(trimmed)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: source, isDirectory: &isDirectory)
            else {
                warnings.append("Calibration source does not exist: \(source)")
                continue
            }
            if !isDirectory.boolValue {
                if !isAstronomyImage(source) {
                    warnings.append("Ignored unsupported calibration file \(source).")
                } else if !LiveStackPath.isWithinDirectory(source, directory: cachePath) {
                    results.insert(source)
                }
                continue
            }
            let enumerator = FileManager.default.enumerator(
                at: URL(fileURLWithPath: source),
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            while let entry = enumerator?.nextObject() as? URL {
                let values = try? entry.resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                if values?.isSymbolicLink == true {
                    enumerator?.skipDescendants()
                    continue
                }
                guard values?.isRegularFile == true else { continue }
                let path = LiveStackPath.normalize(entry.path)
                if isAstronomyImage(path),
                    !LiveStackPath.isWithinDirectory(path, directory: cachePath) {
                    results.insert(path)
                }
            }
        }
        return results.sorted {
            $0.caseInsensitiveCompare($1) == .orderedAscending
        }
    }

    private func isAstronomyImage(_ path: String) -> Bool {
        ImageCollection.isStackableImage(URL(fileURLWithPath: path))
    }

    private struct ProbeOutcome {
        var probes: [CalibrationFrameProbe]
        var warnings: [String]
    }

    private func probeCandidates(
        _ paths: [String],
        concurrency: Int,
        progress: @escaping @Sendable (CalibrationPreparationProgress) -> Void
    ) async -> ProbeOutcome {
        enum ProbeTaskResult: Sendable {
            case probed(CalibrationFrameProbe)
            case failed(path: String, message: String)
        }

        let total = paths.count
        var probes: [CalibrationFrameProbe] = []
        var failures: [(path: String, message: String)] = []
        var completed = 0
        await withTaskGroup(of: ProbeTaskResult.self) { group in
            var iterator = paths.makeIterator()
            var inFlight = 0
            func enqueueNext() {
                guard let path = iterator.next() else { return }
                inFlight += 1
                group.addTask {
                    do {
                        return .probed(try await runBlocking {
                            try CalibrationService.probe(path: path)
                        })
                    } catch {
                        return .failed(path: path, message: error.localizedDescription)
                    }
                }
            }
            for _ in 0..<max(1, concurrency) {
                enqueueNext()
            }
            while inFlight > 0, let result = await group.next() {
                inFlight -= 1
                completed += 1
                switch result {
                case .probed(let probe):
                    probes.append(probe)
                case .failed(let path, let message):
                    failures.append((path, message))
                }
                progress(CalibrationPreparationProgress(
                    stage: .probing,
                    message: "Inspected \(completed) of \(total) calibration frames.",
                    completed: completed,
                    total: total))
                enqueueNext()
            }
        }
        probes.sort {
            $0.path.caseInsensitiveCompare($1.path) == .orderedAscending
        }
        let warnings = failures
            .sorted { $0.path.caseInsensitiveCompare($1.path) == .orderedAscending }
            .map { "Could not inspect \($0.path): \($0.message)" }
        return ProbeOutcome(probes: probes, warnings: warnings)
    }

    // MARK: Planning

    private func planKind(
        kind: String,
        reference: CalibrationPlanRecord,
        references: [CalibrationPlanRecord],
        candidates: [CalibrationPlanRecord],
        minimum: Int,
        biasAvailable: Bool,
        tolerances: CalibrationPlanTolerances,
        progress: @escaping @Sendable (CalibrationPreparationProgress) -> Void,
        progressMessage: String
    ) async -> (CalibrationPlanResult, [String]) {
        progress(CalibrationPreparationProgress(
            stage: .planning, message: progressMessage))
        let request = CalibrationPlanRequest(
            kind: kind,
            reference: reference,
            references: references,
            candidates: candidates,
            minimum: minimum,
            tolerances: tolerances,
            dependencies: CalibrationPlanDependencies(biasAvailable: biasAvailable))
        do {
            let plan = try await runBlocking {
                try CalibrationService.plan(request)
            }
            return (plan, coherentSetWarnings(kind: kind, plan: plan))
        } catch {
            let warning =
                "The \(kind) calibration plan failed: \(error.localizedDescription)"
            return (.empty(kind: kind, minimum: minimum), [warning])
        }
    }

    private func coherentSetWarnings(
        kind: String, plan: CalibrationPlanResult
    ) -> [String] {
        let outside = plan.excluded.filter {
            $0.reason == CalibrationPlanResult.outsideCoherentSetReason
        }
        guard !outside.isEmpty else { return [] }
        let names = outside.prefix(3)
            .map { URL(fileURLWithPath: $0.path).lastPathComponent }
            .joined(separator: ", ")
        let more = outside.count > 3 ? ", and \(outside.count - 3) more" : ""
        let plural = outside.count == 1 ? "" : "s"
        return [
            "Set aside \(outside.count) raw \(kind) frame\(plural) outside the "
                + "selected temperature/session/rotation cohort: \(names)\(more)."
        ]
    }

    private func selectionFailureMessage(
        plan: CalibrationPlanResult,
        selectedProbes: [CalibrationFrameProbe],
        kind: String
    ) -> String? {
        guard plan.ready else {
            if plan.selectedPaths.isEmpty && plan.matchedPaths.isEmpty {
                return "No compatible raw \(kind) frames were found."
            }
            return "Only \(plan.selectedPaths.count) compatible raw \(kind) frames "
                + "were found; at least \(plan.minimum) are required."
        }
        if plan.selectedPaths.count < plan.minimum {
            return "The \(kind) calibration plan was invalid: the core marked the "
                + "plan ready with only \(plan.selectedPaths.count) selected frames."
        }
        let normalized = plan.selectedPaths.map {
            LiveStackPath.normalize($0).lowercased()
        }
        if Set(normalized).count != normalized.count {
            return "The \(kind) calibration plan was invalid: the core selected "
                + "the same frame more than once."
        }
        if selectedProbes.count != plan.selectedPaths.count {
            return "The \(kind) calibration plan was invalid: the core selected an "
                + "unknown frame."
        }
        let expectedRole = kind
        for probe in selectedProbes
        where probe.isMaster || probe.role != expectedRole || !probe.calibrationState.isRaw {
            return "The \(kind) calibration plan was invalid: the core selected a "
                + "master or non-\(kind) frame: \(probe.path)"
        }
        return nil
    }

    // MARK: Kind preparation (plan + cached build)

    private func prepareKind(
        kind: String,
        nativeKind: String,
        planReference: CalibrationPlanRecord,
        planReferences: [CalibrationPlanRecord],
        candidates: [CalibrationPlanRecord],
        candidatesByPath: [String: CalibrationFrameProbe],
        minimum: Int,
        biasAvailable: Bool,
        biasSummary: CalibrationPreparationKindSummary?,
        darkSummary: CalibrationPreparationKindSummary?,
        defectSuppression: CalibrationDefectSuppression?,
        request: CalibrationPreparationRequest,
        tolerances: CalibrationPlanTolerances,
        coreVersion: String,
        progress: @escaping @Sendable (CalibrationPreparationProgress) -> Void,
        planProgressMessage: String? = nil
    ) async throws -> KindOutcome {
        let (plan, planWarnings) = await planKind(
            kind: kind,
            reference: planReference,
            references: planReferences,
            candidates: candidates,
            minimum: minimum,
            biasAvailable: biasAvailable,
            tolerances: tolerances,
            progress: progress,
            progressMessage: planProgressMessage
                ?? "Matching raw \(kind) frames to every target light.")
        try Task.checkCancellation()

        var outcome = KindOutcome(
            summary: CalibrationPreparationKindSummary(kind: kind),
            warnings: planWarnings)
        let selectedProbes = plan.selectedPaths.compactMap { path in
            candidatesByPath[LiveStackPath.normalize(path).lowercased()]
        }
        if let failure = selectionFailureMessage(
            plan: plan, selectedProbes: selectedProbes, kind: kind) {
            outcome.summary.warning = failure
            return outcome
        }

        do {
            let built = try await buildKind(
                logicalKind: kind,
                nativeKind: nativeKind,
                plan: plan,
                bias: biasSummary,
                dark: darkSummary,
                defectSuppression: defectSuppression,
                request: request,
                coreVersion: coreVersion,
                progress: progress)
            outcome.summary = built.summary
            outcome.lease = built.lease
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            outcome.summary.warning = "The master \(kind) could not be built: "
                + error.localizedDescription
        }
        return outcome
    }

    private struct BuildOutcome {
        var summary: CalibrationPreparationKindSummary
        var lease: CalibrationFileLease? = nil
    }

    private func buildKind(
        logicalKind: String,
        nativeKind: String,
        plan: CalibrationPlanResult,
        bias: CalibrationPreparationKindSummary?,
        dark: CalibrationPreparationKindSummary?,
        defectSuppression: CalibrationDefectSuppression?,
        request: CalibrationPreparationRequest,
        coreVersion: String,
        progress: @escaping @Sendable (CalibrationPreparationProgress) -> Void
    ) async throws -> BuildOutcome {
        let inputs = plan.selectedPaths.map { LiveStackPath.normalize($0) }
        let identities = try captureInputIdentities(inputs)
        let fingerprint = computeFingerprint(
            logicalKind: logicalKind,
            nativeKind: nativeKind,
            coreVersion: coreVersion,
            rejection: CalibrationMasterRejection(),
            defectSuppression: defectSuppression,
            biasFingerprint: bias?.fingerprint,
            darkFingerprint: dark?.fingerprint,
            inputs: identities)

        let masterURL = request.cacheDirectory
            .appendingPathComponent("master-\(logicalKind)-\(fingerprint).fits")
        let reportURL = request.cacheDirectory
            .appendingPathComponent("master-\(logicalKind)-\(fingerprint).json")
        let lockURL = request.cacheDirectory
            .appendingPathComponent("master-\(logicalKind)-\(fingerprint).fits.lock")
        let retainURL = request.cacheDirectory
            .appendingPathComponent("master-\(logicalKind)-\(fingerprint).fits.retain")

        let lockKey = CalibrationCacheLocks.key(for: masterURL.path)
        await CalibrationCacheLocks.shared.acquire(lockKey)
        do {
            let outcome = try await buildKindLocked(
                logicalKind: logicalKind,
                nativeKind: nativeKind,
                plan: plan,
                bias: bias,
                dark: dark,
                defectSuppression: defectSuppression,
                request: request,
                coreVersion: coreVersion,
                progress: progress,
                inputs: inputs,
                identities: identities,
                fingerprint: fingerprint,
                masterURL: masterURL,
                reportURL: reportURL,
                lockURL: lockURL,
                retainURL: retainURL)
            await CalibrationCacheLocks.shared.release(lockKey)
            return outcome
        } catch {
            await CalibrationCacheLocks.shared.release(lockKey)
            throw error
        }
    }

    private func buildKindLocked(
        logicalKind: String,
        nativeKind: String,
        plan: CalibrationPlanResult,
        bias: CalibrationPreparationKindSummary?,
        dark: CalibrationPreparationKindSummary?,
        defectSuppression: CalibrationDefectSuppression?,
        request: CalibrationPreparationRequest,
        coreVersion: String,
        progress: @escaping @Sendable (CalibrationPreparationProgress) -> Void,
        inputs: [String],
        identities: [InputIdentity],
        fingerprint: String,
        masterURL: URL,
        reportURL: URL,
        lockURL: URL,
        retainURL: URL
    ) async throws -> BuildOutcome {
        let buildLease = try await CalibrationFileLease.acquireExclusive(at: lockURL)
        defer { buildLease.release() }

        let buildRequest = CalibrationMasterBuildRequest(
            kind: nativeKind,
            inputs: inputs,
            output: "",
            bias: bias?.masterPath,
            dark: dark?.masterPath,
            rejection: CalibrationMasterRejection(),
            defectSuppression: defectSuppression)

        if let cached = tryReadCache(
            kind: logicalKind,
            fingerprint: fingerprint,
            coreVersion: coreVersion,
            masterURL: masterURL,
            reportURL: reportURL,
            request: buildRequest,
            minimum: plan.minimum) {
            try? FileManager.default.setAttributes(
                [.modificationDate: Date()], ofItemAtPath: reportURL.path)
            let retention = try await CalibrationFileLease.acquireShared(at: retainURL)
            return BuildOutcome(
                summary: CalibrationPreparationKindSummary(
                    kind: logicalKind,
                    masterPath: masterURL.path,
                    cacheReused: true,
                    warning: describeSkippedInputs(kind: logicalKind, result: cached.build),
                    fingerprint: fingerprint,
                    build: cached.build),
                lease: retention)
        }

        progress(CalibrationPreparationProgress(
            stage: .building, message: "Building the master \(logicalKind)."))

        let stagingToken = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let stagingMaster = request.cacheDirectory.appendingPathComponent(
            ".master-\(logicalKind)-\(fingerprint)-\(stagingToken).tmp.fits")
        let stagingReport = request.cacheDirectory.appendingPathComponent(
            ".master-\(logicalKind)-\(fingerprint)-\(stagingToken).tmp.json")
        defer {
            try? FileManager.default.removeItem(at: stagingMaster)
            try? FileManager.default.removeItem(at: stagingReport)
        }

        var stagedRequest = buildRequest
        stagedRequest.output = stagingMaster.path
        let cancellation = try CalibrationCancelSignal()
        let requestForBuild = stagedRequest
        let built = try await withTaskCancellationHandler {
            try await runBlocking {
                try CalibrationService.buildMaster(
                    requestForBuild,
                    cancellation: cancellation,
                    isCancelled: { cancellation.wasCancelled })
            }
        } onCancel: {
            cancellation.cancel()
        }
        try Task.checkCancellation()
        try validateBuildResult(
            built,
            request: stagedRequest,
            stagingOutput: stagingMaster.path,
            minimum: plan.minimum)
        try ensureInputsUnchanged(identities)

        try? FileManager.default.removeItem(at: masterURL)
        try FileManager.default.moveItem(at: stagingMaster, to: masterURL)

        var published = built
        published.kind = logicalKind
        published.output = masterURL.path

        let masterAttributes = try FileManager.default.attributesOfItem(
            atPath: masterURL.path)
        let masterLength = (masterAttributes[.size] as? NSNumber)?.int64Value ?? 0
        let masterModified = (masterAttributes[.modificationDate] as? Date) ?? Date()
        let report = CalibrationMasterCacheReport(
            kind: logicalKind,
            fingerprint: fingerprint,
            coreVersion: coreVersion,
            masterPath: masterURL.path,
            masterLength: masterLength,
            masterLastWriteUnixNanoseconds: unixNanoseconds(masterModified),
            build: published)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: stagingReport)
        try Task.checkCancellation()
        try? FileManager.default.removeItem(at: reportURL)
        try FileManager.default.moveItem(at: stagingReport, to: reportURL)

        let retention = try await CalibrationFileLease.acquireShared(at: retainURL)
        return BuildOutcome(
            summary: CalibrationPreparationKindSummary(
                kind: logicalKind,
                masterPath: masterURL.path,
                cacheReused: false,
                warning: describeSkippedInputs(kind: logicalKind, result: published),
                fingerprint: fingerprint,
                build: published),
            lease: retention)
    }

    // MARK: Flat build with the pedestal-safety gate

    private func buildFlat(
        flatPlan: CalibrationPlanResult,
        selectedFlatProbes: [CalibrationFrameProbe],
        bias: CalibrationPreparationKindSummary,
        dark: CalibrationPreparationKindSummary,
        darkFlat: CalibrationPreparationKindSummary,
        targets: [CalibrationFrameProbe],
        candidatesByPath: [String: CalibrationFrameProbe],
        request: CalibrationPreparationRequest,
        resolvedTolerances: CalibrationMatchTolerances,
        coreVersion: String,
        progress: @escaping @Sendable (CalibrationPreparationProgress) -> Void
    ) async throws -> KindOutcome {
        var outcome = KindOutcome(
            summary: CalibrationPreparationKindSummary(kind: CalibrationFrameRole.flat))
        if let failure = selectionFailureMessage(
            plan: flatPlan,
            selectedProbes: selectedFlatProbes,
            kind: CalibrationFrameRole.flat) {
            outcome.summary.warning = failure
            return outcome
        }

        // The pedestal gate: without a bias, the flat may only be built when
        // an uncalibrated dark-flat (or dark) with known exposure matches
        // every selected flat.
        let flatDark = darkFlat.masterPath != nil ? darkFlat : dark
        if bias.masterPath == nil {
            let safe = flatDark.masterPath != nil
                && flatDark.build?.biasSubtracted == false
                && darkMatchesEverySelectedFlat(
                    flatDark: flatDark,
                    selectedFlatProbes: selectedFlatProbes,
                    candidatesByPath: candidatesByPath,
                    tolerances: resolvedTolerances)
            guard safe else {
                outcome.summary.warning = Self.flatPedestalWarning
                return outcome
            }
        }

        do {
            let built = try await buildKind(
                logicalKind: CalibrationFrameRole.flat,
                nativeKind: CalibrationFrameRole.flat,
                plan: flatPlan,
                bias: bias,
                dark: flatDark.masterPath != nil ? flatDark : nil,
                defectSuppression: request.options.flatDefectSuppression,
                request: request,
                coreVersion: coreVersion,
                progress: progress)
            outcome.summary = built.summary
            outcome.lease = built.lease
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if bias.masterPath == nil {
                outcome.summary.warning = "\(Self.flatPedestalWarning) "
                    + "The native check reported: \(error.localizedDescription)"
            } else {
                outcome.summary.warning =
                    "The master flat could not be built: \(error.localizedDescription)"
            }
            return outcome
        }

        // The written master must still prove it is safe for every target.
        if outcome.summary.masterPath != nil {
            if let mismatch = await verifyBuiltFlat(
                outcome.summary, targets: targets, tolerances: resolvedTolerances) {
                let warning = "The built master flat was withheld because \(mismatch). "
                    + "Seiza requires a newly built master to preserve enough metadata "
                    + "to prove it is safe for every selected target before native "
                    + "stacking begins."
                outcome.summary.masterPath = nil
                outcome.summary.warning = [outcome.summary.warning, warning]
                    .compactMap { $0 }
                    .joined(separator: " ")
                outcome.lease?.release()
                outcome.lease = nil
            }
        }
        return outcome
    }

    private func darkMatchesEverySelectedFlat(
        flatDark: CalibrationPreparationKindSummary,
        selectedFlatProbes: [CalibrationFrameProbe],
        candidatesByPath: [String: CalibrationFrameProbe],
        tolerances: CalibrationMatchTolerances
    ) -> Bool {
        guard let build = flatDark.build,
            let outputExposure = build.outputExposureSeconds,
            outputExposure.isFinite, outputExposure > 0,
            let firstInput = build.inputs.first,
            !selectedFlatProbes.isEmpty
        else { return false }
        guard let inputProbe = candidatesByPath[
            LiveStackPath.normalize(firstInput.path).lowercased()]
        else { return false }
        var darkSignature = inputProbe.signature
        darkSignature.exposureSeconds = outputExposure
        for flat in selectedFlatProbes {
            guard let flatExposure = flat.signature.exposureSeconds,
                flatExposure.isFinite, flatExposure > 0
            else { return false }
            let matches = (try? CalibrationMatchingService.darkMatches(
                reference: flat.signature,
                candidate: darkSignature,
                tolerances: tolerances)) ?? false
            guard matches else { return false }
        }
        return true
    }

    private func verifyBuiltFlat(
        _ summary: CalibrationPreparationKindSummary,
        targets: [CalibrationFrameProbe],
        tolerances: CalibrationMatchTolerances
    ) async -> String? {
        guard let masterPath = summary.masterPath else { return nil }
        do {
            let master = try await runBlocking {
                try CalibrationService.probe(path: masterPath)
            }
            guard master.isMaster,
                master.role.caseInsensitiveCompare(CalibrationFrameRole.flat)
                    == .orderedSame,
                master.calibrationState.flatNormalized
            else {
                return "the written file does not identify itself as a normalized "
                    + "master flat"
            }
            for target in targets {
                if try !CalibrationMatchingService.sensorMatches(
                    reference: target.signature, candidate: master.signature) {
                    let details = try CalibrationMatchingService.describeSensorMismatch(
                        reference: target.signature, candidate: master.signature)
                    return "its sensor or readout metadata no longer matches every "
                        + "target (\(details))"
                }
                if try !CalibrationMatchingService.opticsMatch(
                    reference: target.signature,
                    candidate: master.signature,
                    tolerances: tolerances) {
                    let details = try CalibrationMatchingService.describeOpticsMismatch(
                        reference: target.signature,
                        candidate: master.signature,
                        tolerances: tolerances)
                    return "its optical metadata no longer matches every target "
                        + "(\(details))"
                }
            }
            return nil
        } catch {
            return "its written metadata could not be verified "
                + "(\(error.localizedDescription))"
        }
    }

    // MARK: Cache

    private func tryReadCache(
        kind: String,
        fingerprint: String,
        coreVersion: String,
        masterURL: URL,
        reportURL: URL,
        request: CalibrationMasterBuildRequest,
        minimum: Int
    ) -> CalibrationMasterCacheReport? {
        guard FileManager.default.fileExists(atPath: masterURL.path),
            FileManager.default.fileExists(atPath: reportURL.path)
        else { return nil }
        guard let data = try? Data(contentsOf: reportURL),
            let report = try? JSONDecoder().decode(
                CalibrationMasterCacheReport.self, from: data)
        else { return nil }
        guard report.schemaVersion == CalibrationMasterCacheReport.currentSchemaVersion,
            report.kind == kind,
            report.fingerprint == fingerprint,
            report.coreVersion == coreVersion,
            LiveStackPath.equals(report.masterPath, masterURL.path),
            report.masterLength > 0
        else { return nil }
        guard let attributes = try? FileManager.default.attributesOfItem(
            atPath: masterURL.path),
            let size = (attributes[.size] as? NSNumber)?.int64Value,
            let modified = attributes[.modificationDate] as? Date,
            size == report.masterLength,
            unixNanoseconds(modified) == report.masterLastWriteUnixNanoseconds
        else { return nil }
        let build = report.build
        guard build.schemaVersion > 0,
            build.kind == kind,
            LiveStackPath.equals(build.output, masterURL.path),
            build.width > 0, build.height > 0, build.channels > 0,
            hasExpectedCalibrationState(build, request: request),
            build.schemaVersion < 2 || build.requestedFrames == request.inputs.count,
            hasValidInputPartition(build, requestedInputs: request.inputs, minimum: minimum)
        else { return nil }
        return report
    }

    private func hasExpectedCalibrationState(
        _ result: CalibrationMasterBuildResult,
        request: CalibrationMasterBuildRequest
    ) -> Bool {
        let expected: (bias: Bool, dark: Bool, normalized: Bool) = switch request.kind {
        case CalibrationFrameRole.bias: (false, false, false)
        case CalibrationFrameRole.dark: (request.bias != nil, false, false)
        case CalibrationFrameRole.flat: (true, request.dark != nil, true)
        default: (false, false, false)
        }
        return result.biasSubtracted == expected.bias
            && result.darkSubtracted == expected.dark
            && result.normalized == expected.normalized
    }

    private func hasValidInputPartition(
        _ result: CalibrationMasterBuildResult,
        requestedInputs: [String],
        minimum: Int
    ) -> Bool {
        guard result.inputFrames >= minimum,
            result.inputFrames <= requestedInputs.count,
            result.inputs.count == result.inputFrames,
            result.requestedFrames >= 0
        else { return false }
        if result.schemaVersion < 2 {
            return result.requestedFrames == 0
                && result.inputFrames == requestedInputs.count
                && result.skippedInputs.isEmpty
        }
        guard result.requestedFrames == requestedInputs.count else { return false }
        var requested: Set<String> = []
        for path in requestedInputs {
            let normalized = LiveStackPath.normalize(path).lowercased()
            guard !normalized.isEmpty, requested.insert(normalized).inserted else {
                return false
            }
        }
        var reported: Set<String> = []
        for input in result.inputs {
            let normalized = LiveStackPath.normalize(input.path).lowercased()
            guard !normalized.isEmpty, reported.insert(normalized).inserted else {
                return false
            }
        }
        for skipped in result.skippedInputs {
            let normalized = LiveStackPath.normalize(skipped.path).lowercased()
            guard !normalized.isEmpty,
                !skipped.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                reported.insert(normalized).inserted
            else { return false }
        }
        return reported == requested
    }

    private func validateBuildResult(
        _ result: CalibrationMasterBuildResult,
        request: CalibrationMasterBuildRequest,
        stagingOutput: String,
        minimum: Int
    ) throws {
        let valid = result.schemaVersion >= 1
            && result.kind == request.kind
            && LiveStackPath.equals(result.output, stagingOutput)
            && result.width > 0 && result.height > 0 && result.channels > 0
            && (result.schemaVersion < 2 || result.requestedFrames == request.inputs.count)
            && hasValidInputPartition(
                result, requestedInputs: request.inputs, minimum: minimum)
            && hasExpectedCalibrationState(result, request: request)
            && fileLength(stagingOutput) > 0
        guard valid else {
            throw CalibrationServiceError.invalidResponse(
                "The Seiza core returned an invalid master-\(request.kind) build result.")
        }
    }

    private func describeSkippedInputs(
        kind: String,
        result: CalibrationMasterBuildResult
    ) -> String? {
        guard !result.skippedInputs.isEmpty else { return nil }
        let details = result.skippedInputs.prefix(3).map { skipped in
            let name = URL(fileURLWithPath: skipped.path).lastPathComponent
            let reason = skipped.reason
                .replacingOccurrences(of: "\r\n", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty { return skipped.path }
            return reason.isEmpty ? name : "\(name) (\(reason))"
        }
        let more = result.skippedInputs.count > 3
            ? "; and \(result.skippedInputs.count - 3) more"
            : ""
        return "The master \(kind) used \(result.inputFrames) of "
            + "\(result.requestedFrames) selected frames. Seiza skipped "
            + "\(result.skippedInputs.count) after its final compatibility check: "
            + details.joined(separator: "; ") + more + "."
    }

    // MARK: Fingerprint

    private func captureInputIdentities(_ inputs: [String]) throws -> [InputIdentity] {
        try inputs.map { path in
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                let size = (attributes[.size] as? NSNumber)?.int64Value,
                let modified = attributes[.modificationDate] as? Date
            else {
                throw CalibrationServiceError.core(
                    "A selected calibration frame disappeared.")
            }
            return InputIdentity(
                path: path,
                length: size,
                modifiedNanoseconds: unixNanoseconds(modified))
        }
    }

    private func ensureInputsUnchanged(_ identities: [InputIdentity]) throws {
        for identity in identities {
            guard let attributes = try? FileManager.default.attributesOfItem(
                atPath: identity.path),
                let size = (attributes[.size] as? NSNumber)?.int64Value,
                let modified = attributes[.modificationDate] as? Date,
                size == identity.length,
                unixNanoseconds(modified) == identity.modifiedNanoseconds
            else {
                throw CalibrationServiceError.core(
                    "Calibration input changed while its master was being built: "
                        + identity.path)
            }
        }
    }

    private func computeFingerprint(
        logicalKind: String,
        nativeKind: String,
        coreVersion: String,
        rejection: CalibrationMasterRejection,
        defectSuppression: CalibrationDefectSuppression?,
        biasFingerprint: String?,
        darkFingerprint: String?,
        inputs: [InputIdentity]
    ) -> String {
        var hasher = SHA256()
        func append(_ value: String) {
            let bytes = Array(value.utf8)
            var length = Int32(bytes.count).littleEndian
            withUnsafeBytes(of: &length) { hasher.update(data: Data($0)) }
            hasher.update(data: Data(bytes))
        }
        append("seiza-calibration-cache-v1")
        append(nativeKind)
        if logicalKind != nativeKind {
            append("logical:\(logicalKind)")
        }
        append(coreVersion)
        append("\(rejection.lowSigma)")
        append("\(rejection.highSigma)")
        append(defectSuppression.map { "\($0.lowSigma)" } ?? "none")
        append(defectSuppression.map { "\($0.highSigma)" } ?? "none")
        // Exposure overrides never participate today; the two literals keep
        // existing fingerprints stable.
        append("none")
        append("none")
        append(biasFingerprint ?? "none")
        append(darkFingerprint ?? "none")
        for input in inputs {
            append(input.path)
            append("\(input.length)")
            append("\(input.modifiedNanoseconds)")
        }
        return SeizaDigest.hex(hasher.finalize())
    }

    private func unixNanoseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000_000_000).rounded())
    }

    private func fileLength(_ path: String) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return ((attributes?[.size] as? NSNumber)?.int64Value) ?? 0
    }

    // MARK: Pruning

    private struct CacheEntry {
        var masterURL: URL
        var files: [URL]
        var totalBytes: Int64
        var lastUsed: Date
    }

    private func pruneCache(
        request: CalibrationPreparationRequest,
        producedMasterPaths: [String]
    ) async -> [String] {
        guard request.options.maximumCacheBytes != nil
            || request.options.maximumCacheAge != nil
        else { return [] }
        var protected = Set(
            request.protectedMasterPaths.map { LiveStackPath.normalize($0).lowercased() })
        protected.formUnion(
            producedMasterPaths.map { LiveStackPath.normalize($0).lowercased() })

        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: request.cacheDirectory,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                options: [])
            var entries: [String: CacheEntry] = [:]
            for url in contents {
                guard let masterName = cacheEntryMasterName(for: url.lastPathComponent)
                else { continue }
                let masterURL = request.cacheDirectory.appendingPathComponent(masterName)
                let key = masterName.lowercased()
                let values = try? url.resourceValues(
                    forKeys: [.fileSizeKey, .contentModificationDateKey])
                let size = Int64(values?.fileSize ?? 0)
                let modified = values?.contentModificationDate ?? .distantPast
                if var entry = entries[key] {
                    entry.files.append(url)
                    entry.totalBytes += size
                    entry.lastUsed = max(entry.lastUsed, modified)
                    entries[key] = entry
                } else {
                    entries[key] = CacheEntry(
                        masterURL: masterURL,
                        files: [url],
                        totalBytes: size,
                        lastUsed: modified)
                }
            }

            var totalBytes = entries.values.reduce(Int64(0)) { $0 + $1.totalBytes }
            let now = Date()
            for entry in entries.values.sorted(by: { $0.lastUsed < $1.lastUsed }) {
                let expired = request.options.maximumCacheAge.map {
                    now.timeIntervalSince(entry.lastUsed) > $0
                } ?? false
                let overLimit = request.options.maximumCacheBytes.map {
                    totalBytes > $0
                } ?? false
                guard expired || overLimit else { break }
                if protected.contains(
                    LiveStackPath.normalize(entry.masterURL.path).lowercased()) {
                    continue
                }
                totalBytes -= await deleteCacheEntry(entry)
            }
            return []
        } catch {
            return [
                "Calibration cache cleanup could not complete: "
                    + error.localizedDescription
            ]
        }
    }

    /// Maps any cache file name back to its master file name, or nil for
    /// files that are not part of a cache entry. Locks and leases ride along
    /// with their master entry; the longer dark-flat prefix wins.
    private func cacheEntryMasterName(for fileName: String) -> String? {
        for kind in ["dark-flat", "bias", "dark", "flat"] {
            for prefix in ["master-\(kind)-", ".master-\(kind)-"] {
                guard fileName.hasPrefix(prefix) else { continue }
                let rest = fileName.dropFirst(prefix.count)
                guard let fingerprint = leadingFingerprint(rest) else { continue }
                return "master-\(kind)-\(fingerprint).fits"
            }
        }
        return nil
    }

    private func leadingFingerprint(_ value: Substring) -> String? {
        let candidate = value.prefix(64)
        guard candidate.count == 64,
            candidate.allSatisfy({ ("0"..."9").contains(String($0)) || ("a"..."f").contains(String($0)) })
        else { return nil }
        return String(candidate)
    }

    private func deleteCacheEntry(_ entry: CacheEntry) async -> Int64 {
        let lockKey = CalibrationCacheLocks.key(for: entry.masterURL.path)
        guard await CalibrationCacheLocks.shared.tryAcquire(lockKey) else { return 0 }
        defer {
            let key = lockKey
            Task { await CalibrationCacheLocks.shared.release(key) }
        }

        let lockURL = URL(fileURLWithPath: entry.masterURL.path + ".lock")
        let retainURL = URL(fileURLWithPath: entry.masterURL.path + ".retain")
        guard let buildLease = CalibrationFileLease.tryAcquireExclusive(at: lockURL)
        else { return 0 }
        defer { buildLease.release() }
        guard let retainLease = CalibrationFileLease.tryAcquireExclusive(at: retainURL)
        else { return 0 }
        defer { retainLease.release() }

        var reclaimed: Int64 = 0
        for file in entry.files {
            // Lease marker files stay in place: unlinking a held flock would
            // let a fresh lock on a new inode coexist with the old holder.
            let name = file.lastPathComponent
            if name.hasSuffix(".lock") || name.hasSuffix(".retain") { continue }
            let values = try? file.resourceValues(forKeys: [.fileSizeKey])
            do {
                try FileManager.default.removeItem(at: file)
                reclaimed += Int64(values?.fileSize ?? 0)
            } catch {
                continue
            }
        }
        return reclaimed
    }
}

// MARK: - Warning presentation

enum CalibrationPreparationWarningText {
    static func format(_ warnings: [String]) -> String {
        var seen = Set<String>()
        let distinct = warnings
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        let shown = distinct.prefix(12)
        var text = shown.joined(separator: "\n")
        if distinct.count > shown.count {
            text += "\n…and \(distinct.count - shown.count) more warning(s)."
        }
        return text
    }
}

/// Runs a blocking native call off the cooperative pool.
func runBlocking<Result: Sendable>(
    _ work: @escaping @Sendable () throws -> Result
) async throws -> Result {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            continuation.resume(with: Swift.Result(catching: work))
        }
    }
}
