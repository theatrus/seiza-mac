import CoreGraphics
import Foundation

enum LiveStackSessionError: LocalizedError {
    case core(String)
    case invalidState(String)
    case closed

    var errorDescription: String? {
        switch self {
        case .core(let message), .invalidState(let message):
            return message
        case .closed:
            return "The live-stack session is closed."
        }
    }
}

/// The authoritative native description of a live stacker, returned by
/// `seiza_live_stacker_state_json` and persisted beside every checkpoint.
struct LiveStackNativeState: Codable, Equatable, Sendable {
    struct ReferenceFrame: Codable, Equatable, Sendable {
        var role: String
        var isMaster = false
        var signature = CalibrationFrameSignature()
        var calibrationState = CalibrationFrameState()
    }

    var schemaVersion: Int
    var coreVersion: String
    var configurationFingerprint: String
    var width: Int
    var height: Int
    var channels: Int
    var acceptedFrames: Int
    var rejectedFrames: Int
    var inputMode: String
    var inputPaths: [String]
    var referenceFrame: ReferenceFrame? = nil

    var isValidFromCore: Bool {
        schemaVersion == 1
            && !coreVersion.trimmingCharacters(in: .whitespaces).isEmpty
            && width > 0 && height > 0
            && (channels == 1 || channels == 3)
            && acceptedFrames > 0
            && rejectedFrames >= 0
            && configurationFingerprint.count == 64
            && configurationFingerprint.allSatisfy { character in
                character.isNumber || ("a"..."f").contains(String(character))
            }
            && (inputMode == "calibrate-and-prepare" || inputMode == "prepared-only")
            && inputPaths.allSatisfy {
                !$0.trimmingCharacters(in: .whitespaces).isEmpty
            }
    }

    /// True when the persisted manifest expectation and a freshly reopened
    /// context describe the same checkpoint. A reference frame recorded in
    /// the manifest must match; a newer core adding the field to an older
    /// manifest is tolerated.
    func describesSameCheckpoint(_ actual: LiveStackNativeState) -> Bool {
        guard schemaVersion == actual.schemaVersion,
            width == actual.width,
            height == actual.height,
            channels == actual.channels,
            acceptedFrames == actual.acceptedFrames,
            rejectedFrames == actual.rejectedFrames,
            inputMode == actual.inputMode,
            configurationFingerprint == actual.configurationFingerprint,
            inputPaths.count == actual.inputPaths.count
        else { return false }
        if let referenceFrame, referenceFrame != actual.referenceFrame {
            return false
        }
        for (expected, present) in zip(inputPaths, actual.inputPaths)
        where !LiveStackPath.equals(expected, present) {
            return false
        }
        return true
    }
}

struct LiveStackSessionCounts: Equatable, Sendable {
    var acceptedFrames: Int
    var rejectedFrames: Int
}

/// The outcome of offering one file to the native stacker. A nil disposition
/// means the file itself could not be read — a retryable I/O condition, not
/// a native rejection.
struct LiveStackPushOutcome: Sendable {
    var disposition: ImageStackDisposition?
    var nativeError: String?
}

/// A bounded autostretched render of the live accumulator.
struct LiveStackPreview: Sendable {
    let rgba: Data
    let width: Int
    let height: Int

    func makeCGImage() -> CGImage? {
        guard width > 0, height > 0, rgba.count == width * height * 4 else {
            return nil
        }
        guard let provider = CGDataProvider(data: rgba as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent)
    }
}

/// A lightweight export of the accumulator that stays valid while ingestion
/// continues. Owns only the copied mean and output metadata.
final class LiveStackExportSnapshot: @unchecked Sendable {
    private var pointer: OpaquePointer?
    let acceptedFrames: Int

    fileprivate init(pointer: OpaquePointer, acceptedFrames: Int) {
        self.pointer = pointer
        self.acceptedFrames = acceptedFrames
    }

    func writeFITS(to path: String) throws {
        guard let pointer else { throw LiveStackSessionError.closed }
        try LiveStackAtomicFITS.write(to: path) { stagingPath, errorPointer in
            stagingPath.withCString { staging in
                seiza_stack_export_snapshot_write_fits(pointer, staging, &errorPointer)
            }
        }
    }

    func free() {
        if let pointer {
            seiza_stack_export_snapshot_free(pointer)
        }
        pointer = nil
    }

    deinit {
        free()
    }
}

/// The finished accumulator produced by consuming the live stacker.
final class LiveStackFinishedSnapshot: @unchecked Sendable {
    private var pointer: OpaquePointer?

    fileprivate init(pointer: OpaquePointer) {
        self.pointer = pointer
    }

    var acceptedFrames: Int {
        pointer.map { Int(seiza_stack_snapshot_accepted_frames($0)) } ?? 0
    }

    var rejectedFrames: Int {
        pointer.map { Int(seiza_stack_snapshot_rejected_frames($0)) } ?? 0
    }

    func writeFITS(to path: String) throws {
        guard let pointer else { throw LiveStackSessionError.closed }
        try LiveStackAtomicFITS.write(to: path) { stagingPath, errorPointer in
            stagingPath.withCString { staging in
                seiza_stack_snapshot_write_fits(pointer, staging, &errorPointer)
            }
        }
    }

    func free() {
        if let pointer {
            seiza_stack_snapshot_free(pointer)
        }
        pointer = nil
    }

    deinit {
        free()
    }
}

/// Atomic FITS publication: the native writer targets a hidden staging file
/// beside the destination, which is renamed into place only on success.
enum LiveStackAtomicFITS {
    static let stagingPrefix = ".seiza-stack-"

    static func write(
        to path: String,
        using writer: (String, inout UnsafeMutablePointer<CChar>?) -> Bool
    ) throws {
        let destination = URL(fileURLWithPath: path)
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent("\(stagingPrefix)\(token).fits")
        defer { try? FileManager.default.removeItem(at: staging) }
        var errorPointer: UnsafeMutablePointer<CChar>?
        guard writer(staging.path, &errorPointer) else {
            throw LiveStackSessionError.core(
                CalibrationService.takeOwnedError(&errorPointer, fallback:
                    "The Seiza core could not write the stack output."))
        }
        CalibrationService.discardError(&errorPointer)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: staging, to: destination)
    }
}

/// Owns one native live stacker. Every call runs serialized inside the
/// actor; borrowed native buffers are copied before they escape. Native
/// calls are not cancellable — cancellation is observed between calls.
actor LiveStackNativeSession {
    private var stacker: OpaquePointer?
    private var finalized = false

    private init(stacker: OpaquePointer) {
        self.stacker = stacker
    }

    /// Opens a new stacker on a reference light, with optional masters.
    static func open(
        referencePath: String,
        optionsJSON: String,
        calibration: ImageStackCalibration
    ) throws -> LiveStackNativeSession {
        var errorPointer: UnsafeMutablePointer<CChar>?
        let handle = withOptionalCString(calibration.bias?.path) { bias in
            withOptionalCString(calibration.dark?.path) { dark in
                withOptionalCString(calibration.flat?.path) { flat in
                    referencePath.withCString { reference in
                        optionsJSON.withCString { options in
                            seiza_live_stacker_open_fits(
                                reference,
                                bias,
                                dark,
                                flat,
                                calibration.overridesDarkExposure
                                    ? calibration.darkExposureSeconds
                                    : 0,
                                options,
                                &errorPointer)
                        }
                    }
                }
            }
        }
        guard let handle else {
            throw LiveStackSessionError.core(
                CalibrationService.takeOwnedError(&errorPointer, fallback:
                    "The Seiza core could not open the reference image."))
        }
        return LiveStackNativeSession(stacker: handle)
    }

    /// Reopens a saved checkpoint context. The restored stacker retains its
    /// registration reference, calibration, rejection state, and ledger.
    static func resume(contextPath: String) throws -> LiveStackNativeSession {
        var errorPointer: UnsafeMutablePointer<CChar>?
        let handle = contextPath.withCString { path in
            seiza_live_stacker_open_context(path, &errorPointer)
        }
        guard let handle else {
            throw LiveStackSessionError.core(
                CalibrationService.takeOwnedError(&errorPointer, fallback:
                    "The Seiza core could not reopen the live-stack checkpoint."))
        }
        return LiveStackNativeSession(stacker: handle)
    }

    var isFinalized: Bool { finalized }

    func push(path: String) throws -> LiveStackPushOutcome {
        let handle = try requireHandle()
        var errorPointer: UnsafeMutablePointer<CChar>?
        let response = path.withCString { pointer in
            seiza_live_stacker_push_fits_json(handle, pointer, &errorPointer)
        }
        guard let response else {
            return LiveStackPushOutcome(
                disposition: nil,
                nativeError: CalibrationService.takeOwnedError(
                    &errorPointer, fallback: "The frame could not be read."))
        }
        defer { seiza_string_free(response) }
        CalibrationService.discardError(&errorPointer)
        let data = Data(bytes: response, count: strlen(response))
        let disposition = try JSONDecoder().decode(ImageStackDisposition.self, from: data)
        return LiveStackPushOutcome(disposition: disposition, nativeError: nil)
    }

    func counts() throws -> LiveStackSessionCounts {
        let handle = try requireHandle()
        return LiveStackSessionCounts(
            acceptedFrames: Int(seiza_live_stacker_accepted_frames(handle)),
            rejectedFrames: Int(seiza_live_stacker_rejected_frames(handle)))
    }

    func state() throws -> LiveStackNativeState {
        let handle = try requireHandle()
        return try readState(handle)
    }

    /// Saves the opaque context and returns the state describing it, in one
    /// serialized step so the state can never describe a later accumulator
    /// than the file.
    func saveContext(to contextPath: String) throws -> LiveStackNativeState {
        let handle = try requireHandle()
        var errorPointer: UnsafeMutablePointer<CChar>?
        let saved = contextPath.withCString { path in
            seiza_live_stacker_save_context(handle, path, &errorPointer)
        }
        guard saved else {
            throw LiveStackSessionError.core(
                CalibrationService.takeOwnedError(&errorPointer, fallback:
                    "The Seiza core could not save the live-stack checkpoint."))
        }
        CalibrationService.discardError(&errorPointer)
        return try readState(handle)
    }

    /// Atomically replaces the active masters. The complete set is validated
    /// against the immutable registration reference before anything changes;
    /// a failure leaves the stacker untouched.
    func setCalibration(_ calibration: ImageStackCalibration) throws {
        let handle = try requireHandle()
        var errorPointer: UnsafeMutablePointer<CChar>?
        let succeeded = withOptionalCString(calibration.bias?.path) { bias in
            withOptionalCString(calibration.dark?.path) { dark in
                withOptionalCString(calibration.flat?.path) { flat in
                    seiza_live_stacker_set_calibration_fits(
                        handle,
                        bias,
                        dark,
                        flat,
                        calibration.overridesDarkExposure
                            ? calibration.darkExposureSeconds
                            : 0,
                        &errorPointer)
                }
            }
        }
        guard succeeded else {
            throw LiveStackSessionError.core(
                CalibrationService.takeOwnedError(&errorPointer, fallback:
                    "The Seiza core could not apply the calibration masters."))
        }
        CalibrationService.discardError(&errorPointer)
    }

    func renderPreview(
        configJSON: String,
        maxDimension: UInt32
    ) throws -> LiveStackPreview {
        let handle = try requireHandle()
        var errorPointer: UnsafeMutablePointer<CChar>?
        let image = configJSON.withCString { config in
            seiza_live_stacker_render_preview(
                handle, config, maxDimension, &errorPointer)
        }
        guard let image else {
            throw LiveStackSessionError.core(
                CalibrationService.takeOwnedError(&errorPointer, fallback:
                    "The Seiza core could not render the live preview."))
        }
        defer { seiza_rendered_image_free(image) }
        CalibrationService.discardError(&errorPointer)
        let width = Int(seiza_rendered_image_width(image))
        let height = Int(seiza_rendered_image_height(image))
        let length = Int(seiza_rendered_image_rgba_length(image))
        guard width > 0, height > 0, length == width * height * 4,
            let rgba = seiza_rendered_image_rgba(image)
        else {
            throw LiveStackSessionError.invalidState(
                "The Seiza core returned an invalid live preview.")
        }
        return LiveStackPreview(
            rgba: Data(bytes: rgba, count: length),
            width: width,
            height: height)
    }

    /// Captures a lightweight export snapshot; ingestion may continue while
    /// the returned snapshot is written on another thread.
    func exportSnapshot() throws -> LiveStackExportSnapshot {
        let handle = try requireHandle()
        let accepted = Int(seiza_live_stacker_accepted_frames(handle))
        var errorPointer: UnsafeMutablePointer<CChar>?
        let snapshot = seiza_live_stacker_export_snapshot(handle, &errorPointer)
        guard let snapshot else {
            throw LiveStackSessionError.core(
                CalibrationService.takeOwnedError(&errorPointer, fallback:
                    "The Seiza core could not snapshot the live stack."))
        }
        CalibrationService.discardError(&errorPointer)
        return LiveStackExportSnapshot(pointer: snapshot, acceptedFrames: accepted)
    }

    /// Measures the accumulator's noise at the current depth. Nil means no
    /// reading is available yet — an ordinary early-stack answer.
    func measureDepth() throws -> StackSnrSample? {
        let handle = try requireHandle()
        var sample = SeizaSnrSample()
        var errorPointer: UnsafeMutablePointer<CChar>?
        let result = seiza_live_stacker_measure_depth(handle, &sample, &errorPointer)
        switch result {
        case 1:
            CalibrationService.discardError(&errorPointer)
            let channelCount = min(Int(sample.channel_count), 3)
            var channelNoise: [Double] = []
            withUnsafeBytes(of: sample.channel_noise) { raw in
                let values = raw.bindMemory(to: Double.self)
                for index in 0..<channelCount {
                    channelNoise.append(values[index])
                }
            }
            return StackSnrSample(
                frames: sample.frames,
                noise: sample.noise,
                background: sample.background,
                signal: sample.signal,
                snr: sample.snr,
                channelNoise: channelNoise)
        case 0:
            guard errorPointer == nil else {
                throw LiveStackSessionError.core(
                    CalibrationService.takeOwnedError(&errorPointer, fallback:
                        "The Seiza core could not measure the stack depth."))
            }
            return nil
        default:
            throw LiveStackSessionError.core(
                CalibrationService.takeOwnedError(&errorPointer, fallback:
                    "The Seiza core could not measure the stack depth."))
        }
    }

    /// Consumes the stacker and returns the finished snapshot. After this
    /// call the session cannot push or checkpoint again.
    func finish() throws -> LiveStackFinishedSnapshot {
        _ = try requireHandle()
        var errorPointer: UnsafeMutablePointer<CChar>?
        finalized = true
        let snapshot = seiza_live_stacker_finish(&stacker, &errorPointer)
        stacker = nil
        guard let snapshot else {
            throw LiveStackSessionError.core(
                CalibrationService.takeOwnedError(&errorPointer, fallback:
                    "The Seiza core could not finish the live stack."))
        }
        CalibrationService.discardError(&errorPointer)
        return LiveStackFinishedSnapshot(pointer: snapshot)
    }

    func close() {
        if let stacker {
            seiza_live_stacker_free(stacker)
        }
        stacker = nil
    }

    private func requireHandle() throws -> OpaquePointer {
        guard let stacker else { throw LiveStackSessionError.closed }
        return stacker
    }

    private func readState(_ handle: OpaquePointer) throws -> LiveStackNativeState {
        var errorPointer: UnsafeMutablePointer<CChar>?
        let response = seiza_live_stacker_state_json(handle, &errorPointer)
        guard let response else {
            throw LiveStackSessionError.core(
                CalibrationService.takeOwnedError(&errorPointer, fallback:
                    "The Seiza core could not report the live-stack state."))
        }
        defer { seiza_string_free(response) }
        CalibrationService.discardError(&errorPointer)
        let data = Data(bytes: response, count: strlen(response))
        let state = try JSONDecoder().decode(LiveStackNativeState.self, from: data)
        guard state.isValidFromCore else {
            throw LiveStackSessionError.invalidState(
                "The Seiza core returned invalid live-stack state.")
        }
        return state
    }
}

func withOptionalCString<Result>(
    _ value: String?,
    _ body: (UnsafePointer<CChar>?) -> Result
) -> Result {
    guard let value else { return body(nil) }
    return value.withCString(body)
}
