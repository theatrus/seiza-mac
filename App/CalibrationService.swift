import CryptoKit
import Foundation

enum CalibrationServiceError: LocalizedError {
    case core(String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .core(let message), .invalidResponse(let message):
            return message
        }
    }
}

/// One-shot native cancellation flag. `cancel()` is the only thread-safe
/// call in the ABI and may be invoked while a worker borrows the signal.
final class CalibrationCancelSignal: @unchecked Sendable {
    let pointer: OpaquePointer

    init() throws {
        guard let pointer = seiza_cancel_signal_create() else {
            throw CalibrationServiceError.core(
                "The Seiza core could not create a calibration cancellation signal.")
        }
        self.pointer = pointer
    }

    func cancel() {
        seiza_cancel_signal_cancel(pointer)
    }

    deinit {
        seiza_cancel_signal_free(pointer)
    }
}

/// Blocking wrappers over the native probe, plan, build, and matching calls.
/// Callers move the work off the main thread; the native calls themselves
/// never observe cancellation except through a cancel signal.
enum CalibrationService {
    static func probe(path: String) throws -> CalibrationFrameProbe {
        let fullPath = LiveStackPath.normalize(path)
        var errorPointer: UnsafeMutablePointer<CChar>?
        let response = fullPath.withCString { pointer in
            seiza_probe_frame_json(pointer, &errorPointer)
        }
        let data = try takeOwnedJSON(response, &errorPointer, whenMissing:
            "The Seiza core could not inspect the frame header.")
        var probe = try JSONDecoder().decode(CalibrationFrameProbe.self, from: data)
        probe.path = LiveStackPath.normalize(probe.path)
        return probe
    }

    static func plan(_ request: CalibrationPlanRequest) throws -> CalibrationPlanResult {
        let requestJSON = String(
            decoding: try JSONEncoder().encode(request), as: UTF8.self)
        var errorPointer: UnsafeMutablePointer<CChar>?
        let response = requestJSON.withCString { pointer in
            seiza_calibration_plan_json(pointer, &errorPointer)
        }
        let data = try takeOwnedJSON(response, &errorPointer, whenMissing:
            "The Seiza core could not plan the calibration selection.")
        let result = try JSONDecoder().decode(CalibrationPlanResult.self, from: data)
        guard result.schemaVersion >= 1, result.kind == request.kind,
            result.minimum == request.minimum
        else {
            throw CalibrationServiceError.invalidResponse(
                "The Seiza core returned an invalid \(request.kind) calibration plan.")
        }
        return result
    }

    static func buildMaster(
        _ request: CalibrationMasterBuildRequest,
        cancellation: CalibrationCancelSignal,
        isCancelled: () -> Bool
    ) throws -> CalibrationMasterBuildResult {
        let requestJSON = String(
            decoding: try JSONEncoder().encode(request), as: UTF8.self)
        var errorPointer: UnsafeMutablePointer<CChar>?
        let response = requestJSON.withCString { pointer in
            seiza_calibration_build_master_json(
                pointer, cancellation.pointer, &errorPointer)
        }
        guard let response else {
            let message = takeOwnedError(&errorPointer, fallback:
                "The Seiza core could not build the calibration master.")
            if isCancelled() {
                throw CancellationError()
            }
            throw CalibrationServiceError.core(message)
        }
        defer { seiza_string_free(response) }
        discardError(&errorPointer)
        let data = Data(bytes: response, count: strlen(response))
        return try JSONDecoder().decode(CalibrationMasterBuildResult.self, from: data)
    }

    private static func takeOwnedJSON(
        _ response: UnsafeMutablePointer<CChar>?,
        _ errorPointer: inout UnsafeMutablePointer<CChar>?,
        whenMissing fallback: String
    ) throws -> Data {
        guard let response else {
            throw CalibrationServiceError.core(
                takeOwnedError(&errorPointer, fallback: fallback))
        }
        defer { seiza_string_free(response) }
        discardError(&errorPointer)
        return Data(bytes: response, count: strlen(response))
    }

    static func takeOwnedError(
        _ pointer: inout UnsafeMutablePointer<CChar>?,
        fallback: String
    ) -> String {
        guard let value = pointer else { return fallback }
        pointer = nil
        let message = String(cString: value)
        seiza_string_free(value)
        return message.isEmpty ? fallback : message
    }

    static func discardError(_ pointer: inout UnsafeMutablePointer<CChar>?) {
        guard let value = pointer else { return }
        pointer = nil
        seiza_string_free(value)
    }
}

// MARK: - Frame matching

/// Tolerance overrides resolved against the native defaults before every
/// matcher call, so the defaults are never hard-coded on the Swift side.
struct CalibrationMatchTolerances: Equatable, Sendable {
    var exposureSeconds: Double
    var exposureFraction: Double
    var darkTemperatureC: Double
    var masterTemperatureC: Double
    var rotationDeg: Double
    var focalLengthMm: Double
    var flatSessionSeconds: UInt64

    static func nativeDefaults() -> CalibrationMatchTolerances {
        var native = SeizaMatchTolerances()
        seiza_match_tolerances_default(&native)
        return CalibrationMatchTolerances(
            exposureSeconds: native.exposure_seconds,
            exposureFraction: native.exposure_fraction,
            darkTemperatureC: native.dark_temperature_c,
            masterTemperatureC: native.master_temperature_c,
            rotationDeg: native.rotation_deg,
            focalLengthMm: native.focal_length_mm,
            flatSessionSeconds: native.flat_session_seconds)
    }

    static func resolve(_ overrides: CalibrationPlanTolerances) -> CalibrationMatchTolerances {
        var resolved = nativeDefaults()
        if let value = overrides.exposureSeconds { resolved.exposureSeconds = value }
        if let value = overrides.exposureFraction { resolved.exposureFraction = value }
        if let value = overrides.darkTemperatureC { resolved.darkTemperatureC = value }
        if let value = overrides.masterTemperatureC { resolved.masterTemperatureC = value }
        if let value = overrides.rotationDeg { resolved.rotationDeg = value }
        if let value = overrides.focalLengthMm { resolved.focalLengthMm = value }
        if let value = overrides.flatSessionSeconds { resolved.flatSessionSeconds = value }
        return resolved
    }

    fileprivate var native: SeizaMatchTolerances {
        var value = SeizaMatchTolerances()
        value.known = UInt32(
            SEIZA_TOLERANCE_HAS_EXPOSURE
                | SEIZA_TOLERANCE_HAS_DARK_TEMPERATURE
                | SEIZA_TOLERANCE_HAS_MASTER_TEMPERATURE
                | SEIZA_TOLERANCE_HAS_ROTATION
                | SEIZA_TOLERANCE_HAS_FOCAL_LENGTH
                | SEIZA_TOLERANCE_HAS_FLAT_SESSION
                | SEIZA_TOLERANCE_HAS_EXPOSURE_FRACTION)
        value.exposure_seconds = exposureSeconds
        value.exposure_fraction = exposureFraction
        value.dark_temperature_c = darkTemperatureC
        value.master_temperature_c = masterTemperatureC
        value.rotation_deg = rotationDeg
        value.focal_length_mm = focalLengthMm
        value.flat_session_seconds = flatSessionSeconds
        return value
    }
}

enum CalibrationMatchingService {
    static func sensorMatches(
        reference: CalibrationFrameSignature,
        candidate: CalibrationFrameSignature
    ) throws -> Bool {
        try withNativeSignatures(reference, candidate) { referencePointer, candidatePointer in
            var errorPointer: UnsafeMutablePointer<CChar>?
            let result = seiza_calibration_sensor_matches(
                referencePointer, candidatePointer, &errorPointer)
            return try readMatchResult(result, &errorPointer)
        }
    }

    static func opticsMatch(
        reference: CalibrationFrameSignature,
        candidate: CalibrationFrameSignature,
        tolerances: CalibrationMatchTolerances
    ) throws -> Bool {
        try withNativeSignatures(reference, candidate) { referencePointer, candidatePointer in
            var native = tolerances.native
            var errorPointer: UnsafeMutablePointer<CChar>?
            let result = seiza_calibration_optics_match(
                referencePointer, candidatePointer, &native, &errorPointer)
            return try readMatchResult(result, &errorPointer)
        }
    }

    static func darkMatches(
        reference: CalibrationFrameSignature,
        candidate: CalibrationFrameSignature,
        tolerances: CalibrationMatchTolerances
    ) throws -> Bool {
        try withNativeSignatures(reference, candidate) { referencePointer, candidatePointer in
            var native = tolerances.native
            var errorPointer: UnsafeMutablePointer<CChar>?
            let result = seiza_calibration_dark_matches(
                referencePointer, candidatePointer, &native, &errorPointer)
            return try readMatchResult(result, &errorPointer)
        }
    }

    static func describeSensorMismatch(
        reference: CalibrationFrameSignature,
        candidate: CalibrationFrameSignature
    ) throws -> String {
        try withNativeSignatures(reference, candidate) { referencePointer, candidatePointer in
            var errorPointer: UnsafeMutablePointer<CChar>?
            let description = seiza_calibration_describe_sensor_mismatch(
                referencePointer, candidatePointer, &errorPointer)
            return try readDescription(description, &errorPointer)
        }
    }

    static func describeOpticsMismatch(
        reference: CalibrationFrameSignature,
        candidate: CalibrationFrameSignature,
        tolerances: CalibrationMatchTolerances
    ) throws -> String {
        try withNativeSignatures(reference, candidate) { referencePointer, candidatePointer in
            var native = tolerances.native
            var errorPointer: UnsafeMutablePointer<CChar>?
            let description = seiza_calibration_describe_optics_mismatch(
                referencePointer, candidatePointer, &native, &errorPointer)
            return try readDescription(description, &errorPointer)
        }
    }

    private static func readMatchResult(
        _ result: Int32,
        _ errorPointer: inout UnsafeMutablePointer<CChar>?
    ) throws -> Bool {
        switch result {
        case 1:
            CalibrationService.discardError(&errorPointer)
            return true
        case 0:
            CalibrationService.discardError(&errorPointer)
            return false
        default:
            throw CalibrationServiceError.core(
                CalibrationService.takeOwnedError(&errorPointer, fallback:
                    "The Seiza core could not compare the calibration signatures."))
        }
    }

    private static func readDescription(
        _ description: UnsafeMutablePointer<CChar>?,
        _ errorPointer: inout UnsafeMutablePointer<CChar>?
    ) throws -> String {
        guard let description else {
            throw CalibrationServiceError.core(
                CalibrationService.takeOwnedError(&errorPointer, fallback:
                    "The Seiza core could not describe the calibration mismatch."))
        }
        defer { seiza_string_free(description) }
        if errorPointer != nil {
            throw CalibrationServiceError.core(
                CalibrationService.takeOwnedError(&errorPointer, fallback:
                    "The Seiza core could not describe the calibration mismatch."))
        }
        return String(cString: description)
    }

    private static func withNativeSignatures<Result>(
        _ reference: CalibrationFrameSignature,
        _ candidate: CalibrationFrameSignature,
        _ body: (
            UnsafePointer<SeizaFrameSignature>, UnsafePointer<SeizaFrameSignature>
        ) throws -> Result
    ) rethrows -> Result {
        try withNativeSignature(reference) { referencePointer in
            try withNativeSignature(candidate) { candidatePointer in
                try body(referencePointer, candidatePointer)
            }
        }
    }

    private static func withNativeSignature<Result>(
        _ signature: CalibrationFrameSignature,
        _ body: (UnsafePointer<SeizaFrameSignature>) throws -> Result
    ) rethrows -> Result {
        try withNormalizedCString(signature.camera) { camera in
            try withNormalizedCString(signature.telescope) { telescope in
                try withNormalizedCString(signature.bayerPattern) { bayerPattern in
                    try withNormalizedCString(signature.filter) { filter in
                        var native = SeizaFrameSignature()
                        native.camera = camera
                        native.telescope = telescope
                        native.bayer_pattern = bayerPattern
                        native.filter = filter
                        var known: UInt32 = 0
                        func set(
                            _ value: Double?, _ flag: Int32,
                            _ write: (inout SeizaFrameSignature, Double) -> Void
                        ) {
                            guard let value, value.isFinite else { return }
                            known |= UInt32(flag)
                            write(&native, value)
                        }
                        set(signature.width.map(Double.init), SEIZA_FRAME_HAS_WIDTH) {
                            $0.width = $1
                        }
                        set(signature.height.map(Double.init), SEIZA_FRAME_HAS_HEIGHT) {
                            $0.height = $1
                        }
                        set(signature.channels.map(Double.init), SEIZA_FRAME_HAS_CHANNELS) {
                            $0.channels = $1
                        }
                        set(signature.binningX.map(Double.init), SEIZA_FRAME_HAS_BINNING_X) {
                            $0.binning_x = $1
                        }
                        set(signature.binningY.map(Double.init), SEIZA_FRAME_HAS_BINNING_Y) {
                            $0.binning_y = $1
                        }
                        set(signature.gain.map(Double.init), SEIZA_FRAME_HAS_GAIN) {
                            $0.gain = $1
                        }
                        set(signature.offset.map(Double.init), SEIZA_FRAME_HAS_OFFSET) {
                            $0.offset = $1
                        }
                        set(
                            signature.readoutMode.map(Double.init),
                            SEIZA_FRAME_HAS_READOUT_MODE
                        ) { $0.readout_mode = $1 }
                        set(signature.focalLengthMm, SEIZA_FRAME_HAS_FOCAL_LENGTH) {
                            $0.focal_length_mm = $1
                        }
                        set(signature.rotationDeg, SEIZA_FRAME_HAS_ROTATION) {
                            $0.rotation_deg = $1
                        }
                        set(signature.exposureSeconds, SEIZA_FRAME_HAS_EXPOSURE) {
                            $0.exposure_seconds = $1
                        }
                        set(signature.cameraTempC, SEIZA_FRAME_HAS_CAMERA_TEMP) {
                            $0.camera_temp_c = $1
                        }
                        set(
                            signature.capturedAtUnix.map(Double.init),
                            SEIZA_FRAME_HAS_CAPTURED_AT
                        ) { $0.captured_at_unix = $1 }
                        native.known = known
                        return try withUnsafePointer(to: native) { pointer in
                            try body(pointer)
                        }
                    }
                }
            }
        }
    }

    private static func withNormalizedCString<Result>(
        _ value: String?,
        _ body: (UnsafePointer<CChar>?) throws -> Result
    ) rethrows -> Result {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return try body(nil)
        }
        return try value.withCString { pointer in
            try body(pointer)
        }
    }
}

// MARK: - Cache identity

enum CalibrationCachePaths {
    /// Per-library master cache: Application Support/Seiza/CalibrationMasters/{id},
    /// where the id is the first 6 bytes of the SHA-256 of the uppercased
    /// normalized library path, in lowercase hex.
    static func forLibrary(_ libraryPath: String) -> URL {
        baseDirectory().appendingPathComponent(directoryIdentity(for: libraryPath))
    }

    static func baseDirectory() -> URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support
            .appendingPathComponent("Seiza", isDirectory: true)
            .appendingPathComponent("CalibrationMasters", isDirectory: true)
    }

    static func directoryIdentity(for libraryPath: String) -> String {
        let normalized = LiveStackPath.normalize(libraryPath).uppercased()
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }
}
