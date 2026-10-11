import AVFoundation
import CoreVideo
import Foundation
import VideoToolbox

/// Pulls frames only as AVFoundation accepts them; no full-movie frame array or
/// external encoder. Both the writer and its producer live on one private queue.
enum NativeVideoExporter {
    enum Codec: String, CaseIterable { case h264 = "H.264", hevc = "HEVC"
        var avCodec: AVVideoCodecType { self == .h264 ? .h264 : .hevc }
    }

    static func write(to destination: URL, width: Int, height: Int, fps: Int,
                      frames: Int, codec: Codec, cancellation: ParallaxCancellation,
                      render: @escaping (Int, CVPixelBuffer) throws -> Void,
                      progress: @escaping (Int, Int) -> Void) async throws {
        guard width >= 16, height >= 16, width <= 3840, height <= 3840,
            width.isMultiple(of: 2), height.isMultiple(of: 2), fps > 0, fps <= 60,
            frames >= 2, frames <= 36_000 else {
            throw SeizaCoreError.message("Unsupported video size or duration.")
        }
        try cancellation.check()
        let accessing = destination.startAccessingSecurityScopedResource()
        defer { if accessing { destination.stopAccessingSecurityScopedResource() } }
        let manager = FileManager.default
        let staging = try manager.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                      appropriateFor: destination, create: true)
        defer { try? manager.removeItem(at: staging) }
        let output = staging.appendingPathComponent("video.mp4")
        let job = try VideoEncodingJob(output: output, width: width, height: height,
            fps: fps, frames: frames, codec: codec, cancellation: cancellation,
            render: render, progress: progress)
        defer { withExtendedLifetime(job) {} }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            job.start(continuation)
        }
        try cancellation.check()
        if manager.fileExists(atPath: destination.path) {
            _ = try manager.replaceItemAt(destination, withItemAt: output)
        } else {
            try manager.moveItem(at: output, to: destination)
        }
    }
}

private final class VideoEncodingJob: @unchecked Sendable {
    let writer: AVAssetWriter
    let input: AVAssetWriterInput
    let adaptor: AVAssetWriterInputPixelBufferAdaptor
    let queue = DispatchQueue(label: "fyi.seiza.parallax.encoder", qos: .userInitiated)
    let fps: Int
    let frames: Int
    let cancellation: ParallaxCancellation
    let render: (Int, CVPixelBuffer) throws -> Void
    let progress: (Int, Int) -> Void
    var continuation: CheckedContinuation<Void, Error>?
    var timer: DispatchSourceTimer?
    var index = 0
    var finishing = false
    var completed = false

    init(output: URL, width: Int, height: Int, fps: Int, frames: Int,
         codec: NativeVideoExporter.Codec, cancellation: ParallaxCancellation,
         render: @escaping (Int, CVPixelBuffer) throws -> Void,
         progress: @escaping (Int, Int) -> Void) throws {
        self.fps = fps; self.frames = frames; self.cancellation = cancellation
        self.render = render; self.progress = progress
        writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: codec.avCodec,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoEncoderSpecificationKey: [
                kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(2_000_000, width * height * fps / 2),
                AVVideoExpectedSourceFrameRateKey: fps,
                // Keep encoder lookahead compatible with the bounded pool.
                AVVideoAllowFrameReorderingKey: false,
            ],
            // The prepared display pixels follow the app's sRGB convention.
            // Keep that transfer function; don't just relabel them as Rec.709.
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_IEC_sRGB,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
        guard writer.canApply(outputSettings: settings, forMediaType: .video) else {
            throw SeizaCoreError.message("This Mac cannot encode the selected format and dimensions. Try H.264 at 1080p.")
        }
        input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ])
        guard writer.canAdd(input) else { throw SeizaCoreError.message("The native video encoder is unavailable.") }
        writer.add(input)
    }

    func start(_ continuation: CheckedContinuation<Void, Error>) {
        queue.async { [self] in
            self.continuation = continuation
            guard writer.startWriting() else {
                complete(.failure(writer.error ?? SeizaCoreError.message("Could not start the native encoder.")))
                return
            }
            writer.startSession(atSourceTime: .zero)
            // Cancellation must also work when AVFoundation is not ready for data.
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(100))
            timer.setEventHandler { [weak self] in
                guard let self, !completed else { return }
                if cancellation.isCancelled { complete(.failure(CancellationError())) }
                else if writer.status == .failed { complete(.failure(writer.error ?? SeizaCoreError.message("Encoding failed."))) }
            }
            self.timer = timer
            timer.resume()
            input.requestMediaDataWhenReady(on: queue) { [weak self] in self?.pump() }
        }
    }

    private func pump() {
        guard !completed, !finishing else { return }
        do {
            while input.isReadyForMoreMediaData && index < frames {
                try cancellation.check()
                let appended = try autoreleasepool { () throws -> Bool in
                    guard let pool = adaptor.pixelBufferPool else { throw SeizaCoreError.message("The encoder has no pixel buffer pool.") }
                    var buffer: CVPixelBuffer?
                    // Cap pooled buffers while respecting encoder ownership.
                    let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool,
                        [kCVPixelBufferPoolAllocationThresholdKey: 6] as CFDictionary, &buffer)
                    if status == kCVReturnWouldExceedAllocationThreshold { return false }
                    guard status == kCVReturnSuccess, let buffer else {
                        throw SeizaCoreError.message("Could not allocate a video frame (CoreVideo \(status)). \(writer.error?.localizedDescription ?? "Try a smaller resolution or H.264.")")
                    }
                    try render(index, buffer)
                    CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
                    CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
                    CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
                    try cancellation.check()
                    guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: Int32(fps))) else {
                        throw writer.error ?? SeizaCoreError.message("The encoder rejected a frame.")
                    }
                    index += 1
                    progress(index, frames)
                    return true
                }
                if !appended {
                    queue.asyncAfter(deadline: .now() + .milliseconds(10)) { [self] in pump() }
                    return
                }
                if index < frames && !input.isReadyForMoreMediaData { return }
            }
            if index == frames {
                finishing = true
                input.markAsFinished()
                writer.endSession(atSourceTime: CMTime(value: Int64(frames), timescale: Int32(fps)))
                writer.finishWriting { [self] in
                    queue.async {
                        guard !self.completed else { return }
                        if self.cancellation.isCancelled { self.complete(.failure(CancellationError())) }
                        else if self.writer.status == .completed { self.complete(.success(())) }
                        else { self.complete(.failure(self.writer.error ?? SeizaCoreError.message("Could not finalize the movie."))) }
                    }
                }
            }
        } catch { complete(.failure(error)) }
    }

    private func complete(_ result: Result<Void, Error>) {
        guard !completed else { return }
        completed = true
        timer?.cancel(); timer = nil
        if case .failure = result { writer.cancelWriting() }
        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume(with: result)
    }
}
