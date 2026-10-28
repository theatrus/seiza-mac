import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum StackNormalizationMode: String, CaseIterable, Identifiable, Sendable {
    case none
    case global
    case local
    case localBackground = "local-background"

    var id: Self { self }

    var title: String {
        switch self {
        case .none: "None"
        case .global: "Global"
        case .local: "Local"
        case .localBackground: "Local background"
        }
    }
}

enum StackRegistrationModel: String, CaseIterable, Identifiable, Sendable {
    case similarity, affine, quadratic
    var id: Self { self }
    var title: String {
        switch self {
        case .similarity: "Similarity (default)"
        case .affine: "Affine"
        case .quadratic: "Quadratic"
        }
    }
}

enum StackWeighting: String, CaseIterable, Identifiable, Sendable {
    case equal
    case inverseNoiseVariance = "inverse-noise-variance"
    var id: Self { self }
    var title: String { self == .equal ? "Equal (default)" : "Inverse noise variance" }
}

enum StackInterpolation: String, CaseIterable, Identifiable, Sendable {
    case bilinear, lanczos3
    var id: Self { self }
    var title: String { self == .bilinear ? "Bilinear (default)" : "Lanczos-3" }
}

enum StackDemosaic: String, CaseIterable, Identifiable, Sendable {
    case vng, mhc, bilinear
    var id: Self { self }
    var title: String {
        switch self {
        case .vng: "VNG (default)"
        case .mhc: "MHC"
        case .bilinear: "Bilinear"
        }
    }
}

enum StackCfaIntegration: String, CaseIterable, Identifiable, Sendable {
    case demosaic
    case bayerDrizzle = "bayer_drizzle"
    var id: Self { self }
    var title: String { self == .demosaic ? "Demosaic (default)" : "Bayer drizzle" }
}

enum StackRejectionMode: String, CaseIterable, Identifiable, Sendable {
    case none
    case deltaSigma

    var id: Self { self }

    var title: String {
        switch self {
        case .none: "None"
        case .deltaSigma: "Delta Sigma"
        }
    }
}

enum StackCalibrationSource: String, CaseIterable, Identifiable, Sendable {
    case masters
    case automatic

    var id: Self { self }

    var title: String {
        switch self {
        case .masters: "None or existing masters"
        case .automatic: "Graded calibration files or library"
        }
    }
}

enum StackCanvasMode: String, CaseIterable, Identifiable, Sendable {
    case fixed, expanded
    var id: String { rawValue }
    var title: String { self == .fixed ? "Fixed reference" : "Expanded mosaic" }
}

enum StackingPreferences {
    static func gpuBudgetMiB(in defaults: UserDefaults = .standard) -> Int {
        min(1_048_576, max(0, defaults.integer(forKey: "gpuPlanningBudgetMiB")))
    }
    static func usesGPU(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: "useGpuForStacking") as? Bool ?? true
    }
}

struct ImageStackOptions: Equatable, Sendable {
    var useGPU = true
    var gpuBudgetMiB = 0
    var canvasMode = StackCanvasMode.fixed
    var maximumCanvasMegasamples = 256

    var normalization = StackNormalizationMode.global
    var localTileSize = 256
    var rejection = StackRejectionMode.deltaSigma
    var sigmaLow = 3.0
    var sigmaHigh = 3.0
    var rejectionWarmup = 5
    var maximumRegistrationRMS = 2.0
    var maximumDriftPixels = 256.0
    var maximumDriftFraction = 0.15
    var minimumOverlap = 0.60
    var registrationModel = StackRegistrationModel.similarity
    var weighting = StackWeighting.equal
    var minimumWeight = 0.05
    var maximumWeight = 20.0
    var interpolation = StackInterpolation.bilinear
    var demosaic = StackDemosaic.vng
    var cfaIntegration = StackCfaIntegration.demosaic
    var suppressesHotPixels = false
    var cosmeticLowSigma = 16.0
    var cosmeticHighSigma = 16.0

    var usesLocalTiles: Bool { normalization == .local || normalization == .localBackground }
    /// Integrate every accepted frame again after stacking, with
    /// leave-one-out rejection, to remove trails that live rejection kept in
    /// the first frames. Not part of `jsonData`: it does not change how the
    /// native stacker is configured, so live checkpoints stay resumable.
    var removesTransients = true

    /// Sigma limits for the reintegration pass; zero takes the core default.
    var reintegrationSigmas: (low: Double, high: Double) {
        rejection == .deltaSigma ? (sigmaLow, sigmaHigh) : (0, 0)
    }

    var validationMessage: String? {
        if !(0...1_048_576).contains(gpuBudgetMiB) {
            return "GPU planning budget must be 0 (automatic) through 1048576 MiB."
        }
        if canvasMode == .expanded, normalization == .local {
            return "Expanded mosaics require local-background, global, or no normalization."
        }
        if !(1...4096).contains(maximumCanvasMegasamples) {
            return "Canvas limit must be between 1 and 4096 million samples."
        }
        if canvasMode == .expanded, cfaIntegration == .bayerDrizzle {
            return "Bayer drizzle is unavailable on expanded canvases."
        }
        if usesLocalTiles, localTileSize < 16 {
            return "Local normalization tiles must be at least 16 pixels wide."
        }
        if rejection == .deltaSigma {
            guard Self.isPositiveNativeFloat(sigmaLow), Self.isPositiveNativeFloat(sigmaHigh) else {
                return "Sigma thresholds must be positive numbers."
            }
            guard rejectionWarmup >= 2 else {
                return "Rejection warmup must include at least two frames."
            }
        }
        guard maximumRegistrationRMS.isFinite, maximumRegistrationRMS > 0 else {
            return "Maximum registration RMS must be positive."
        }
        guard maximumDriftPixels.isFinite, maximumDriftPixels > 0 else {
            return "Maximum drift must be positive."
        }
        guard maximumDriftFraction.isFinite, (0...1).contains(maximumDriftFraction) else {
            return "Maximum drift fraction must be between 0 and 1."
        }
        guard minimumOverlap.isFinite, (0...1).contains(minimumOverlap) else {
            return "Minimum overlap must be between 0 and 1."
        }
        if weighting == .inverseNoiseVariance,
            !(Self.isPositiveNativeFloat(minimumWeight) && minimumWeight <= 1
                && Self.isPositiveNativeFloat(maximumWeight) && maximumWeight >= 1) {
            return "Frame weights must satisfy 0 < minimum ≤ 1 ≤ maximum."
        }
        if suppressesHotPixels,
            !(Self.isPositiveNativeFloat(cosmeticLowSigma)
                && Self.isPositiveNativeFloat(cosmeticHighSigma)) {
            return "Hot/dead pixel thresholds must be positive finite numbers."
        }
        return nil
    }

    /// GPU policy changes execution, not checkpoint processing compatibility.
    static func savedUsesGPU(_ json: String) throws -> Bool {
        _ = try processingIdentity(json)
        let value = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        return (value["gpu"] as? [String: Any])?["enabled"] as? Bool ?? true
    }

    var gpuJSON: String {
        get throws {
            if let message = validationMessage { throw ImageStackError.invalidRequest(message) }
            var gpu: [String: Any] = ["enabled": useGPU]
            if gpuBudgetMiB > 0 { gpu["memory_bytes"] = gpuBudgetMiB * 1_048_576 }
            return String(decoding: try JSONSerialization.data(withJSONObject: gpu, options: [.sortedKeys]), as: UTF8.self)
        }
    }

    func applyingGPU(to saved: String) throws -> String {
        _ = try Self.processingIdentity(saved)
        var value = try JSONSerialization.jsonObject(with: Data(saved.utf8)) as! [String: Any]
        value["gpu"] = try JSONSerialization.jsonObject(with: Data(gpuJSON.utf8))
        return String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
    }

    private static func processingIdentity(_ json: String) throws -> Data {
        guard var value = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            throw ImageStackError.invalidRequest("Invalid saved stack options.")
        }
        if let gpuValue = value["gpu"] {
            guard let gpu = gpuValue as? [String: Any],
                gpu.allSatisfy({ key, value in
                    if ["enabled", "trace", "defects", "debayer", "detection", "resampling", "accumulator", "integration"].contains(key) {
                        return CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID()
                    }
                    if ["memory_bytes", "concurrency"].contains(key), let n = value as? NSNumber,
                        CFGetTypeID(n) != CFBooleanGetTypeID() {
                        return n.doubleValue.isFinite && n.doubleValue > 0 && n.doubleValue.rounded() == n.doubleValue
                            && n.doubleValue < (key == "concurrency" ? 4_294_967_296 : 18_446_744_073_709_551_616)
                    }
                    return false
                }) else {
                throw ImageStackError.invalidRequest("Invalid saved GPU policy.")
            }
        }
        value.removeValue(forKey: "gpu")
        return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    static func sameProcessingOptions(_ lhs: String, _ rhs: String) -> Bool {
        guard let a = try? processingIdentity(lhs), let b = try? processingIdentity(rhs) else { return false }
        return a == b
    }

    private static func isPositiveNativeFloat(_ value: Double) -> Bool {
        value.isFinite && Float(value).isFinite && Float(value) > 0
    }

    var jsonData: Data {
        get throws {
            if let message = validationMessage { throw ImageStackError.invalidRequest(message) }
            let payload = StackOptionsPayload(options: self)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(payload)
        }
    }
}

private struct StackOptionsPayload: Encodable {
    let gpu: GPUPayload?
    struct GPUPayload: Encodable { let enabled: Bool; let memory_bytes: Int? }
    let registration: RegistrationPayload
    let normalization: NormalizationPayload
    let rejection: RejectionPayload
    let acceptance: AcceptancePayload
    let cosmetic: CosmeticPayload?
    let weighting: WeightingPayload?
    let interpolation: String?
    let demosaic: String?
    let cfaIntegration: String?

    enum CodingKeys: String, CodingKey {
        case gpu, registration, normalization, rejection, acceptance, cosmetic, weighting
        case interpolation, demosaic
        case cfaIntegration = "cfa_integration"
    }

    init(options: ImageStackOptions) {
        gpu = options.useGPU && options.gpuBudgetMiB == 0 ? nil : GPUPayload(enabled: options.useGPU, memory_bytes: options.gpuBudgetMiB == 0 ? nil : options.gpuBudgetMiB * 1_048_576)
        registration = RegistrationPayload(
            maximumDriftPixels: options.maximumDriftPixels,
            maximumDriftFraction: options.maximumDriftFraction,
            model: options.registrationModel == .similarity ? nil : options.registrationModel.rawValue
        )
        normalization = NormalizationPayload(options: options)
        rejection = RejectionPayload(options: options)
        acceptance = AcceptancePayload(
            maximumRegistrationRMS: options.maximumRegistrationRMS,
            minimumOverlap: options.minimumOverlap
        )
        cosmetic = options.suppressesHotPixels
            ? CosmeticPayload(low_sigma: options.cosmeticLowSigma, high_sigma: options.cosmeticHighSigma) : nil
        weighting = options.weighting == .equal ? nil : WeightingPayload(
            mode: options.weighting.rawValue, minimum_weight: options.minimumWeight,
            maximum_weight: options.maximumWeight)
        interpolation = options.interpolation == .bilinear ? nil : options.interpolation.rawValue
        demosaic = options.demosaic == .vng ? nil : options.demosaic.rawValue
        cfaIntegration = options.cfaIntegration == .demosaic ? nil : options.cfaIntegration.rawValue
    }

    struct CosmeticPayload: Encodable {
        let low_sigma: Double
        let high_sigma: Double
    }

    struct WeightingPayload: Encodable {
        let mode: String
        let minimum_weight: Double
        let maximum_weight: Double
    }

    struct RegistrationPayload: Encodable {
        let maximumDriftPixels: Double
        let maximumDriftFraction: Double
        let model: String?

        enum CodingKeys: String, CodingKey {
            case maximumDriftPixels = "maximum_drift_pixels"
            case maximumDriftFraction = "maximum_drift_fraction"
            case model
        }
    }

    struct NormalizationPayload: Encodable {
        let mode: String
        let options: LocalOptions?

        init(options stackOptions: ImageStackOptions) {
            mode = stackOptions.normalization.rawValue
            options = stackOptions.usesLocalTiles
                ? LocalOptions(tileSize: stackOptions.localTileSize)
                : nil
        }

        struct LocalOptions: Encodable {
            let tileSize: Int

            enum CodingKeys: String, CodingKey {
                case tileSize = "tile_size"
            }
        }
    }

    struct RejectionPayload: Encodable {
        let mode: String
        let options: DeltaSigmaPayload?

        init(options stackOptions: ImageStackOptions) {
            switch stackOptions.rejection {
            case .none:
                mode = "none"
                options = nil
            case .deltaSigma:
                mode = "delta-sigma"
                options = DeltaSigmaPayload(
                    lowSigma: stackOptions.sigmaLow,
                    highSigma: stackOptions.sigmaHigh,
                    warmupSamples: stackOptions.rejectionWarmup,
                    minimumSigma: 1.0e-6
                )
            }
        }

        struct DeltaSigmaPayload: Encodable {
            let lowSigma: Double
            let highSigma: Double
            let warmupSamples: Int
            let minimumSigma: Double

            enum CodingKeys: String, CodingKey {
                case lowSigma = "low_sigma"
                case highSigma = "high_sigma"
                case warmupSamples = "warmup_samples"
                case minimumSigma = "minimum_sigma"
            }
        }
    }

    struct AcceptancePayload: Encodable {
        let maximumRegistrationRMS: Double
        let minimumOverlap: Double

        enum CodingKeys: String, CodingKey {
            case maximumRegistrationRMS = "maximum_registration_rms_pixels"
            case minimumOverlap = "minimum_overlap_fraction"
        }
    }
}

/// Shared controls for directory and live stacks. Every choice is opt-in.
struct StackProcessingOptionsView: View {
    @Binding var options: ImageStackOptions

    var body: some View {
        DisclosureGroup("Registration and processing") {
            Picker("Registration model", selection: $options.registrationModel) {
                ForEach(StackRegistrationModel.allCases) { Text($0.title).tag($0) }
            }
            Text("Similarity fits shift, rotation, and scale. Affine adds shear; quadratic can fit lens distortion. Too few matched stars falls back to similarity.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Frame weights", selection: $options.weighting) {
                ForEach(StackWeighting.allCases) { Text($0.title).tag($0) }
            }
            if options.weighting == .inverseNoiseVariance {
                TextField("Minimum weight", value: $options.minimumWeight, format: .number)
                TextField("Maximum weight", value: $options.maximumWeight, format: .number)
                Text("Give less weight to noisier frames. The reference has weight 1.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Picker("Interpolation", selection: $options.interpolation) {
                ForEach(StackInterpolation.allCases) { Text($0.title).tag($0) }
            }
            Text("Lanczos-3 can keep stars sharper, but takes longer and may ring near bright edges.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Bayer integration", selection: $options.cfaIntegration) {
                ForEach(StackCfaIntegration.allCases) { Text($0.title).tag($0) }
            }
            if options.cfaIntegration == .bayerDrizzle {
                Text("Bayer drizzle needs well-dithered frames to fill each color channel. It does not enlarge the output. Mono and RGB frames use normal integration.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Picker("Bayer demosaic", selection: $options.demosaic) {
                ForEach(StackDemosaic.allCases) { Text($0.title).tag($0) }
            }
            Text("Bayer frames only. VNG keeps star colors even; MHC is sharper but may ring; bilinear is faster and softer. Drizzle still uses demosaicing for registration and normalization.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Suppress hot and dead pixels", isOn: $options.suppressesHotPixels)
            if options.suppressesHotPixels {
                TextField("Low sigma", value: $options.cosmeticLowSigma, format: .number)
                TextField("High sigma", value: $options.cosmeticHighSigma, format: .number)
                Text("Replace isolated outlier pixels after calibration and before demosaicing.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct StackReferenceSelection: Decodable, Sendable {
    struct Score: Decodable, Sendable {
        let stars: Int
        let medianStarArea: Double
        let background: Double
        let backgroundVariation: Double
        let score: Double
    }
    let schemaVersion: Int
    let referenceIndex: Int
    let referencePath: String
    let scores: [Score?]
    /// Optional for decoding older saved/test responses; the pinned core supplies it.
    let ranking: [Int]?

    var candidateIndices: [Int] { Array((ranking ?? [referenceIndex]).prefix(5)) }

    func validate(paths: [String]) throws {
        guard schemaVersion == 1, scores.count == paths.count,
            paths.indices.contains(referenceIndex), paths[referenceIndex] == referencePath,
            scores[referenceIndex] != nil,
            scores.compactMap({ $0 }).allSatisfy({
                $0.stars >= 0 && $0.medianStarArea.isFinite && $0.medianStarArea > 0
                    && $0.background.isFinite && $0.backgroundVariation.isFinite
                    && $0.backgroundVariation >= 0 && $0.score.isFinite && $0.score > 0
            })
        else { throw ImageStackError.core("Seiza returned an invalid reference selection.") }
        if let ranking {
            let scored = Set(scores.indices.filter { scores[$0] != nil })
            guard ranking.first == referenceIndex, Set(ranking) == scored,
                ranking.count == scored.count else {
                throw ImageStackError.core("Seiza returned an invalid reference ranking.")
            }
        }
    }
}

/// Validated result of trying ranked channel lights against one alignment image.
struct StackChannelReferenceSelection: Decodable, Sendable {
    struct Skipped: Decodable, Sendable {
        let index: Int
        let path: String
        let reason: String
    }
    let schemaVersion: Int
    let channelReferenceIndex: Int
    let channelReferencePath: String
    let skipped: [Skipped]

    func validate(paths: [String]) throws {
        guard schemaVersion == 1, paths.indices.contains(channelReferenceIndex),
            paths[channelReferenceIndex] == channelReferencePath,
            skipped.map(\.index) == Array(0..<channelReferenceIndex),
            skipped.allSatisfy({ paths[$0.index] == $0.path && !$0.reason.isEmpty })
        else { throw ImageStackError.core("Seiza returned an invalid channel reference selection.") }
    }

    var summary: String {
        var text = "Channel reference: \(URL(fileURLWithPath: channelReferencePath).lastPathComponent)."
        for item in skipped {
            text += " Skipped \(URL(fileURLWithPath: item.path).lastPathComponent): \(item.reason)"
        }
        return text
    }
}

/// Both drivers share ownership and response validation at the C boundary.
/// The caller owns the returned handle. An external alignment image opens an
/// empty accumulator; its selected channel light must be pushed first.
enum StackNativeOpener {
    static func openExpanded(
        paths: [String], optionsJSON: String, calibration: ImageStackCalibration,
        maximumMegasamples: Int, cancellation: ImageStackCancellation,
        libraryPlan: LibraryPreparedPlan? = nil
    ) throws -> (handle: OpaquePointer, note: String) {
        guard paths.count >= 2, (1...4096).contains(maximumMegasamples) else {
            throw ImageStackError.invalidRequest("Choose at least two lights and a valid canvas sample limit.")
        }
        guard Set(paths).count == paths.count else {
            throw ImageStackError.invalidRequest("Mosaic lights must be distinct.")
        }
        let pathsJSON = String(decoding: try JSONEncoder().encode(paths), as: UTF8.self)
        var error: UnsafeMutablePointer<CChar>?
        defer { if let error { seiza_string_free(error) } }
        let handle: OpaquePointer?
        if let libraryPlan {
            let sessionsJSON = String(decoding: try JSONEncoder().encode(libraryPlan.review.fileSessions), as: UTF8.self)
            let assignments = try paths.map { libraryPlan.review.assignments[try libraryPlan.index($0)] }
            let assignmentsJSON = String(decoding: try JSONEncoder().encode(assignments), as: UTF8.self)
            handle = pathsJSON.withCString { paths in sessionsJSON.withCString { sessions in
                assignmentsJSON.withCString { assignments in optionsJSON.withCString { options in
                    seiza_live_stacker_open_fits_expanding_sessions(paths, sessions, assignments, options,
                        maximumMegasamples, cancellation.nativeSignal?.pointer, &error)
                } }
            } }
        } else {
        handle = withOptionalCString(calibration.bias?.path) { bias in
            withOptionalCString(calibration.dark?.path) { dark in
                withOptionalCString(calibration.flat?.path) { flat in
                    pathsJSON.withCString { paths in
                        optionsJSON.withCString { options in
                            seiza_live_stacker_open_fits_expanding(paths, bias, dark, flat,
                                calibration.overridesDarkExposure ? calibration.darkExposureSeconds : 0,
                                options, maximumMegasamples, cancellation.nativeSignal?.pointer, &error)
                        }
                    }
                }
            }
        }
        }
        // Take ownership before observing cancellation: even cancelled opens may return a handle.
        guard let handle else {
            if cancellation.isCancelled { throw CancellationError() }
            throw ImageStackError.core(CalibrationService.takeOwnedError(&error, fallback: "Could not plan the mosaic canvas."))
        }
        do {
            if cancellation.isCancelled { throw CancellationError() }
            guard seiza_live_stacker_accepted_frames(handle) == 0,
                seiza_live_stacker_rejected_frames(handle) == 0 else {
                throw ImageStackError.core("The mosaic plan was not empty.")
            }
            func readJSON(_ call: (OpaquePointer, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> UnsafeMutablePointer<CChar>?) throws -> Data {
                var localError: UnsafeMutablePointer<CChar>?
                defer { if let localError { seiza_string_free(localError) } }
                guard let value = call(handle, &localError) else {
                    throw ImageStackError.core(CalibrationService.takeOwnedError(&localError, fallback: "Could not read mosaic planning notes."))
                }
                defer { seiza_string_free(value) }
                return Data(bytes: value, count: strlen(value))
            }
            let notes = try JSONDecoder().decode([String].self,
                from: readJSON(seiza_live_stacker_expansion_planning_notes_json))
            let lens = try JSONSerialization.jsonObject(with: readJSON(seiza_live_stacker_expanded_lens_json), options: [.fragmentsAllowed])
            var note = "Expanded mosaic canvas: \(seiza_live_stacker_width(handle)) × \(seiza_live_stacker_height(handle)), \(seiza_live_stacker_channels(handle)) channel(s)."
            if let lens = lens as? [String: Any], let shift = lens["largestShiftPixels"] as? Double {
                note += String(format: " Lens correction: %.2f sensor pixels maximum shift.", shift)
            }
            if !notes.isEmpty { note += " " + notes.joined(separator: " ") }
            return (handle, note)
        } catch {
            seiza_live_stacker_free(handle)
            throw error
        }
    }

    static func open(
        candidates: [String], referenceImagePath: String?,
        optionsJSON: String, calibration: ImageStackCalibration
    ) throws -> (handle: OpaquePointer, selection: StackChannelReferenceSelection?) {
        guard let first = candidates.first else {
            throw ImageStackError.invalidRequest("Choose a channel reference light.")
        }
        let pathsJSON = String(decoding: try JSONEncoder().encode(candidates), as: UTF8.self)
        var error: UnsafeMutablePointer<CChar>?
        var selectionJSON: UnsafeMutablePointer<CChar>?
        defer {
            if let error { seiza_string_free(error) }
            if let selectionJSON { seiza_string_free(selectionJSON) }
        }
        let handle = withOptionalCString(calibration.bias?.path) { bias in
            withOptionalCString(calibration.dark?.path) { dark in
                withOptionalCString(calibration.flat?.path) { flat in
                    optionsJSON.withCString { options in
                        let exposure = calibration.overridesDarkExposure ? calibration.darkExposureSeconds : 0
                        if let referenceImagePath {
                            return referenceImagePath.withCString { image in
                                pathsJSON.withCString { paths in
                                    seiza_live_stacker_open_fits_with_reference_image_candidates(
                                        image, paths, bias, dark, flat, exposure, options, &selectionJSON, &error)
                                }
                            }
                        }
                        return first.withCString {
                            seiza_live_stacker_open_fits($0, bias, dark, flat, exposure, options, &error)
                        }
                    }
                }
            }
        }
        guard let handle else {
            throw ImageStackError.core(CalibrationService.takeOwnedError(
                &error, fallback: "The reference could not be opened."))
        }
        do {
            var selection: StackChannelReferenceSelection?
            if referenceImagePath != nil {
                guard let selectionJSON else {
                    throw ImageStackError.core("The channel reference selection is missing.")
                }
                selection = try JSONDecoder().decode(StackChannelReferenceSelection.self,
                    from: Data(bytes: selectionJSON, count: strlen(selectionJSON)))
                try selection?.validate(paths: candidates)
            }
            let expectedCount: UInt = referenceImagePath == nil ? 1 : 0
            guard seiza_live_stacker_accepted_frames(handle) == expectedCount else {
                throw ImageStackError.core("The reference opened with unexpected frame counts.")
            }
            return (handle, selection)
        } catch {
            seiza_live_stacker_free(handle)
            throw error
        }
    }
}

enum StackInputProtection {
    static func referenceIdentity(_ path: String?) -> String? {
        path.map { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path }
    }

    /// Include symlinks and hard links: writing through an atomic staging file
    /// must not bypass native source protection for the final destination.
    static func sameFile(_ a: URL, _ b: URL) -> Bool {
        if LiveStackPath.equals(a.resolvingSymlinksInPath().path, b.resolvingSymlinksInPath().path) {
            return true
        }
        let keys: Set<URLResourceKey> = [.fileResourceIdentifierKey]
        if let left = try? a.resourceValues(forKeys: keys).fileResourceIdentifier as? NSObject,
            let right = try? b.resourceValues(forKeys: keys).fileResourceIdentifier as? NSObject {
            return left.isEqual(right)
        }
        return false
    }

    static func validate(output: URL, sources: [URL]) throws {
        guard !sources.contains(where: { sameFile(output, $0) }) else {
            throw ImageStackError.invalidRequest(
                "Choose an output file that is not a light, calibration master, or alignment image.")
        }
    }
}

enum StackReferenceSelector {
    /// Synchronous native scoring; callers run this away from the main actor.
    /// One frame at a time bounds memory use. Cancellation is checked around
    /// the call because this C ABI does not provide a cancellation callback.
    static func choose(_ urls: [URL]) throws -> StackReferenceSelection {
        guard !urls.isEmpty else { throw ImageStackError.invalidRequest("Choose reference candidates first.") }
        let accessed = urls.filter { $0.startAccessingSecurityScopedResource() }
        defer { accessed.forEach { $0.stopAccessingSecurityScopedResource() } }
        let paths = urls.map(\.path)
        let json = String(decoding: try JSONEncoder().encode(paths), as: UTF8.self)
        var error: UnsafeMutablePointer<CChar>?
        let pointer = json.withCString { seiza_stack_choose_reference_json($0, 1, &error) }
        guard let pointer else {
            throw ImageStackError.core(CalibrationService.takeOwnedError(
                &error, fallback: "No frame could be scored as a reference."))
        }
        defer { seiza_string_free(pointer) }
        let result = try JSONDecoder().decode(StackReferenceSelection.self,
            from: Data(bytes: pointer, count: strlen(pointer)))
        try result.validate(paths: paths)
        return result
    }
}

struct ImageStackCalibration: Equatable, Sendable {
    var bias: URL?
    var dark: URL?
    var flat: URL?
    var overridesDarkExposure = false
    var darkExposureSeconds = 300.0

    var validationMessage: String? {
        guard dark != nil || !overridesDarkExposure else {
            return "Choose a master dark before overriding its exposure."
        }
        if overridesDarkExposure,
           (!darkExposureSeconds.isFinite || darkExposureSeconds <= 0) {
            return "The master-dark exposure must be positive."
        }
        return nil
    }

    func validationMessage(for inputs: [URL]) -> String? {
        if let validationMessage { return validationMessage }
        let urls = inputs + [bias, dark, flat].compactMap { $0 }
        let paths = urls.map { $0.standardizedFileURL.path }
        guard Set(paths).count == paths.count else {
            return "Each light frame and calibration master must be a different file."
        }
        return nil
    }
}

struct ImageStackRequest: Sendable {
    let inputs: [URL]
    let output: URL
    let outputAccessURL: URL?
    let options: ImageStackOptions
    let calibration: ImageStackCalibration
    let referenceImage: URL?
    let choosesReferenceAutomatically: Bool
    let additionalProtectedSources: [URL]
    let libraryPlan: LibraryPreparedPlan?

    var protectedSources: [URL] {
        inputs + additionalProtectedSources + (libraryPlan?.review.sources.map { URL(fileURLWithPath: $0.path) } ?? []) + [calibration.bias, calibration.dark, calibration.flat, referenceImage].compactMap { $0 }
    }

    init(
        inputs: [URL],
        output: URL,
        outputAccessURL: URL? = nil,
        options: ImageStackOptions,
        calibration: ImageStackCalibration,
        referenceImage: URL? = nil,
        choosesReferenceAutomatically: Bool = false,
        additionalProtectedSources: [URL] = [],
        libraryPlan: LibraryPreparedPlan? = nil
    ) {
        self.inputs = inputs
        self.output = output
        self.outputAccessURL = outputAccessURL
        self.options = options
        self.calibration = calibration
        self.referenceImage = referenceImage
        self.choosesReferenceAutomatically = choosesReferenceAutomatically
        self.additionalProtectedSources = additionalProtectedSources
        self.libraryPlan = libraryPlan
    }
}

struct ImageStackGroup: Identifiable, Sendable {
    let id: String
    let filter: ImageFilenameFilter?
    let inputs: [URL]

    var fieldTitle: String? = nil
    var outputSuffix: String? = nil

    var title: String {
        if let fieldTitle { return fieldTitle + (filter.map { " · " + $0.title } ?? "") }
        return filter?.title ?? (id == "all" ? "All frames" : "Other")
    }

    var filenameSuffix: String {
        outputSuffix ?? filter?.filenameSuffix ?? "Other"
    }
}

enum ImageStackGrouping {
    static func hasMultipleDetectedFilters(in urls: [URL]) -> Bool {
        Set(urls.compactMap { ImageFilenameFilter.detect(in: $0)?.id }).count > 1
    }

    static func groups(for urls: [URL], splitByFilter: Bool) -> [ImageStackGroup] {
        guard splitByFilter, hasMultipleDetectedFilters(in: urls)
        else {
            return [ImageStackGroup(id: "all", filter: nil, inputs: urls)]
        }

        var order: [String] = []
        var groups: [String: ImageStackGroup] = [:]
        for url in urls {
            let filter = ImageFilenameFilter.detect(in: url)
            let key = filter?.id ?? "other"
            if groups[key] == nil {
                order.append(key)
                groups[key] = ImageStackGroup(id: key, filter: filter, inputs: [])
            }
            let current = groups[key]!
            groups[key] = ImageStackGroup(
                id: key,
                filter: current.filter,
                inputs: current.inputs + [url]
            )
        }
        return order.compactMap { groups[$0] }
    }
}

struct ImageStackJob: Sendable {
    let group: ImageStackGroup
    let request: ImageStackRequest
}

struct ImageStackBatchRequest: Sendable {
    let jobs: [ImageStackJob]
}

struct ImageStackDisposition: Decodable, Sendable {
    let source: String?
    let accepted: Bool
    let reason: String?
}

struct ImageStackProgress: Sendable {
    enum Phase: Sendable {
        case preparing
        case stacking
        case removingTransients
        case writing
    }

    let phase: Phase
    let message: String
    let completedFrames: Int
    let totalFrames: Int
    let acceptedFrames: Int
    let rejectedFrames: Int
    /// Progress through the current phase when it does not advance by
    /// input frame, as while removing transients.
    var phaseFraction: Double? = nil

    var fractionCompleted: Double? {
        if let phaseFraction {
            return min(max(phaseFraction, 0), 1)
        }
        guard totalFrames > 0 else { return nil }
        return min(max(Double(completedFrames) / Double(totalFrames), 0), 1)
    }
}

struct ImageStackResult: Sendable {
    let output: URL
    let acceptedFrames: Int
    let rejectedFrames: Int
    let dispositions: [ImageStackDisposition]
    var snrAnalysis: StackSnrAnalysis = .empty
    var snrWarning: String? = nil
    /// Set when transient removal was requested but did not run, saying
    /// why; the stack was written from the live result instead.
    var transientNote: String? = nil
    var referenceNote: String? = nil
}

struct ImageStackBatchResult: Sendable {
    let results: [ImageStackResult]
    let outputAccessURLs: [URL]

    var acceptedFrames: Int { results.reduce(0) { $0 + $1.acceptedFrames } }
    var rejectedFrames: Int { results.reduce(0) { $0 + $1.rejectedFrames } }
}

private struct ImageStackBatchCancellation: Error {
    let completedOutputs: [URL]
}

private struct ImageStackBatchFailure: LocalizedError {
    let underlying: Error
    let completedOutputs: [URL]

    var errorDescription: String? {
        let saved = completedOutputs.map(\.lastPathComponent).joined(separator: ", ")
        return "\(underlying.localizedDescription) Already saved: \(saved)."
    }
}

enum ImageStackError: LocalizedError {
    case invalidRequest(String)
    case core(String)
    case noAdditionalFrames([ImageStackDisposition])

    var errorDescription: String? {
        switch self {
        case .invalidRequest(let message), .core(let message):
            return message
        case .noAdditionalFrames(let dispositions):
            let reason = dispositions.compactMap(\.reason).first
            if let reason {
                return "No frame beyond the reference was accepted. \(reason)"
            } else {
                return "No frame beyond the reference was accepted."
            }
        }
    }
}

final class ImageStackCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    /// Stops long native calls, such as transient removal, mid-call. Nil
    /// only if the core could not create a signal; cancellation then waits
    /// for the call to return.
    let nativeSignal: CalibrationCancelSignal?

    init() {
        nativeSignal = try? CalibrationCancelSignal()
    }

    var isCancelled: Bool {
        lock.withLock { value }
    }

    func cancel() {
        lock.withLock { value = true }
        nativeSignal?.cancel()
    }
}

enum ImageStackEngine {
    static func stack(
        request: ImageStackRequest,
        cancellation: ImageStackCancellation,
        progress: @Sendable (ImageStackProgress) -> Void
    ) throws -> ImageStackResult {
        guard request.inputs.count >= 2 else {
            throw ImageStackError.invalidRequest("Choose at least two images to stack.")
        }
        if request.options.canvasMode == .expanded, request.referenceImage != nil {
            throw ImageStackError.invalidRequest("Expanded mosaics cannot use a shared fixed alignment image.")
        }
        if let message = request.options.validationMessage
            ?? request.calibration.validationMessage(for: request.inputs) {
            throw ImageStackError.invalidRequest(message)
        }

        let accessURLs = Set(
            request.protectedSources + (request.libraryPlan?.accessURLs ?? []) + [
                request.calibration.bias,
                request.calibration.dark,
                request.calibration.flat,
                request.output,
                request.outputAccessURL,
                request.referenceImage,
            ].compactMap { $0 }
        )
        let accessedURLs = accessURLs.filter { $0.startAccessingSecurityScopedResource() }
        defer { accessedURLs.forEach { $0.stopAccessingSecurityScopedResource() } }
        try StackInputProtection.validate(output: request.output, sources: request.protectedSources)

        if cancellation.isCancelled { throw CancellationError() }
        progress(ImageStackProgress(
            phase: .preparing,
            message: "Opening reference image…",
            completedFrames: 0,
            totalFrames: request.inputs.count,
            acceptedFrames: 0,
            rejectedFrames: 0
        ))

        if let plan = request.libraryPlan { try CalibrationLibraryService.verify(plan.review.sources) }
        let optionsJSON = String(decoding: try request.options.jsonData, as: UTF8.self)
        var errorPointer: UnsafeMutablePointer<CChar>?
        var candidates = [request.inputs[0]]
        if request.choosesReferenceAutomatically {
            progress(ImageStackProgress(phase: .preparing,
                message: "Scoring \(request.inputs.count) channel reference candidates…",
                completedFrames: 0, totalFrames: request.inputs.count, acceptedFrames: 0, rejectedFrames: 0))
            let ranked = try StackReferenceSelector.choose(request.inputs)
            if cancellation.isCancelled { throw CancellationError() }
            candidates = ranked.candidateIndices.map { request.inputs[$0] }
        }
        progress(ImageStackProgress(phase: .preparing,
            message: request.referenceImage == nil ? "Opening channel reference…"
                : "Aligning channel reference to shared image (up to \(candidates.count) candidates)…",
            completedFrames: 0, totalFrames: request.inputs.count, acceptedFrames: 0, rejectedFrames: 0))
        let expanded = request.options.canvasMode == .expanded
        var canvasNote: String?
        let opened: (handle: OpaquePointer, selection: StackChannelReferenceSelection?)
        if expanded {
            let anchor = candidates[0]
            let paths = ([anchor] + request.inputs.filter { $0 != anchor }).map(\.path)
            let plan = try StackNativeOpener.openExpanded(paths: paths, optionsJSON: optionsJSON,
                calibration: request.calibration, maximumMegasamples: request.options.maximumCanvasMegasamples,
                cancellation: cancellation, libraryPlan: request.libraryPlan)
            opened = (plan.handle, nil)
            canvasNote = plan.note
        } else if let plan = request.libraryPlan {
            // Each ranked candidate must open with its own complete calibration
            // gate. A failed open owns no state and cannot leak the previous set.
            var selected: (handle: OpaquePointer, selection: StackChannelReferenceSelection?)?
            var failures: [String] = []
            for candidate in candidates {
                let session = try plan.session(for: candidate.path)
                var options = try JSONSerialization.jsonObject(with: request.options.jsonData) as! [String: Any]
                // This existing StackOptions subdocument uses native snake_case;
                // file-coordinator reports use the C ABI's camelCase fields.
                let fields = ["allow_flat_gain_offset_mismatch", "exposure_seconds", "exposure_fraction", "dark_temperature_c", "rotation_deg", "focal_length_mm", "light_rotation"]
                let values = Dictionary(uniqueKeysWithValues: fields.compactMap { key -> (String, LibraryJSON)? in
                    let value = session.tolerances[key]
                    if case .null = value { return nil }
                    return (key, value)
                })
                let gate = try JSONSerialization.jsonObject(with: JSONEncoder().encode(values)) as! [String: Any]
                // StackOptions accepts application gates only; master cohort
                // temperature/session windows belong to file-session policy.
                options["match_tolerances"] = gate
                let json = String(decoding: try JSONSerialization.data(withJSONObject: options), as: UTF8.self)
                do {
                    selected = try StackNativeOpener.open(candidates: [candidate.path],
                        referenceImagePath: request.referenceImage?.path, optionsJSON: json,
                        calibration: session.calibration)
                    candidates = [candidate]
                    break
                } catch { failures.append("\(candidate.lastPathComponent): \(error.localizedDescription)") }
            }
            guard let selected else { throw ImageStackError.core(failures.joined(separator: "\n")) }
            opened = selected
        } else {
            opened = try StackNativeOpener.open(candidates: candidates.map(\.path),
                referenceImagePath: request.referenceImage?.path, optionsJSON: optionsJSON,
                calibration: request.calibration)
        }
        var liveStacker: OpaquePointer? = opened.handle
        defer {
            if let liveStacker {
                seiza_live_stacker_free(liveStacker)
            }
        }

        if cancellation.isCancelled { throw CancellationError() }
        let chosen = URL(fileURLWithPath: opened.selection?.channelReferencePath ?? candidates[0].path)
        let orderedInputs = [chosen] + request.inputs.filter { $0.path != chosen.path }
        let initialCount = !expanded && request.referenceImage == nil ? 1 : 0
        let referenceNote = canvasNote ?? opened.selection.map { selection in
            "Alignment image: \(request.referenceImage!.lastPathComponent). " + selection.summary
        }
        var dispositions: [ImageStackDisposition] = []
        var unreadableFrames = 0
        let snrDepths = StackSnrMeasurementSchedule.depths(
            totalFrames: request.inputs.count)
        var snrAttemptedDepths: Set<Int> = []
        var snrSamples: [StackSnrMeasurement] = []
        var snrWarning: String?
        tryMeasureSnr(
            liveStacker,
            scheduledDepths: snrDepths,
            attemptedDepths: &snrAttemptedDepths,
            samples: &snrSamples,
            warning: &snrWarning,
            includeCurrentDepth: false)
        progress(ImageStackProgress(
            phase: .stacking,
            message: referenceNote ?? chosen.lastPathComponent,
            completedFrames: initialCount,
            totalFrames: request.inputs.count,
            acceptedFrames: initialCount,
            rejectedFrames: 0
        ))

        for (offset, url) in orderedInputs.dropFirst(initialCount).enumerated() {
            if cancellation.isCancelled { throw CancellationError() }
            if let plan = request.libraryPlan {
                try plan.verifyActiveSources(for: url.path)
                if !expanded, let liveStacker { try plan.session(for: url.path).apply(to: liveStacker) }
            }
            errorPointer = nil
            let responsePointer = url.path.withCString { path in
                seiza_live_stacker_push_fits_json(liveStacker, path, &errorPointer)
            }
            if let responsePointer {
                defer { seiza_string_free(responsePointer) }
                let data = Data(bytes: responsePointer, count: strlen(responsePointer))
                dispositions.append(try JSONDecoder().decode(
                    ImageStackDisposition.self,
                    from: data
                ))
            } else {
                unreadableFrames += 1
                dispositions.append(ImageStackDisposition(
                    source: url.path,
                    accepted: false,
                    reason: CalibrationService.takeOwnedError(
                        &errorPointer,
                        fallback: "Seiza returned an invalid stacking response.")
                ))
            }

            let accepted = Int(seiza_live_stacker_accepted_frames(liveStacker))
            let rejected = Int(seiza_live_stacker_rejected_frames(liveStacker))
                + unreadableFrames
            if initialCount == 0, offset == 0, accepted != 1 {
                throw ImageStackError.core(dispositions.last?.reason
                    ?? "The selected channel reference could not be integrated.")
            }
            tryMeasureSnr(
                liveStacker,
                scheduledDepths: snrDepths,
                attemptedDepths: &snrAttemptedDepths,
                samples: &snrSamples,
                warning: &snrWarning,
                includeCurrentDepth: false)
            progress(ImageStackProgress(
                phase: .stacking,
                message: url.lastPathComponent,
                completedFrames: offset + initialCount + 1,
                totalFrames: request.inputs.count,
                acceptedFrames: accepted,
                rejectedFrames: rejected
            ))
        }

        if cancellation.isCancelled { throw CancellationError() }
        if let plan = request.libraryPlan { try CalibrationLibraryService.verify(plan.review.sources) }
        guard seiza_live_stacker_accepted_frames(liveStacker) > 1 else {
            throw ImageStackError.noAdditionalFrames(dispositions)
        }
        tryMeasureSnr(
            liveStacker,
            scheduledDepths: snrDepths,
            attemptedDepths: &snrAttemptedDepths,
            samples: &snrSamples,
            warning: &snrWarning,
            includeCurrentDepth: true)
        let acceptedBeforeFinish = Int(seiza_live_stacker_accepted_frames(liveStacker))
        let rejectedBeforeFinish = Int(seiza_live_stacker_rejected_frames(liveStacker))
            + unreadableFrames

        var reintegrated: LiveStackFinishedSnapshot?
        var transientNote: String?
        if request.options.removesTransients, let handle = liveStacker {
            do {
                if let reason = try LiveStackReintegration.unavailableReason(handle) {
                    transientNote = "Transients were not removed: \(reason)"
                } else {
                    progress(ImageStackProgress(
                        phase: .removingTransients,
                        message: "Removing transients…",
                        completedFrames: request.inputs.count,
                        totalFrames: request.inputs.count,
                        acceptedFrames: acceptedBeforeFinish,
                        rejectedFrames: rejectedBeforeFinish,
                        phaseFraction: 0
                    ))
                    let sigmas = request.options.reintegrationSigmas
                    reintegrated = try LiveStackReintegration.run(
                        handle,
                        lowSigma: sigmas.low,
                        highSigma: sigmas.high,
                        cancel: cancellation.nativeSignal
                    ) { step in
                        progress(ImageStackProgress(
                            phase: .removingTransients,
                            message: step.message,
                            completedFrames: request.inputs.count,
                            totalFrames: request.inputs.count,
                            acceptedFrames: acceptedBeforeFinish,
                            rejectedFrames: rejectedBeforeFinish,
                            phaseFraction: step.fractionCompleted
                        ))
                    }
                }
            } catch {
                if cancellation.isCancelled { throw CancellationError() }
                transientNote = "Transients were not removed: "
                    + error.localizedDescription
            }
        }
        defer { reintegrated?.free() }

        if cancellation.isCancelled { throw CancellationError() }
        progress(ImageStackProgress(
            phase: .writing,
            message: "Writing \(request.output.lastPathComponent)…",
            completedFrames: request.inputs.count,
            totalFrames: request.inputs.count,
            acceptedFrames: acceptedBeforeFinish,
            rejectedFrames: rejectedBeforeFinish
        ))

        // Finish even when the reintegrated snapshot is written, so the
        // stacker is consumed and freed on one path.
        errorPointer = nil
        let snapshot = seiza_live_stacker_finish(&liveStacker, &errorPointer)
        guard let snapshot else {
            throw ImageStackError.core(CalibrationService.takeOwnedError(
                &errorPointer, fallback: "Seiza returned an invalid stacking response."))
        }
        defer { seiza_stack_snapshot_free(snapshot) }

        if cancellation.isCancelled { throw CancellationError() }
        do {
            if let reintegrated {
                try reintegrated.writeFITS(to: request.output.path)
            } else {
                try LiveStackAtomicFITS.write(to: request.output.path) {
                    stagingPath, stagingError in
                    stagingPath.withCString { path in
                        seiza_stack_snapshot_write_fits(snapshot, path, &stagingError)
                    }
                }
            }
        } catch {
            throw ImageStackError.core(error.localizedDescription)
        }
        return ImageStackResult(
            output: request.output,
            acceptedFrames: Int(seiza_stack_snapshot_accepted_frames(snapshot)),
            rejectedFrames: Int(seiza_stack_snapshot_rejected_frames(snapshot))
                + unreadableFrames,
            dispositions: dispositions,
            snrAnalysis: StackSnrAnalyzer.analyze(snrSamples),
            snrWarning: snrWarning,
            transientNote: transientNote,
            referenceNote: referenceNote
        )
    }

    /// Measures accumulator noise at the scheduled doubling depths and once
    /// more at the final depth. A missing reading or a failure never affects
    /// the stack; the first failure is kept as a warning.
    private static func tryMeasureSnr(
        _ liveStacker: OpaquePointer?,
        scheduledDepths: Set<Int>,
        attemptedDepths: inout Set<Int>,
        samples: inout [StackSnrMeasurement],
        warning: inout String?,
        includeCurrentDepth: Bool
    ) {
        guard let liveStacker else { return }
        let accepted = Int(seiza_live_stacker_accepted_frames(liveStacker))
        guard accepted > 0 else { return }
        if includeCurrentDepth {
            // The closing measurement may retry a depth that was unavailable
            // earlier.
        } else {
            guard scheduledDepths.contains(accepted),
                attemptedDepths.insert(accepted).inserted
            else { return }
        }
        guard !samples.contains(where: { Int($0.frames) == accepted }) else { return }

        var nativeSample = SeizaSnrSample()
        var errorPointer: UnsafeMutablePointer<CChar>?
        let result = seiza_live_stacker_measure_depth(
            liveStacker, &nativeSample, &errorPointer)
        switch result {
        case 1:
            CalibrationService.discardError(&errorPointer)
            let sample = StackSnrSample(native: nativeSample)
            guard Int(sample.frames) == accepted else { return }
            samples.append(StackSnrMeasurement(
                frames: sample.frames,
                noise: sample.noise,
                background: sample.background,
                signal: sample.signal))
        case 0 where errorPointer == nil:
            break
        default:
            let message = CalibrationService.takeOwnedError(
                &errorPointer, fallback: "The Seiza core could not measure the stack.")
            if warning == nil {
                warning = "SNR analysis was unavailable: \(message)"
            }
        }
    }

}

enum ImageStackBatchEngine {
    static func stack(
        request: ImageStackBatchRequest,
        cancellation: ImageStackCancellation,
        progress: @Sendable (ImageStackProgress) -> Void
    ) throws -> ImageStackBatchResult {
        guard !request.jobs.isEmpty else {
            throw ImageStackError.invalidRequest("Choose at least one stack group.")
        }
        let sources = request.jobs.flatMap { $0.request.protectedSources }
        var outputs: [URL] = []
        for job in request.jobs {
            try StackInputProtection.validate(output: job.request.output, sources: sources + outputs)
            outputs.append(job.request.output)
        }
        let totalFrames = request.jobs.reduce(0) { $0 + $1.request.inputs.count }
        var completedFrames = 0
        var acceptedFrames = 0
        var rejectedFrames = 0
        var results: [ImageStackResult] = []

        for job in request.jobs {
            if cancellation.isCancelled {
                throw ImageStackBatchCancellation(
                    completedOutputs: results.map(\.output)
                )
            }
            let prefix = request.jobs.count > 1 ? "\(job.group.title): " : ""
            let completedBeforeJob = completedFrames
            let acceptedBeforeJob = acceptedFrames
            let rejectedBeforeJob = rejectedFrames
            let result: ImageStackResult
            do {
                result = try ImageStackEngine.stack(
                    request: job.request,
                    cancellation: cancellation,
                    progress: { update in
                        progress(ImageStackProgress(
                            phase: update.phase,
                            message: prefix + update.message,
                            completedFrames: completedBeforeJob + update.completedFrames,
                            totalFrames: totalFrames,
                            acceptedFrames: acceptedBeforeJob + update.acceptedFrames,
                            rejectedFrames: rejectedBeforeJob + update.rejectedFrames,
                            phaseFraction: update.phaseFraction
                        ))
                    }
                )
            } catch is CancellationError {
                throw ImageStackBatchCancellation(
                    completedOutputs: results.map(\.output)
                )
            } catch {
                guard !results.isEmpty else { throw error }
                throw ImageStackBatchFailure(
                    underlying: error,
                    completedOutputs: results.map(\.output)
                )
            }
            results.append(result)
            completedFrames += job.request.inputs.count
            acceptedFrames += result.acceptedFrames
            rejectedFrames += result.rejectedFrames
        }
        let outputAccessURLs = Array(Set(
            request.jobs.compactMap { $0.request.outputAccessURL }
        ))
        return ImageStackBatchResult(
            results: results,
            outputAccessURLs: outputAccessURLs
        )
    }
}

@MainActor
final class ImageStackCoordinator: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var isCancelling = false
    @Published private(set) var progress: ImageStackProgress?
    @Published private(set) var errorMessage: String?
    @Published private(set) var cancellationMessage: String?

    private var cancellation: ImageStackCancellation?
    private var task: Task<Void, Never>?

    func start(
        request: ImageStackBatchRequest,
        onSuccess: @escaping @MainActor (ImageStackBatchResult) -> Void
    ) {
        guard !isRunning else { return }
        let cancellation = ImageStackCancellation()
        self.cancellation = cancellation
        isRunning = true
        isCancelling = false
        errorMessage = nil
        cancellationMessage = nil
        progress = ImageStackProgress(
            phase: .preparing,
            message: "Preparing stack…",
            completedFrames: 0,
            totalFrames: request.jobs.reduce(0) { $0 + $1.request.inputs.count },
            acceptedFrames: 0,
            rejectedFrames: 0
        )

        task = Task { [weak self] in
            let (updates, continuation) = AsyncStream.makeStream(of: ImageStackProgress.self)
            let progressTask = Task { @MainActor [weak self] in
                for await update in updates {
                    self?.progress = update
                }
            }
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try ImageStackBatchEngine.stack(
                        request: request,
                        cancellation: cancellation,
                        progress: { continuation.yield($0) }
                    )
                }.value
                continuation.finish()
                await progressTask.value
                guard let self else { return }
                self.isRunning = false
                self.cancellation = nil
                self.task = nil
                onSuccess(result)
            } catch let cancellation as ImageStackBatchCancellation {
                continuation.finish()
                await progressTask.value
                guard let self else { return }
                self.isRunning = false
                self.isCancelling = false
                self.cancellation = nil
                self.task = nil
                if cancellation.completedOutputs.isEmpty {
                    self.cancellationMessage = "Stacking was canceled. No output was written."
                } else {
                    let saved = cancellation.completedOutputs
                        .map(\.lastPathComponent)
                        .joined(separator: ", ")
                    self.cancellationMessage = "Stacking was canceled. Already saved: \(saved)."
                }
            } catch {
                continuation.finish()
                await progressTask.value
                guard let self else { return }
                self.isRunning = false
                self.isCancelling = false
                self.cancellation = nil
                self.task = nil
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func cancel() {
        guard isRunning, !isCancelling else { return }
        isCancelling = true
        cancellation?.cancel()
    }
}

struct ImageStackWorkflowView: View {
    let urls: [URL]
    let onComplete: (ImageStackBatchResult) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var coordinator = ImageStackCoordinator()
    @StateObject private var libraryModel = CalibrationLibraryModel()
    @State private var showsLibraryReview = false
    @State private var selectedURLs: Set<URL>
    @State private var referenceURLs: [String: URL] = [:]
    @State private var automaticReferenceGroups: Set<String> = []
    @State private var referenceImage: URL?
    @State private var options = ImageStackOptions()
    @State private var calibration = ImageStackCalibration()
    @State private var calibrationSource = StackCalibrationSource.masters
    @State private var calibrationLibrary: URL?
    @State private var providedCalibration: [URL] = []
    @State private var splitByFilenameFilter = true
    @State private var outputBaseName = "stacked"
    @State private var groupsPanelsAutomatically = false
    @State private var panelAnalysis: SkyPanelAnalysis?
    @State private var overlapWasEdited = false
    @State private var showsAdvancedOptions = false
    @State private var showsCalibration = false
    @State private var isChoosingFile = false
    @State private var isPreparingCalibration = false
    @State private var preparationMessage = ""
    @State private var preparationNotice: String?
    @State private var pendingWarnings: [String]?
    @State private var pendingFlatReviews: [FlatQualityReview] = []
    @State private var pendingJobs: [ImageStackJob]?
    @State private var preparationTask: Task<Void, Never>?

    init(urls: [URL], onComplete: @escaping (ImageStackBatchResult) -> Void) {
        precondition(!urls.isEmpty)
        self.urls = urls
        self.onComplete = onComplete
        _selectedURLs = State(initialValue: Set(urls))
    }

    var body: some View {
        VStack(spacing: 0) {
            if coordinator.isRunning || isPreparingCalibration {
                progressView
            } else {
                configurationView
            }
        }
        .frame(width: 620, height: 640)
        .interactiveDismissDisabled(coordinator.isRunning || isPreparingCalibration)
        .sheet(isPresented: warningSheetBinding) {
            CalibrationWarningsSheet(
                warnings: pendingWarnings ?? [],
                reviews: pendingFlatReviews,
                primaryTitle: "Continue Stacking",
                onPrimary: {
                    let jobs = pendingJobs
                    pendingWarnings = nil
                    pendingFlatReviews = []
                    pendingJobs = nil
                    if let jobs {
                        startBatch(jobs)
                    }
                },
                onCancel: {
                    pendingWarnings = nil
                    pendingFlatReviews = []
                    pendingJobs = nil
                    preparationNotice = "Stacking was cancelled before any light "
                        + "frames were processed."
                })
        }
        .sheet(isPresented: $showsLibraryReview) {
            CalibrationLibraryReviewView(model: libraryModel, library: calibrationLibrary, lights: libraryLights, provided: providedCalibration)
        }
        .onChange(of: libraryLights) { _, _ in analyzeCalibration() }
        .onChange(of: calibrationLibrary) { _, _ in analyzeCalibration() }
        .onChange(of: providedCalibration) { _, _ in analyzeCalibration() }
        .onChange(of: libraryModel.preferences.reviewInputs) { _, _ in analyzeCalibration() }
        .onChange(of: calibrationSource) { _, _ in analyzeCalibration() }
        .onDisappear {
            libraryModel.task?.cancel()
            preparationTask?.cancel()
        }
    }

    private func panelSelection(_ analysis: SkyPanelAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Select panels to include").font(.headline)
            ForEach(Array(analysis.fields.enumerated()), id: \.element.id) { index, field in
                Text("Sky field \(index + 1)").font(.subheadline.weight(.semibold))
                ForEach(field.panels) { panel in
                    HStack(alignment: .top, spacing: 8) {
                        Toggle("Include \(panel.title)", isOn: Binding(
                            get: { panel.frames.allSatisfy { selectedURLs.contains($0.url) } },
                            set: { checked in
                                for frame in panel.frames {
                                    if checked { selectedURLs.insert(frame.url) }
                                    else { selectedURLs.remove(frame.url) }
                                }
                            }))
                            .toggleStyle(.checkbox)
                            .labelsHidden()
                            .accessibilityLabel("Include \(panel.title)")
                        DisclosureGroup {
                            ForEach(panel.frames, id: \.url) { frame in
                                Toggle(frame.url.lastPathComponent, isOn: selectedBinding(for: frame.url))
                                    .toggleStyle(.checkbox)
                                    .help(frame.url.path)
                            }
                        } label: {
                            Text("\(panel.title) · \(panel.frames.count) exposures · \(panel.position)")
                                .font(.caption)
                        }
                    }
                }
            }
            if !analysis.failures.isEmpty {
                DisclosureGroup("Excluded (\(analysis.failures.count))") {
                    ForEach(analysis.failures) { failure in
                        Text("\(failure.url.lastPathComponent): \(failure.reason)")
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            }
        }
    }

    private func analyzePanels() {
        let inputs = selectedFrames
        let catalog = CatalogAccess.resolve()
        isPreparingCalibration = true
        preparationMessage = "Solving selected lights…"
        preparationNotice = nil
        preparationTask = Task { @MainActor in
            let worker = Task.detached(priority: .userInitiated) {
                try SkyPanelService.analyze(inputs, catalog: catalog) { message in
                    Task { @MainActor in preparationMessage = message }
                }
            }
            do {
                let analysis = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                // Commit analysis and selection together; cancellation leaves the prior analysis intact.
                panelAnalysis = analysis
                selectedURLs = Set(analysis.fields.first?.panels.flatMap(\.frames).map(\.url) ?? [])
                preparationNotice = "Found \(analysis.fields.count) sky fields; \(analysis.failures.count) excluded. Review the selected panels before stacking."
            } catch is CancellationError { preparationNotice = "Panel analysis was cancelled." }
            catch { preparationNotice = error.localizedDescription }
            isPreparingCalibration = false
        }
    }

    private var warningSheetBinding: Binding<Bool> {
        Binding(
            get: { pendingWarnings != nil },
            set: { presented in
                if !presented, pendingWarnings != nil {
                    pendingWarnings = nil
                    pendingFlatReviews = []
                    pendingJobs = nil
                }
            })
    }

    private var configurationView: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Stack Images")
                        .font(.title2.weight(.semibold))
                    Text("Align and combine linear FITS or XISF frames.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)

            Divider()

            Form {
                Section("Stacking mode") {
                    Picker("Mode", selection: $options.canvasMode) {
                        ForEach(StackCanvasMode.allCases) { mode in Text(mode.title).tag(mode) }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: options.canvasMode) { _, mode in
                        if !overlapWasEdited { options.minimumOverlap = mode == .expanded ? 0.05 : 0.60 }
                    }
                    Text(options.canvasMode == .expanded
                        ? "Register the selected lights onto one expanding canvas per output, including images from different folders. Overlapping panels can connect through other panels. Sky-panel analysis is optional."
                        : "Align and combine the selected lights within a fixed reference frame. Choose Expanded mosaic to retain the edges of overlapping panels.")
                        .font(.caption).foregroundStyle(.secondary)
                    if options.canvasMode == .expanded {
                        TextField("Maximum canvas (million samples)", value: $options.maximumCanvasMegasamples, format: .number)
                        Text("Samples are pixels × channels. Peak working memory is approximately 40 bytes per sample (256 million ≈ 10 GB). Native registration decides which lights join. Shared fixed alignment and Bayer drizzle are unavailable.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Frames") {
                    HStack {
                        Text("\(selectedURLs.count) of \(urls.count) selected")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("All") {
                            selectedURLs = Set(groupsPanelsAutomatically ? (panelAnalysis?.solved.map(\.url) ?? urls) : urls)
                        }
                        Button("None") {
                            selectedURLs.removeAll()
                        }
                    }

                    if !groupsPanelsAutomatically || panelAnalysis == nil {
                        List(urls, id: \.self) { url in
                            Toggle(isOn: selectedBinding(for: url)) {
                                Text(url.lastPathComponent).lineLimit(1)
                            }
                        }
                        .frame(height: 150)
                    }

                    DisclosureGroup("Optional sky-panel analysis") {
                        Toggle("Group lights by solved sky position", isOn: $groupsPanelsAutomatically)
                        Text("Plate-solve selected lights to review repeated pointings and split disconnected fields into separate outputs. Expanded mosaic works without this step. Installed solving catalogs are required for this analysis.")
                            .font(.caption).foregroundStyle(.secondary)
                        if groupsPanelsAutomatically {
                            Button("Solve and group selected lights", action: analyzePanels)
                                .disabled(selectedFrames.count < 2)
                            if let analysis = panelAnalysis {
                                panelSelection(analysis)
                            }
                        }
                    }

                    if hasMultipleDetectedFilters {
                        Toggle("Split by filename filter", isOn: $splitByFilenameFilter)
                        Text("Recognizes L, R, G, B, Ha, OIII, S/SII, and H-beta; other filter names stay unchanged.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if stackGroups.count > 1 {
                            TextField("Output base name", text: $outputBaseName)
                        }
                    }

                    if !hasMultipleDetectedFilters && stackGroups.count > 1 {
                        TextField("Output base name", text: $outputBaseName)
                    }
                    ForEach(stackGroups) { group in
                        Picker(
                            stackGroups.count == 1 ? "Channel reference" : "\(group.title) channel reference",
                            selection: referenceBinding(for: group)
                        ) {
                            ForEach(group.inputs, id: \.self) { url in
                                Text(url.lastPathComponent).tag(url)
                            }
                        }
                        .disabled(group.inputs.isEmpty || automaticReferenceGroups.contains(group.id))
                        Toggle("Choose \(group.title) channel reference automatically", isOn: Binding(
                            get: { automaticReferenceGroups.contains(group.id) },
                            set: { enabled in
                                if enabled { automaticReferenceGroups.insert(group.id) }
                                else { automaticReferenceGroups.remove(group.id) }
                            }))
                    }

                    Text("Automatic selection scores the selected lights when stacking starts. With a shared alignment image, it tries up to five ranked lights until one aligns.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(groupSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    LabeledContent("Shared alignment image") {
                        HStack {
                            Button(referenceImage?.lastPathComponent ?? "Choose…") {
                                isChoosingFile = true
                                Task { @MainActor in
                                    if let selected = await StackFilePanels.chooseCalibration(
                                        directory: urls.first?.deletingLastPathComponent(),
                                        message: "Choose a FITS or XISF image to set the common alignment grid.") {
                                        referenceImage = selected
                                    }
                                    isChoosingFile = false
                                }
                            }
                            .lineLimit(1)
                            .disabled(options.canvasMode == .expanded)
                            if referenceImage != nil {
                                Button("Clear") { referenceImage = nil }
                            }
                        }
                    }
                    Text(referenceImage == nil
                        ? (options.canvasMode == .expanded
                            ? "Each channel reference anchors its expanding canvas and normalization."
                            : "Each channel reference sets its stack's grid and normalization. Choose a shared alignment image to put every filter on the same grid.")
                        : "The alignment image supplies bounds and coordinates; each channel light supplies its own brightness and noise scale. The alignment image contributes no pixels unless it is also selected as a light. Use matching mono or color data at the same image scale.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Stack") {
                    StackProcessingOptionsView(options: $options)
                    Picker("Normalization", selection: $options.normalization) {
                        ForEach(StackNormalizationMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    if options.usesLocalTiles {
                        Picker("Tile size", selection: $options.localTileSize) {
                            ForEach([64, 128, 256, 512], id: \.self) { size in
                                Text("\(size) px").tag(size)
                            }
                        }
                    }

                    Picker("Sample rejection", selection: $options.rejection) {
                        ForEach(StackRejectionMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    if options.rejection == .deltaSigma {
                        LabeledContent("Sigma limits") {
                            HStack {
                                TextField("Low", value: $options.sigmaLow, format: .number)
                                    .frame(width: 70)
                                Text("low")
                                    .foregroundStyle(.secondary)
                                TextField("High", value: $options.sigmaHigh, format: .number)
                                    .frame(width: 70)
                                Text("high")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Stepper(
                            "Warmup frames: \(options.rejectionWarmup)",
                            value: $options.rejectionWarmup,
                            in: 2...100
                        )
                    }

                    Toggle("Remove transients after stacking", isOn: $options.removesTransients)
                    Text("Runs three passes over accepted frames to reject satellite "
                        + "trails that live rejection kept in the first frames.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                DisclosureGroup("Calibration", isExpanded: $showsCalibration) {
                    Picker("Source", selection: $calibrationSource) {
                        ForEach(StackCalibrationSource.allCases) { source in
                            Text(source.title).tag(source)
                        }
                    }
                    if calibrationSource == .masters {
                        calibrationRow("Bias", selection: $calibration.bias)
                        calibrationRow("Dark", selection: $calibration.dark)
                        calibrationRow("Flat", selection: $calibration.flat)
                        Toggle(
                            "Override dark exposure",
                            isOn: $calibration.overridesDarkExposure
                        )
                        .disabled(calibration.dark == nil)
                        if calibration.overridesDarkExposure {
                            TextField(
                                "Dark exposure (seconds)",
                                value: $calibration.darkExposureSeconds,
                                format: .number
                            )
                        }
                    } else {
                        Text("Provide calibration files or a library folder. Frames are graded, grouped and matched automatically; masters are built when stacking. Mosaics can use several calibration sessions in one output.")
                            .font(.caption).foregroundStyle(.secondary)
                        LabeledContent("Library") {
                            HStack {
                                Text(calibrationLibrary?.path
                                    ?? "Calibration library folder")
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .foregroundStyle(
                                        calibrationLibrary == nil
                                            ? .secondary : .primary)
                                Button("Choose…") { chooseCalibrationLibrary() }
                            }
                        }
                        LabeledContent("Files") {
                            HStack {
                                Text("\(providedCalibration.count) provided calibration frames")
                                Button("Add…") { chooseCalibrationFiles() }
                                if !providedCalibration.isEmpty { Button("Clear") { providedCalibration = [] } }
                            }
                        }
                        Picker("Flats", selection: $libraryModel.preferences.flatAssociation) {
                            ForEach(LibraryAssociation.allCases) { Text($0.title).tag($0) }
                        }
                        Picker("Darks", selection: $libraryModel.preferences.darkAssociation) {
                            ForEach(LibraryAssociation.allCases) { Text($0.title).tag($0) }
                        }
                        HStack {
                            Button(libraryModel.busy ? "Analyzing…" : "Analyze Calibration") {
                                libraryModel.analyze(library: calibrationLibrary, lights: libraryLights, provided: providedCalibration)
                            }.disabled((calibrationLibrary == nil && providedCalibration.isEmpty) || libraryModel.busy)
                            Button("Review Grades and Matches…") { showsLibraryReview = true }
                                .disabled(libraryModel.review == nil)
                        }
                        if libraryModel.busy { ProgressView("Measuring and matching…") }
                        if let review = libraryModel.review {
                            Text("\(review.frames.count) calibration frames · \(review.sessionCount) sessions · \(review.missing.filter { $0 }.count) incomplete lights")
                                .font(.caption)
                        }
                        if let error = libraryModel.error { Text(error).foregroundStyle(.red) }
                        Picker("Incomplete lights", selection: $libraryModel.preferences.incomplete) {
                            Text("Stop and review").tag("stop")
                            Text("Exclude from stack").tag("exclude")
                            Text("Keep with available calibration").tag("keep")
                        }
                        CalibrationLibrarySettingsView(model: libraryModel).disabled(libraryModel.busy)

                    }
                }

                DisclosureGroup("Registration Limits", isExpanded: $showsAdvancedOptions) {
                    TextField(
                        "Maximum RMS (pixels)",
                        value: $options.maximumRegistrationRMS,
                        format: .number
                    )
                    TextField(
                        "Drift floor (pixels)",
                        value: $options.maximumDriftPixels,
                        format: .number
                    )
                    TextField(
                        "Maximum drift fraction",
                        value: $options.maximumDriftFraction,
                        format: .number
                    )
                    TextField(
                        "Minimum overlap",
                        value: Binding(get: { options.minimumOverlap }, set: { options.minimumOverlap = $0; overlapWasEdited = true }),
                        format: .number
                    )
                }

                if let message = setupValidationMessage {
                    Text(message)
                        .foregroundStyle(.red)
                        .font(.callout)
                } else if let message = coordinator.errorMessage {
                    Text(message)
                        .foregroundStyle(.red)
                        .font(.callout)
                } else if let message = preparationNotice {
                    Text(message)
                        .foregroundStyle(.secondary)
                        .font(.callout)
                } else if let message = coordinator.cancellationMessage {
                    Text(message)
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Choose Output and Stack…") {
                    chooseOutputAndStart()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(setupValidationMessage != nil || isChoosingFile)
            }
            .padding(16)
        }
    }

    private var progressView: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 42))
                .foregroundStyle(.tint)
            Text(progressTitle)
                .font(.title2.weight(.semibold))

            if isPreparingCalibration {
                ProgressView()
                    .controlSize(.large)
                Text(preparationMessage)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .frame(maxWidth: 440)
                    .foregroundStyle(.secondary)
            } else if let progress = coordinator.progress {
                if let fraction = progress.fractionCompleted {
                    ProgressView(value: fraction)
                        .frame(width: 360)
                } else {
                    ProgressView()
                        .controlSize(.large)
                }
                Text(progress.message)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 440)
                Text(
                    "\(progress.completedFrames) of \(progress.totalFrames) frames · "
                    + "\(progress.acceptedFrames) accepted · \(progress.rejectedFrames) rejected"
                )
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button(coordinator.isCancelling ? "Stopping…" : "Cancel") {
                if isPreparingCalibration {
                    preparationTask?.cancel()
                } else {
                    coordinator.cancel()
                }
            }
            .disabled(coordinator.isCancelling)
            .keyboardShortcut(.cancelAction)
            .padding(.bottom, 20)
        }
        .padding(28)
    }

    private var progressTitle: String {
        if isPreparingCalibration { return "Preparing Stack" }
        return coordinator.isCancelling ? "Stopping…" : "Stacking Images"
    }

    private var selectedFrames: [URL] {
        urls.filter(selectedURLs.contains)
    }

    private var hasMultipleDetectedFilters: Bool {
        ImageStackGrouping.hasMultipleDetectedFilters(in: urls)
    }

    private var stackGroups: [ImageStackGroup] {
        if groupsPanelsAutomatically {
            return panelAnalysis?.selectedGroups(selectedFrames, splitByFilter: splitByFilenameFilter) ?? []
        }
        return ImageStackGrouping.groups(
            for: selectedFrames,
            splitByFilter: splitsSelectedFramesByFilter
        )
    }

    private var splitsSelectedFramesByFilter: Bool {
        splitByFilenameFilter
            && ImageStackGrouping.hasMultipleDetectedFilters(in: selectedFrames)
    }

    private var groupSummary: String {
        stackGroups.map { "\($0.title): \($0.inputs.count)" }.joined(separator: " · ")
    }

    private var setupValidationMessage: String? {
        if groupsPanelsAutomatically {
            guard panelAnalysis != nil else { return "Solve and group selected lights before stacking." }
            guard !stackGroups.isEmpty else { return "Choose lights from a solved panel." }
        }
        if options.canvasMode == .expanded, referenceImage != nil {
            return "Clear the shared alignment image before using an expanded canvas."
        }
        guard selectedURLs.count >= 2 else { return "Choose at least two frames." }
        if let group = stackGroups.first(where: { $0.inputs.count < 2 }) {
            return "\(group.title) needs at least two selected frames."
        }
        if stackGroups.count > 1 {
            let baseName = outputBaseName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !baseName.isEmpty, !baseName.contains("/"), !baseName.contains(":") else {
                return "Enter a valid output base name."
            }
        }
        if calibrationSource == .automatic {
            if calibrationLibrary == nil && providedCalibration.isEmpty { return "Choose calibration files or a library folder." }
            if libraryModel.busy { return "Wait for calibration analysis to finish." }
            guard let review = libraryModel.review, !libraryModel.stale else { return "Analyze and review calibration before stacking." }
            if libraryModel.preferences.incomplete == "stop", review.missing.contains(true) { return "Some lights have incomplete calibration. Review their matches or change Incomplete lights." }
            if libraryModel.preferences.incomplete == "exclude" {
                for group in stackGroups {
                    let count = group.inputs.filter { url in
                        guard let index = libraryLights.firstIndex(of: url) else { return false }
                        return !review.missing[index]
                    }.count
                    if count < 2 { return "\(group.title) needs at least two lights with complete calibration." }
                }
            }
            return options.validationMessage
        }
        return options.validationMessage ?? calibration.validationMessage(for: selectedFrames)
    }

    private func selectedBinding(for url: URL) -> Binding<Bool> {
        Binding(
            get: { selectedURLs.contains(url) },
            set: { selected in
                if selected {
                    selectedURLs.insert(url)
                } else {
                    selectedURLs.remove(url)
                }
            }
        )
    }

    private func referenceBinding(for group: ImageStackGroup) -> Binding<URL> {
        Binding(
            get: {
                if let reference = referenceURLs[group.id], group.inputs.contains(reference) {
                    return reference
                }
                return group.inputs.first ?? urls[0]
            },
            set: { referenceURLs[group.id] = $0 }
        )
    }

    private func orderedInputs(for group: ImageStackGroup) -> [URL] {
        let reference = referenceBinding(for: group).wrappedValue
        return [reference] + group.inputs.filter { $0 != reference }
    }

    @ViewBuilder
    private func calibrationRow(_ title: String, selection: Binding<URL?>) -> some View {
        LabeledContent(title) {
            HStack {
                Button(selection.wrappedValue?.lastPathComponent ?? "Choose…") {
                    chooseCalibration(selection: selection)
                }
                .lineLimit(1)
                if selection.wrappedValue != nil {
                    Button {
                        selection.wrappedValue = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove \(title.lowercased()) master")
                }
            }
        }
    }

    private func chooseCalibration(selection: Binding<URL?>) {
        isChoosingFile = true
        Task { @MainActor in
            selection.wrappedValue = await StackFilePanels.chooseCalibration(
                directory: urls.first?.deletingLastPathComponent()
            )
            isChoosingFile = false
        }
    }

    private func analyzeCalibration() {
        guard calibrationSource == .automatic, !libraryLights.isEmpty,
              calibrationLibrary != nil || !providedCalibration.isEmpty else { libraryModel.invalidate(); return }
        libraryModel.analyze(library: calibrationLibrary, lights: libraryLights, provided: providedCalibration, debounce: true)
    }

    private func chooseCalibrationFiles() {
        isChoosingFile = true
        Task { @MainActor in
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = true
            panel.message = "Choose raw calibration frames or masters. FITS/XISF headers identify bias, dark, dark-flat and flat frames."
            let chosen: [URL] = await withCheckedContinuation { continuation in
                panel.begin { response in continuation.resume(returning: response == .OK ? panel.urls : []) }
            }
            for url in chosen where !providedCalibration.contains(url) { providedCalibration.append(url) }
            isChoosingFile = false
        }
    }

    private func chooseCalibrationLibrary() {
        isChoosingFile = true
        Task { @MainActor in
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            panel.directoryURL = calibrationLibrary
                ?? urls.first?.deletingLastPathComponent()
            panel.message = "Choose a library containing raw bias, dark, "
                + "dark-flat, and flat frames."
            panel.prompt = "Choose"
            let url: URL? = await withCheckedContinuation { continuation in
                panel.begin { response in
                    continuation.resume(returning: response == .OK ? panel.url : nil)
                }
            }
            if let url {
                calibrationLibrary = url
            }
            isChoosingFile = false
        }
    }

    private func chooseOutputAndStart() {
        guard setupValidationMessage == nil else { return }
        isChoosingFile = true
        Task { @MainActor in
            if groupsPanelsAutomatically, let analysis = panelAnalysis {
                let inputs = selectedFrames
                let unchanged = await Task.detached { analysis.sourcesUnchanged(inputs) }.value
                guard unchanged else {
                    isChoosingFile = false
                    preparationNotice = "A selected source changed. Solve and group it again."
                    return
                }
            }
            let groups = stackGroups
            let outputSelection = await StackFilePanels.chooseOutputs(
                for: groups,
                splitByFilter: groups.count > 1,
                baseName: outputBaseName.trimmingCharacters(in: .whitespacesAndNewlines),
                directory: urls.first?.deletingLastPathComponent()
            )
            isChoosingFile = false
            guard let outputSelection else { return }
            preparationNotice = nil

            guard calibrationSource == .automatic
            else {
                startBatch(makeJobs(
                    groups: groups,
                    outputSelection: outputSelection,
                    calibrationsByGroup: [:]))
                return
            }

            isPreparingCalibration = true
            preparationMessage = "Inspecting target light headers…"
            preparationTask = Task { @MainActor in
                do {
                    guard let reviewed = libraryModel.review, !libraryModel.stale else {
                        throw ImageStackError.invalidRequest("Analyze calibration again before stacking.")
                    }
                    let lights = libraryLights
                    let preferences = libraryModel.preferences
                    preparationMessage = "Building reviewed calibration masters…"
                    let execution = LibraryRequest(operation: "execute", library: calibrationLibrary, lights: lights,
                        provided: providedCalibration, preferences: preferences, reviewKey: reviewed.reviewKey)
                    let prepared = try await CalibrationLibraryService.perform(execution)
                    let plan = LibraryPreparedPlan(review: prepared, originalPaths: lights.map(\.path), accessURLs: execution.accessURLs)
                    let jobs = try makeLibraryJobs(groups: groups, outputSelection: outputSelection, plan: plan,
                        excludeIncomplete: preferences.incomplete == "exclude")
                    isPreparingCalibration = false
                    let newWarnings = prepared.warnings.filter { !reviewed.warnings.contains($0) }
                    if newWarnings.isEmpty {
                        startBatch(jobs)
                    } else {
                        pendingJobs = jobs
                        pendingFlatReviews = []
                        pendingWarnings = newWarnings
                    }
                } catch is CancellationError {
                    isPreparingCalibration = false
                    preparationNotice = "Calibration preparation was cancelled."
                } catch {
                    isPreparingCalibration = false
                    preparationNotice = error.localizedDescription
                }
            }
        }
    }

    private var libraryLights: [URL] { stackGroups.flatMap { orderedInputs(for: $0) } }

    private func makeLibraryJobs(groups: [ImageStackGroup], outputSelection: StackFilePanels.OutputSelection,
        plan: LibraryPreparedPlan, excludeIncomplete: Bool) throws -> [ImageStackJob] {
        try zip(groups, outputSelection.outputs).map { group, output in
            let inputs = try plan.preparedInputs(orderedInputs(for: group), excludeIncomplete: excludeIncomplete)
            guard inputs.count >= 2 else { throw ImageStackError.invalidRequest("\(group.title) needs two usable lights after calibration exclusions.") }
            return ImageStackJob(group: group, request: ImageStackRequest(inputs: inputs, output: output,
                outputAccessURL: outputSelection.accessURL, options: stackOptions, calibration: ImageStackCalibration(),
                referenceImage: referenceImage, choosesReferenceAutomatically: automaticReferenceGroups.contains(group.id),
                additionalProtectedSources: urls, libraryPlan: plan))
        }
    }

    private var stackOptions: ImageStackOptions {
        var snapshot = options
        snapshot.useGPU = StackingPreferences.usesGPU()
        snapshot.gpuBudgetMiB = StackingPreferences.gpuBudgetMiB()
        return snapshot
    }

    private func makeJobs(
        groups: [ImageStackGroup],
        outputSelection: StackFilePanels.OutputSelection,
        calibrationsByGroup: [String: ImageStackCalibration]
    ) -> [ImageStackJob] {
        zip(groups, outputSelection.outputs).map { group, output in
            ImageStackJob(
                group: group,
                request: ImageStackRequest(
                    inputs: orderedInputs(for: group),
                    output: output,
                    outputAccessURL: outputSelection.accessURL,
                    options: stackOptions,
                    calibration: calibrationsByGroup[group.id]
                        ?? (calibrationSource == .automatic
                            ? ImageStackCalibration()
                            : calibration),
                    referenceImage: referenceImage,
                    choosesReferenceAutomatically: automaticReferenceGroups.contains(group.id),
                    additionalProtectedSources: urls
                )
            )
        }
    }

    private func startBatch(_ jobs: [ImageStackJob]) {
        if groupsPanelsAutomatically,
            panelAnalysis?.sourcesUnchanged(selectedFrames) != true {
            preparationNotice = "A selected source changed. Solve and group it again."
            return
        }
        coordinator.start(
            request: ImageStackBatchRequest(jobs: jobs),
            onSuccess: { result in
                dismiss()
                onComplete(result)
            }
        )
    }


}

@MainActor
private enum StackFilePanels {
    struct OutputSelection {
        let outputs: [URL]
        let accessURL: URL
    }

    static func chooseOutputs(
        for groups: [ImageStackGroup],
        splitByFilter: Bool,
        baseName: String,
        directory: URL?
    ) async -> OutputSelection? {
        if splitByFilter {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            panel.canCreateDirectories = true
            panel.directoryURL = directory
            panel.message = "Choose a folder for the filter stacks."
            panel.prompt = "Choose"
            let outputDirectory: URL? = await withCheckedContinuation { continuation in
                panel.begin { response in
                    continuation.resume(returning: response == .OK ? panel.url : nil)
                }
            }
            guard let outputDirectory else { return nil }
            let accessedDirectory = outputDirectory.startAccessingSecurityScopedResource()
            defer {
                if accessedDirectory {
                    outputDirectory.stopAccessingSecurityScopedResource()
                }
            }
            let outputs = groups.map { group in
                outputDirectory.appendingPathComponent(
                    "\(baseName)-\(group.filenameSuffix).fits"
                )
            }
            let existing = outputs.filter { FileManager.default.fileExists(atPath: $0.path) }
            guard existing.isEmpty || confirmReplacing(existing) else { return nil }
            return OutputSelection(outputs: outputs, accessURL: outputDirectory)
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.fits]
        panel.canCreateDirectories = true
        panel.directoryURL = directory
        panel.nameFieldStringValue = "stacked.fits"
        panel.message = "Save the unstretched 32-bit floating-point FITS stack."
        panel.prompt = "Stack"
        let baseURL: URL? = await withCheckedContinuation { continuation in
            panel.begin { response in
                continuation.resume(returning: response == .OK ? panel.url : nil)
            }
        }
        guard let baseURL else { return nil }

        return OutputSelection(outputs: [baseURL], accessURL: baseURL)
    }

    private static func confirmReplacing(_ urls: [URL]) -> Bool {
        let alert = NSAlert()
        alert.messageText = urls.count == 1
            ? "Replace Existing Stack?"
            : "Replace Existing Stacks?"
        alert.informativeText = urls.map(\.lastPathComponent).joined(separator: "\n")
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func chooseCalibration(directory: URL?, message: String = "Choose an integrated calibration master.") async -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.fits, .xisf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.directoryURL = directory
        panel.message = message
        return await withCheckedContinuation { continuation in
            panel.begin { response in
                continuation.resume(returning: response == .OK ? panel.url : nil)
            }
        }
    }
}
