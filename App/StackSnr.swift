import Foundation

/// One native noise reading of a stack accumulator, in the stack's own units.
/// Only ratios between readings of the same stack mean anything.
struct StackSnrSample: Equatable, Sendable {
    var frames: UInt32
    var noise: Double
    var background: Double
    var signal: Double
    var snr: Double
    var channelNoise: [Double]

    /// Copies a native reading. Valid only when the measuring ABI call
    /// returned exactly 1.
    init(native: SeizaSnrSample) {
        frames = native.frames
        noise = native.noise
        background = native.background
        signal = native.signal
        snr = native.snr
        let channelCount = min(Int(native.channel_count), Int(SEIZA_SNR_MAX_CHANNELS))
        var channels: [Double] = []
        withUnsafeBytes(of: native.channel_noise) { raw in
            let values = raw.bindMemory(to: Double.self)
            for index in 0..<channelCount {
                channels.append(values[index])
            }
        }
        channelNoise = channels
    }

    init(
        frames: UInt32,
        noise: Double,
        background: Double,
        signal: Double,
        snr: Double,
        channelNoise: [Double]
    ) {
        self.frames = frames
        self.noise = noise
        self.background = background
        self.signal = signal
        self.snr = snr
        self.channelNoise = channelNoise
    }

    /// The per-reading `snr` flatters shallow stacks; depth comparisons
    /// divide one common signal by each depth's noise instead.
    func relativeSnr(commonSignal: Double) -> Double {
        guard commonSignal.isFinite, commonSignal > 0, noise.isFinite, noise > 0 else {
            return 0
        }
        return commonSignal / noise
    }
}

/// A persisted live-stack SNR reading with capture telemetry.
struct LiveStackPersistedSnrSample: Codable, Equatable, Sendable {
    var acceptedFrames: Int
    var cumulativeExposureSeconds: Double?
    var noise: Double
    var background: Double
    var signal: Double
    var channelNoise: [Double]
    var measuredAtUTC: Date

    var isUsable: Bool {
        acceptedFrames > 0 && noise.isFinite && noise > 0 && signal.isFinite
    }
}

/// A depth measurement handed to the analyzer.
struct StackSnrMeasurement: Equatable, Sendable {
    var frames: UInt32
    var noise: Double
    var background: Double
    var signal: Double
    var exposureSeconds: Double = 0
}

/// One plotted depth: relative SNR against a shared deepest-signal baseline.
struct StackSnrPlotPoint: Equatable, Sendable {
    var frames: UInt32
    var snr: Double
    var noise: Double
    var exposureSeconds: Double
}

/// The analyzed depth curve plus its noise-improvement summary.
struct StackSnrAnalysis: Equatable, Sendable {
    var points: [StackSnrPlotPoint]
    var noiseImprovement: Double
    var idealImprovement: Double
    var efficiency: Double

    static let empty = StackSnrAnalysis(
        points: [], noiseImprovement: 0, idealImprovement: 0, efficiency: 0)
}

enum StackSnrAnalyzer {
    /// Orders usable measurements by depth (the last reading at a depth
    /// wins), rates every depth against the deepest measured signal, and
    /// summarizes measured noise improvement against the square-root ideal.
    static func analyze(_ measurements: [StackSnrMeasurement]) -> StackSnrAnalysis {
        var byDepth: [UInt32: StackSnrMeasurement] = [:]
        for measurement in measurements
        where measurement.frames > 0
            && measurement.noise.isFinite && measurement.noise > 0
            && measurement.signal.isFinite {
            byDepth[measurement.frames] = measurement
        }
        let samples = byDepth.values.sorted { $0.frames < $1.frames }
        guard let first = samples.first, let last = samples.last else { return .empty }
        let commonSignal = last.signal
        guard commonSignal.isFinite, commonSignal > 0 else { return .empty }

        let points = samples.map { sample in
            StackSnrPlotPoint(
                frames: sample.frames,
                snr: commonSignal / sample.noise,
                noise: sample.noise,
                exposureSeconds: sample.exposureSeconds)
        }
        let noiseImprovement = first.noise / last.noise
        let idealImprovement = (Double(last.frames) / Double(first.frames)).squareRoot()
        return StackSnrAnalysis(
            points: points,
            noiseImprovement: noiseImprovement,
            idealImprovement: idealImprovement,
            efficiency: idealImprovement > 0 ? noiseImprovement / idealImprovement : 0)
    }
}

enum StackSnrMeasurementSchedule {
    /// Depths a finite stack of `total` frames should measure at: the
    /// doubling ladder plus the final depth, from the native schedule.
    static func depths(totalFrames: Int) -> Set<Int> {
        guard totalFrames > 0 else { return [] }
        let count = Int(seiza_checkpoint_depths(size_t(totalFrames), nil, 0))
        guard count > 0 else { return [] }
        var buffer = [size_t](repeating: 0, count: count)
        let written = buffer.withUnsafeMutableBufferPointer { pointer in
            Int(seiza_checkpoint_depths(
                size_t(totalFrames), pointer.baseAddress, size_t(count)))
        }
        guard written == count else { return [] }
        return Set(buffer.map { Int($0) })
    }

    /// Whether an open-ended live stack owes a measurement at this depth:
    /// depth is a power of two (or the closing measurement forces the
    /// current depth) and the depth has not been measured yet.
    static func isLiveMeasurementDue(
        acceptedFrames: Int,
        measuredDepths: Set<Int>,
        includeCurrentDepth: Bool = false
    ) -> Bool {
        guard acceptedFrames > 0 else { return false }
        guard includeCurrentDepth || isPowerOfTwo(acceptedFrames) else { return false }
        return !measuredDepths.contains(acceptedFrames)
    }

    static func isPowerOfTwo(_ value: Int) -> Bool {
        value > 0 && value & (value - 1) == 0
    }
}

enum LiveStackExposureMath {
    /// Total exposure across accepted frames, or nil unless every accepted
    /// frame reports a finite positive exposure.
    static func cumulativeExposure(_ acceptedExposures: [Double?]) -> Double? {
        var total = 0.0
        for exposure in acceptedExposures {
            guard let exposure, exposure.isFinite, exposure > 0 else { return nil }
            total += exposure
        }
        return acceptedExposures.isEmpty ? nil : total
    }
}

/// Screen-space geometry for the depth chart: measured and ideal series
/// share X positions on log-log axes.
struct StackSnrPlotGeometry: Equatable {
    var measured: [CGPoint]
    var ideal: [CGPoint]
    var minimumFrames: UInt32
    var maximumFrames: UInt32

    static let empty = StackSnrPlotGeometry(
        measured: [], ideal: [], minimumFrames: 0, maximumFrames: 0)

    var isEmpty: Bool { measured.isEmpty }
}

enum StackSnrPlotLayout {
    static func create(
        points: [StackSnrPlotPoint],
        width: Double,
        height: Double,
        horizontalPadding: Double = 12,
        verticalPadding: Double = 10
    ) -> StackSnrPlotGeometry {
        var byDepth: [UInt32: StackSnrPlotPoint] = [:]
        for point in points where point.frames > 0 && point.snr.isFinite && point.snr > 0 {
            byDepth[point.frames] = point
        }
        let ordered = byDepth.values.sorted { $0.frames < $1.frames }
        guard let first = ordered.first, let last = ordered.last,
            width.isFinite, height.isFinite,
            width > horizontalPadding * 2, height > verticalPadding * 2
        else { return .empty }

        let ideal = ordered.map { point in
            first.snr * (Double(point.frames) / Double(first.frames)).squareRoot()
        }
        let allValues = ordered.map(\.snr) + ideal
        let minSnr = log(allValues.min() ?? 1)
        let maxSnr = log(allValues.max() ?? 1)
        let minFrames = log(Double(first.frames))
        let maxFrames = log(Double(last.frames))
        let frameSpan = max(maxFrames - minFrames, 1e-9)
        let snrSpan = max(maxSnr - minSnr, 1e-9)
        let plotWidth = width - horizontalPadding * 2
        let plotHeight = height - verticalPadding * 2

        func position(frames: UInt32, value: Double) -> CGPoint {
            let x = horizontalPadding + (log(Double(frames)) - minFrames) / frameSpan * plotWidth
            let y = verticalPadding + plotHeight - (log(value) - minSnr) / snrSpan * plotHeight
            return CGPoint(x: x, y: y)
        }

        return StackSnrPlotGeometry(
            measured: ordered.map { position(frames: $0.frames, value: $0.snr) },
            ideal: zip(ordered, ideal).map { position(frames: $0.frames, value: $1) },
            minimumFrames: first.frames,
            maximumFrames: last.frames)
    }
}
