import CryptoKit
import Foundation

/// Digest presentation shared by every subsystem that names files or
/// directories after SHA-256 content.
enum SeizaDigest {
    static func hex(_ digest: SHA256Digest, byteCount: Int? = nil) -> String {
        let bytes = byteCount.map { Array(digest.prefix($0)) } ?? Array(digest)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// The on-disk identity of a path: case-folded normalized path, hashed,
    /// truncated. Both the calibration-master cache and the live-stack
    /// session roots derive their directory names from this.
    static func pathIdentity(_ path: String, byteCount: Int) -> String {
        let normalized = LiveStackPath.normalize(path).uppercased()
        return hex(SHA256.hash(data: Data(normalized.utf8)), byteCount: byteCount)
    }
}

/// Path identity helpers shared by calibration, live stacking, and session
/// persistence. Comparison is case-insensitive to match the default APFS
/// volume and the recorded-path contract of the native ledger.
enum LiveStackPath {
    static func normalize(_ path: String) -> String {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        var normalized = url.path
        while normalized.count > 1 && normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }

    static func equals(_ a: String, _ b: String) -> Bool {
        normalize(a).caseInsensitiveCompare(normalize(b)) == .orderedSame
    }

    static func isWithinDirectory(_ path: String, directory: String) -> Bool {
        let normalizedPath = normalize(path)
        let normalizedDirectory = normalize(directory)
        if normalizedPath.caseInsensitiveCompare(normalizedDirectory) == .orderedSame {
            return true
        }
        let prefix = normalizedDirectory.hasSuffix("/")
            ? normalizedDirectory
            : normalizedDirectory + "/"
        return normalizedPath.lowercased().hasPrefix(prefix.lowercased())
    }
}

enum CalibrationFrameRole {
    static let bias = "bias"
    static let dark = "dark"
    static let darkFlat = "dark-flat"
    static let flat = "flat"
    static let light = "light"
    static let unknown = "unknown"
}

/// The per-frame metadata signature reported by `seiza_probe_frame_json`.
/// Every field is optional; "unknown" is a first-class state that drives the
/// native matchers' asymmetric acceptance rules.
struct CalibrationFrameSignature: Codable, Equatable, Sendable {
    var camera: String? = nil
    var telescope: String? = nil
    var width: Int64? = nil
    var height: Int64? = nil
    var channels: Int64? = nil
    var binningX: Int64? = nil
    var binningY: Int64? = nil
    var gain: Int64? = nil
    var offset: Int64? = nil
    var readoutMode: Int64? = nil
    var bayerPattern: String? = nil
    var filter: String? = nil
    var focalLengthMm: Double? = nil
    var rotationDeg: Double? = nil
    var exposureSeconds: Double? = nil
    var cameraTempC: Double? = nil
    var capturedAtUnix: Int64? = nil
}

struct CalibrationFrameState: Codable, Equatable, Sendable {
    var biasSubtracted = false
    var darkSubtracted = false
    var flatNormalized = false

    var isRaw: Bool { !biasSubtracted && !darkSubtracted && !flatNormalized }
}

/// One header probe of a FITS or XISF file. Role classification, master
/// detection, and calibration state are native; nothing here re-reads
/// header keywords.
struct CalibrationFrameProbe: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var path: String
    var format: String? = nil
    var role: String
    var rawImageType: String? = nil
    var isMaster = false
    var signature = CalibrationFrameSignature()
    var calibrationState = CalibrationFrameState()

    var isRawCandidate: Bool { !isMaster && calibrationState.isRaw }
}

enum CalibrationLightEligibility {
    /// Why a probed frame cannot serve as a calibration target light, or nil
    /// when it can.
    static func ineligibilityReason(_ probe: CalibrationFrameProbe) -> String? {
        if probe.isMaster {
            return "the frame is already a master"
        }
        if probe.role != CalibrationFrameRole.light {
            return "the frame is not a light frame"
        }
        if !probe.calibrationState.isRaw {
            return "the light frame is already preprocessed"
        }
        return nil
    }
}

/// Splits a group's probed lights into calibration-matching targets and
/// set-aside frames. A frame that cannot serve as a target — a master, a
/// non-light, a preprocessed light — is a warning, not a reason to refuse
/// the whole batch: the native stacker's per-frame admission remains
/// authoritative when the frame is pushed.
enum CalibrationTargetSelection {
    struct Partition {
        var eligible: [CalibrationFrameProbe] = []
        var warnings: [String] = []
    }

    static func partition(_ probes: [CalibrationFrameProbe]) -> Partition {
        var partition = Partition()
        for probe in probes {
            if let reason = CalibrationLightEligibility.ineligibilityReason(probe) {
                let name = URL(fileURLWithPath: probe.path).lastPathComponent
                partition.warnings.append(
                    "Set aside \(name) for calibration matching; \(reason).")
            } else {
                partition.eligible.append(probe)
            }
        }
        return partition
    }
}

enum CalibrationTargetMetadata {
    /// Fills a target light's missing FILTER header from a recognized
    /// filename filter, using the conventional header spelling. Calibration
    /// candidates are never enriched: the native builder rereads their files
    /// and must see the same metadata the planner used.
    static func enrich(_ probe: CalibrationFrameProbe) -> CalibrationFrameProbe {
        let filter = probe.signature.filter?.trimmingCharacters(in: .whitespaces)
        guard filter == nil || filter?.isEmpty == true else { return probe }
        guard let detected = ImageFilenameFilter.detect(
            in: URL(fileURLWithPath: probe.path))
        else { return probe }
        var enriched = probe
        enriched.signature.filter = detected.filenameSuffix
        return enriched
    }
}

// MARK: - Plan contract

struct CalibrationPlanTolerances: Codable, Equatable, Sendable {
    var exposureSeconds: Double? = nil
    var exposureFraction: Double? = nil
    var darkTemperatureC: Double? = nil
    var masterTemperatureC: Double? = nil
    var rotationDeg: Double? = nil
    var focalLengthMm: Double? = nil
    var flatSessionSeconds: UInt64? = nil
}

struct CalibrationPlanRecord: Codable, Equatable, Sendable {
    var path: String
    var role: String
    var signature: CalibrationFrameSignature

    init(probe: CalibrationFrameProbe) {
        path = probe.path
        role = probe.role
        signature = probe.signature
    }
}

struct CalibrationPlanDependencies: Codable, Equatable, Sendable {
    var biasAvailable = false
}

struct CalibrationPlanRequest: Encodable, Sendable {
    var kind: String
    var reference: CalibrationPlanRecord
    var references: [CalibrationPlanRecord]
    var candidates: [CalibrationPlanRecord]
    var minimum: Int
    var tolerances: CalibrationPlanTolerances
    var dependencies: CalibrationPlanDependencies
}

struct CalibrationPlanExclusion: Codable, Equatable, Sendable {
    var path: String
    var reason: String
}

struct CalibrationPlanResult: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var kind: String
    var minimum: Int
    var ready: Bool
    var matchedPaths: [String]
    var selectedPaths: [String]
    var excluded: [CalibrationPlanExclusion]

    static let outsideCoherentSetReason = "outside-coherent-set"

    static func empty(kind: String, minimum: Int) -> CalibrationPlanResult {
        CalibrationPlanResult(
            schemaVersion: 1, kind: kind, minimum: minimum, ready: false,
            matchedPaths: [], selectedPaths: [], excluded: [])
    }
}

// MARK: - Master build contract

struct CalibrationMasterRejection: Codable, Equatable, Sendable {
    var lowSigma = 3.0
    var highSigma = 3.0
}

struct CalibrationDefectSuppression: Codable, Equatable, Sendable {
    var lowSigma = 16.0
    var highSigma = 16.0
}

struct CalibrationMasterBuildRequest: Encodable, Sendable {
    var kind: String
    var inputs: [String]
    var output: String
    var bias: String? = nil
    var dark: String? = nil
    var darkExposureSeconds: Double? = nil
    var exposureSeconds: Double? = nil
    var rejection = CalibrationMasterRejection()
    var defectSuppression: CalibrationDefectSuppression? = nil
}

struct CalibrationMasterBuildInput: Codable, Equatable, Sendable {
    var path: String
    var acceptedSamples: UInt64 = 0
    var rejectedSamples: UInt64 = 0
}

struct CalibrationMasterSkippedInput: Codable, Equatable, Sendable {
    var path: String
    var reason: String
}

struct CalibrationMasterBuildResult: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var kind: String
    var output: String
    var width: Int
    var height: Int
    var channels: Int
    var requestedFrames: Int
    var inputFrames: Int
    var acceptedSamples: UInt64
    var rejectedSamples: UInt64
    var fallbackPixels: UInt64
    var defectPixelsReplaced: UInt64
    var biasSubtracted: Bool
    var darkSubtracted: Bool
    var normalized: Bool
    var outputExposureSeconds: Double?
    var rejection: CalibrationMasterRejection
    var inputs: [CalibrationMasterBuildInput]
    var skippedInputs: [CalibrationMasterSkippedInput]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        kind = try container.decode(String.self, forKey: .kind)
        output = try container.decode(String.self, forKey: .output)
        width = try container.decode(Int.self, forKey: .width)
        height = try container.decode(Int.self, forKey: .height)
        channels = try container.decode(Int.self, forKey: .channels)
        requestedFrames = try container.decodeIfPresent(Int.self, forKey: .requestedFrames) ?? 0
        inputFrames = try container.decode(Int.self, forKey: .inputFrames)
        acceptedSamples = try container.decode(UInt64.self, forKey: .acceptedSamples)
        rejectedSamples = try container.decode(UInt64.self, forKey: .rejectedSamples)
        fallbackPixels = try container.decodeIfPresent(UInt64.self, forKey: .fallbackPixels) ?? 0
        defectPixelsReplaced =
            try container.decodeIfPresent(UInt64.self, forKey: .defectPixelsReplaced) ?? 0
        biasSubtracted = try container.decode(Bool.self, forKey: .biasSubtracted)
        darkSubtracted = try container.decode(Bool.self, forKey: .darkSubtracted)
        normalized = try container.decode(Bool.self, forKey: .normalized)
        outputExposureSeconds =
            try container.decodeIfPresent(Double.self, forKey: .outputExposureSeconds)
        rejection = try container.decodeIfPresent(
            CalibrationMasterRejection.self, forKey: .rejection)
            ?? CalibrationMasterRejection()
        inputs = try container.decodeIfPresent(
            [CalibrationMasterBuildInput].self, forKey: .inputs) ?? []
        skippedInputs = try container.decodeIfPresent(
            [CalibrationMasterSkippedInput].self, forKey: .skippedInputs) ?? []
    }

    init(
        schemaVersion: Int,
        kind: String,
        output: String,
        width: Int,
        height: Int,
        channels: Int,
        requestedFrames: Int = 0,
        inputFrames: Int,
        acceptedSamples: UInt64 = 0,
        rejectedSamples: UInt64 = 0,
        fallbackPixels: UInt64 = 0,
        defectPixelsReplaced: UInt64 = 0,
        biasSubtracted: Bool,
        darkSubtracted: Bool,
        normalized: Bool,
        outputExposureSeconds: Double? = nil,
        rejection: CalibrationMasterRejection = CalibrationMasterRejection(),
        inputs: [CalibrationMasterBuildInput] = [],
        skippedInputs: [CalibrationMasterSkippedInput] = []
    ) {
        self.schemaVersion = schemaVersion
        self.kind = kind
        self.output = output
        self.width = width
        self.height = height
        self.channels = channels
        self.requestedFrames = requestedFrames
        self.inputFrames = inputFrames
        self.acceptedSamples = acceptedSamples
        self.rejectedSamples = rejectedSamples
        self.fallbackPixels = fallbackPixels
        self.defectPixelsReplaced = defectPixelsReplaced
        self.biasSubtracted = biasSubtracted
        self.darkSubtracted = darkSubtracted
        self.normalized = normalized
        self.outputExposureSeconds = outputExposureSeconds
        self.rejection = rejection
        self.inputs = inputs
        self.skippedInputs = skippedInputs
    }
}

// MARK: - Live-stack admission identities

/// The filter identity a live stack locks after its first light. A header
/// FILTER wins; a recognized filename filter is the fallback.
struct LiveStackFilterIdentity: Equatable, Sendable {
    enum Source: String, Sendable {
        case header
        case filename
        case unspecified
    }

    var key: String
    var displayName: String
    var source: Source

    static let unfiltered = LiveStackFilterIdentity(
        key: "unfiltered", displayName: "Unfiltered", source: .unspecified)

    static func fromProbe(_ probe: CalibrationFrameProbe) -> LiveStackFilterIdentity {
        let headerFilter = probe.signature.filter?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !headerFilter.isEmpty {
            return fromName(headerFilter, source: .header)
        }
        if let detected = ImageFilenameFilter.detect(in: URL(fileURLWithPath: probe.path)) {
            return LiveStackFilterIdentity(
                key: detected.id, displayName: detected.title, source: .filename)
        }
        return .unfiltered
    }

    static func fromStoredName(_ name: String?) -> LiveStackFilterIdentity {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return .unfiltered }
        return fromName(trimmed, source: .header)
    }

    static func fromName(_ name: String, source: Source) -> LiveStackFilterIdentity {
        let displayName = name
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        let alias = displayName.lowercased().filter { $0.isLetter || $0.isNumber }
        let known: ImageFilenameFilter? = switch alias {
        case "l", "lum", "luminance": .luminance
        case "r", "red": .red
        case "g", "green": .green
        case "b", "blue": .blue
        case "ha", "halpha", "hydrogenalpha": .hydrogenAlpha
        case "oiii", "o3", "oxygeniii": .oxygenIII
        case "sii", "s2", "sulfurii", "sulphurii": .sulfurII
        case "hb", "hbeta", "hydrogenbeta": .hydrogenBeta
        default: nil
        }
        if let known {
            return LiveStackFilterIdentity(
                key: known.id, displayName: known.title, source: source)
        }
        return LiveStackFilterIdentity(
            key: "named:\(alias)", displayName: displayName, source: source)
    }

    func matches(_ other: LiveStackFilterIdentity) -> Bool {
        key == other.key
    }
}

/// The camera and geometry lock applied to every candidate light after the
/// reference is chosen. Exposure and camera temperature are deliberately not
/// compared: dark-scaling policy belongs to the native stacker.
enum LiveStackCalibrationIdentity {
    static func mismatchReason(
        reference: CalibrationFrameSignature,
        candidate: CalibrationFrameSignature
    ) -> String? {
        if let reason = stringMismatch("camera", reference.camera, candidate.camera) {
            return reason
        }
        if let reason = numberMismatch("width", reference.width, candidate.width) {
            return reason
        }
        if let reason = numberMismatch("height", reference.height, candidate.height) {
            return reason
        }
        if let reason = numberMismatch(
            "channel count", reference.channels, candidate.channels) {
            return reason
        }
        if let reason = numberMismatch("X binning", reference.binningX, candidate.binningX) {
            return reason
        }
        if let reason = numberMismatch("Y binning", reference.binningY, candidate.binningY) {
            return reason
        }
        if let reason = numberMismatch("gain", reference.gain, candidate.gain) {
            return reason
        }
        if let reason = numberMismatch("offset", reference.offset, candidate.offset) {
            return reason
        }
        if let reason = numberMismatch(
            "readout mode", reference.readoutMode, candidate.readoutMode) {
            return reason
        }
        if let reason = stringMismatch(
            "Bayer pattern", reference.bayerPattern, candidate.bayerPattern) {
            return reason
        }
        return nil
    }

    private static func stringMismatch(
        _ name: String, _ reference: String?, _ candidate: String?
    ) -> String? {
        let referenceValue = collapse(reference)
        guard let referenceValue else { return nil }
        guard let candidateValue = collapse(candidate) else {
            return "The candidate does not report \(name)."
        }
        guard referenceValue.caseInsensitiveCompare(candidateValue) == .orderedSame else {
            return "The candidate \(name) does not match the reference."
        }
        return nil
    }

    private static func numberMismatch<Value: Equatable>(
        _ name: String, _ reference: Value?, _ candidate: Value?
    ) -> String? {
        guard let reference else { return nil }
        guard let candidate else {
            return "The candidate does not report \(name)."
        }
        guard reference == candidate else {
            return "The candidate \(name) does not match the reference."
        }
        return nil
    }

    private static func collapse(_ value: String?) -> String? {
        guard let value else { return nil }
        let stripped = String(value.filter { !$0.isWhitespace })
        return stripped.isEmpty ? nil : stripped
    }
}
