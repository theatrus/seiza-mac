import CoreGraphics
import Foundation

struct RenderedImage {
    let image: CGImage
    let metadata: ImageMetadata
}

struct CatalogComponentStatus: Decodable, Equatable {
    let available: Bool
    let path: String?
}

struct CatalogStatus: Decodable, Equatable {
    let directory: String
    let readyForSolving: Bool
    let readyForOverlays: Bool
    let starCatalog: CatalogComponentStatus
    let blindIndex: CatalogComponentStatus
    let objects: CatalogComponentStatus
    let transients: CatalogComponentStatus
    let minorBodies: CatalogComponentStatus
}

enum CatalogSetupPreset: UInt32, CaseIterable, Identifiable {
    case standardBlind = 0
    case deepestBlind = 1
    case all = 2

    var id: Self { self }

    var title: String {
        switch self {
        case .standardBlind: "Standard blind solving"
        case .deepestBlind: "Deepest blind solving"
        case .all: "Everything"
        }
    }

    var detail: String {
        switch self {
        case .standardBlind:
            "Recommended. G≤17 Gaia stars, blind index, named stars, deep-sky objects, transients, and Solar System bodies."
        case .deepestBlind:
            "For the faintest crowded fields. Replaces the standard star catalog with the optional G≤20 catalog (about 9 GB larger)."
        case .all:
            "Every published solver and overlay catalog, including both standard and G≤20 data. Intended for development and offline use."
        }
    }
}

struct CatalogSetupProgress: Decodable, Equatable {
    enum Phase: String, Decodable {
        case preparing
        case manifest
        case downloading
        case verifying
        case installing
        case complete
    }

    let phase: Phase
    let message: String
    let fileName: String?
    let filesCompleted: Int
    let filesTotal: Int
    let bytesCompleted: UInt64?
    let bytesTotal: UInt64?
    let writtenBytes: UInt64?

    var fractionCompleted: Double? {
        guard let bytesCompleted, let bytesTotal, bytesTotal > 0 else { return nil }
        return min(max(Double(bytesCompleted) / Double(bytesTotal), 0), 1)
    }
}

private final class CatalogSetupProgressSink {
    let handler: (CatalogSetupProgress) -> Void

    init(handler: @escaping (CatalogSetupProgress) -> Void) {
        self.handler = handler
    }
}

private let catalogSetupProgressCallback: @convention(c) (
    UnsafePointer<CChar>?,
    UnsafeMutableRawPointer?
) -> Void = { jsonPointer, context in
    guard let jsonPointer, let context else { return }
    let data = Data(bytes: jsonPointer, count: strlen(jsonPointer))
    guard let progress = try? JSONDecoder().decode(CatalogSetupProgress.self, from: data) else {
        return
    }
    let sink = Unmanaged<CatalogSetupProgressSink>.fromOpaque(context).takeUnretainedValue()
    sink.handler(progress)
}

struct ImageMetadata: Decodable {
    let width: Int
    let height: Int
    let planes: Int
    let format: String
    let colorKind: String
    let rgbStretchMode: String?
    let stretchStages: Int?
    let statistics: ImageStatistics
    let inputHistogram: ImageHistogram?
    let displayHistogram: ImageHistogram?
    let headers: [String: JSONValue]
}

struct ImageHistogram: Decodable, Equatable {
    static let binCount = 256

    let red: [UInt64]
    let green: [UInt64]
    let blue: [UInt64]
    let lowerBound: Double
    let upperBound: Double

    var isValid: Bool {
        red.count == Self.binCount
            && green.count == Self.binCount
            && blue.count == Self.binCount
            && lowerBound.isFinite
            && upperBound.isFinite
            && upperBound > lowerBound
    }
}

enum FITSStretchType: String, CaseIterable, Identifiable {
    case autoMtf
    case percentileAsinh
    case linear
    case asinh
    case mtf
    case ghs
    case identity

    var id: Self { self }

    static let automatic: [Self] = [.autoMtf, .percentileAsinh]
    static let manual: [Self] = [.linear, .asinh, .mtf, .ghs]
    static let utility: [Self] = [.identity]

    var title: String {
        switch self {
        case .autoMtf: "Auto MTF"
        case .percentileAsinh: "Percentile Asinh"
        case .linear: "Linear"
        case .asinh: "Asinh"
        case .mtf: "Midtones Transfer"
        case .ghs: "Generalized Hyperbolic"
        case .identity: "No Stretch"
        }
    }

    var help: String {
        switch self {
        case .autoMtf:
            "Choose an MTF curve from the image median and median absolute deviation."
        case .percentileAsinh:
            "Choose black and white points from image percentiles, then apply an asinh curve."
        case .linear:
            "Map explicit black and white points linearly to the display range."
        case .asinh:
            "Apply an asinh curve between explicit black and white points."
        case .mtf:
            "Apply explicit shadows, midtone, and highlights parameters."
        case .ghs:
            "Apply a manual Generalized Hyperbolic Stretch with protection boundaries."
        case .identity:
            "Clamp normalized astronomy samples to the display range without a stretch curve."
        }
    }
}

enum FITSStretchColorStrategy: String, CaseIterable, Identifiable, Codable {
    case linked
    case unlinked
    case luminancePreserving = "luminance-preserving"

    var id: Self { self }

    var title: String {
        switch self {
        case .linked: "Linked Channels"
        case .unlinked: "Per Channel"
        case .luminancePreserving: "Preserve Luminance Color"
        }
    }

    var help: String {
        switch self {
        case .linked:
            "Analyze all channels together and apply one shared curve."
        case .unlinked:
            "Analyze and stretch each color channel independently."
        case .luminancePreserving:
            "Stretch Rec. 709 luminance while retaining RGB chromaticity."
        }
    }
}

struct FITSStretchConfiguration: Equatable, Codable {
    static let `default` = Self()

    init() {}

    static var identity: Self {
        var configuration = Self.default
        configuration.type = .identity
        return configuration
    }

    var type: FITSStretchType = .autoMtf
    var colorStrategy: FITSStretchColorStrategy = .unlinked
    var maxAnalysisSamples = 200_000

    var targetMedian = 0.2
    var shadowsClip = -2.8

    var blackPercentile = 0.01
    var whitePercentile = 0.995
    var strength = 10.0

    var black = 0.0
    var white = 1.0

    var shadows = 0.0
    var midtone = 0.25
    var highlights = 1.0

    var stretchFactor = 1.0
    var localIntensity = 0.0
    var symmetryPoint = 0.0
    var protectShadows = 0.0
    var protectHighlights = 1.0

    var validationMessage: String? {
        let finiteValues = [
            targetMedian, shadowsClip, blackPercentile, whitePercentile,
            strength, black, white, shadows, midtone, highlights,
            stretchFactor, localIntensity, symmetryPoint, protectShadows,
            protectHighlights,
        ]
        guard finiteValues.allSatisfy(\.isFinite) else {
            return "Stretch parameters must be finite numbers."
        }
        guard maxAnalysisSamples > 0 else {
            return "Analysis samples must be greater than zero."
        }

        switch type {
        case .autoMtf:
            guard (0.0..<1.0).contains(targetMedian) else {
                return "Target median must be between 0 and 1."
            }
            guard shadowsClip <= 0 else {
                return "Shadows clipping must be zero or negative."
            }
        case .percentileAsinh:
            guard (0.0...1.0).contains(blackPercentile),
                  (0.0...1.0).contains(whitePercentile),
                  whitePercentile > blackPercentile else {
                return "White percentile must be greater than black percentile."
            }
            guard strength > 0 else { return "Asinh strength must be greater than zero." }
        case .linear:
            guard white > black else { return "White point must be greater than black point." }
        case .asinh:
            guard white > black else { return "White point must be greater than black point." }
            guard strength > 0 else { return "Asinh strength must be greater than zero." }
        case .mtf:
            guard highlights > shadows else {
                return "Highlights must be greater than shadows."
            }
            guard (0.0..<1.0).contains(midtone), midtone > 0 else {
                return "Midtone must be between 0 and 1."
            }
        case .ghs:
            guard white > black else { return "White point must be greater than black point." }
            guard (0.0...20.0).contains(stretchFactor),
                  (-5.0...15.0).contains(localIntensity),
                  (0.0...1.0).contains(symmetryPoint),
                  (0.0...symmetryPoint).contains(protectShadows),
                  (symmetryPoint...1.0).contains(protectHighlights) else {
                return "GHS requires 0 ≤ shadow protection ≤ symmetry ≤ highlight protection ≤ 1."
            }
        case .identity:
            break
        }
        return nil
    }

    var jsonData: Data {
        get throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(self)
        }
    }

    var cacheIdentifier: String {
        guard let data = try? jsonData else { return "invalid-stretch-config" }
        return String(decoding: data, as: UTF8.self)
    }

    private enum CodingKeys: String, CodingKey {
        case model
        case colorStrategy = "color_strategy"
        case maxAnalysisSamples = "max_analysis_samples"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(StretchModelPayload(configuration: self), forKey: .model)
        try container.encode(colorStrategy, forKey: .colorStrategy)
        try container.encode(maxAnalysisSamples, forKey: .maxAnalysisSamples)
    }

    init(from decoder: Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        colorStrategy = try container.decodeIfPresent(
            FITSStretchColorStrategy.self,
            forKey: .colorStrategy
        ) ?? colorStrategy
        maxAnalysisSamples = try container.decodeIfPresent(
            Int.self,
            forKey: .maxAnalysisSamples
        ) ?? maxAnalysisSamples

        let model = try container.decode(StretchModelDecodingPayload.self, forKey: .model)
        switch model.type {
        case "auto-mtf":
            type = .autoMtf
            targetMedian = try model.required(model.targetMedian, named: "target_median")
            shadowsClip = try model.required(model.shadowsClip, named: "shadows_clip")
        case "percentile-asinh":
            type = .percentileAsinh
            blackPercentile = try model.required(
                model.blackPercentile,
                named: "black_percentile"
            )
            whitePercentile = try model.required(
                model.whitePercentile,
                named: "white_percentile"
            )
            strength = try model.required(model.strength, named: "strength")
        case "linear":
            type = .linear
            black = try model.required(model.black, named: "black")
            white = try model.required(model.white, named: "white")
        case "asinh":
            type = .asinh
            black = try model.required(model.black, named: "black")
            white = try model.required(model.white, named: "white")
            strength = try model.required(model.strength, named: "strength")
        case "mtf":
            type = .mtf
            shadows = try model.required(model.shadows, named: "shadows")
            midtone = try model.required(model.midtone, named: "midtone")
            highlights = try model.required(model.highlights, named: "highlights")
        case "ghs":
            type = .ghs
            stretchFactor = try model.required(model.stretchFactor, named: "stretch_factor")
            localIntensity = try model.required(model.localIntensity, named: "local_intensity")
            symmetryPoint = try model.required(model.symmetryPoint, named: "symmetry_point")
            protectShadows = try model.required(model.protectShadows, named: "protect_shadows")
            protectHighlights = try model.required(
                model.protectHighlights,
                named: "protect_highlights"
            )
            black = try model.required(model.black, named: "black")
            white = try model.required(model.white, named: "white")
        case "identity":
            type = .identity
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .model,
                in: container,
                debugDescription: "Unknown stretch model \(model.type)."
            )
        }

        if let validationMessage {
            throw DecodingError.dataCorruptedError(
                forKey: .model,
                in: container,
                debugDescription: validationMessage
            )
        }
    }
}

struct FITSStretchStack: Equatable, Encodable {
    static let `default` = Self(stages: [.default])

    let stages: [FITSStretchConfiguration]

    init(stages: [FITSStretchConfiguration]) {
        precondition(!stages.isEmpty, "A stretch stack must contain at least one stage")
        self.stages = stages
    }

    var jsonData: Data {
        get throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(stages)
        }
    }

    var cacheIdentifier: String {
        guard let data = try? jsonData else { return "invalid-stretch-stack" }
        return String(decoding: data, as: UTF8.self)
    }
}

struct FITSDeconvolutionConfiguration: Equatable, Codable {
    static let `default` = Self()

    var psfFWHMPixels = 3.0
    var iterations = 4
    var amount = 0.35
    var noiseFraction = 0.001
    var maxCorrection = 2.0

    var validationMessage: String? {
        let finiteValues = [psfFWHMPixels, amount, noiseFraction, maxCorrection]
        guard finiteValues.allSatisfy(\.isFinite) else {
            return "Deconvolution parameters must be finite numbers."
        }
        guard (0.25...100.0).contains(psfFWHMPixels) else {
            return "PSF FWHM must be between 0.25 and 100 pixels."
        }
        guard (1...50).contains(iterations) else {
            return "Iterations must be between 1 and 50."
        }
        guard (0.0...1.0).contains(amount) else {
            return "Amount must be between 0 and 1."
        }
        guard (0.0...0.25).contains(noiseFraction) else {
            return "Noise damping must be between 0 and 0.25."
        }
        guard (1.0...100.0).contains(maxCorrection) else {
            return "Correction limit must be between 1 and 100."
        }
        return nil
    }

    private enum CodingKeys: String, CodingKey {
        case psfFWHMPixels = "psf_fwhm_pixels"
        case iterations
        case amount
        case noiseFraction = "noise_fraction"
        case maxCorrection = "max_correction"
    }
}

struct FITSImageProcessingConfiguration: Equatable, Codable {
    static let `default` = Self(
        stretchStack: .default,
        extractsBackground: false,
        deconvolution: nil
    )

    let stretchStack: FITSStretchStack
    let extractsBackground: Bool
    let deconvolution: FITSDeconvolutionConfiguration?
    let interactivePreview: Bool

    init(
        stretchStack: FITSStretchStack,
        extractsBackground: Bool,
        deconvolution: FITSDeconvolutionConfiguration? = nil,
        interactivePreview: Bool = false
    ) {
        self.stretchStack = stretchStack
        self.extractsBackground = extractsBackground
        self.deconvolution = deconvolution
        self.interactivePreview = interactivePreview
    }

    var jsonData: Data {
        get throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(self)
        }
    }

    var cacheIdentifier: String {
        guard let data = try? jsonData else { return "invalid-processing-config" }
        return String(decoding: data, as: UTF8.self)
    }

    private enum CodingKeys: String, CodingKey {
        case stretch
        case background
        case deconvolution
        case interactivePreview = "interactive_preview"
    }

    private struct BackgroundPayload: Codable {
        let mode: String

        init(mode: String = "subtract") {
            self.mode = mode
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(stretchStack.stages, forKey: .stretch)
        if extractsBackground {
            try container.encode(BackgroundPayload(), forKey: .background)
        }
        if let deconvolution {
            try container.encode(deconvolution, forKey: .deconvolution)
        }
        if interactivePreview {
            try container.encode(true, forKey: .interactivePreview)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let stages = try container.decode(
            [FITSStretchConfiguration].self,
            forKey: .stretch
        )
        guard !stages.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .stretch,
                in: container,
                debugDescription: "A processing recipe needs at least one stretch stage."
            )
        }
        let background = try container.decodeIfPresent(
            BackgroundPayload.self,
            forKey: .background
        )
        if let background, background.mode != "subtract" {
            throw DecodingError.dataCorruptedError(
                forKey: .background,
                in: container,
                debugDescription: "Unknown background operation \(background.mode)."
            )
        }
        self.init(
            stretchStack: FITSStretchStack(stages: stages),
            extractsBackground: background != nil,
            deconvolution: try container.decodeIfPresent(
                FITSDeconvolutionConfiguration.self,
                forKey: .deconvolution
            ),
            interactivePreview: try container.decodeIfPresent(
                Bool.self,
                forKey: .interactivePreview
            ) ?? false
        )
        if let validationMessage = deconvolution?.validationMessage {
            throw DecodingError.dataCorruptedError(
                forKey: .deconvolution,
                in: container,
                debugDescription: validationMessage
            )
        }
    }
}

struct FITSStretchHistory: Equatable {
    private(set) var appliedStages: [FITSStretchConfiguration]
    private var undoStacks: [[FITSStretchConfiguration]] = []
    private var redoStacks: [[FITSStretchConfiguration]] = []

    init(base: FITSStretchConfiguration = .default) {
        appliedStages = [base]
    }

    init(stack: FITSStretchStack) {
        precondition(!stack.stages.isEmpty)
        precondition(stack.stages.allSatisfy { $0.validationMessage == nil })
        appliedStages = stack.stages
    }

    var stack: FITSStretchStack { FITSStretchStack(stages: appliedStages) }
    var current: FITSStretchConfiguration { appliedStages[appliedStages.count - 1] }
    var canUndo: Bool { !undoStacks.isEmpty }
    var canRedo: Bool { !redoStacks.isEmpty }

    mutating func apply(_ configuration: FITSStretchConfiguration) {
        precondition(configuration.validationMessage == nil)
        undoStacks.append(appliedStages)
        appliedStages.append(configuration)
        redoStacks.removeAll()
    }

    mutating func updateCurrent(_ configuration: FITSStretchConfiguration) {
        precondition(configuration.validationMessage == nil)
        undoStacks.append(appliedStages)
        appliedStages[appliedStages.count - 1] = configuration
        redoStacks.removeAll()
    }

    mutating func replace(with configuration: FITSStretchConfiguration) {
        precondition(configuration.validationMessage == nil)
        undoStacks.append(appliedStages)
        appliedStages = [configuration]
        redoStacks.removeAll()
    }

    mutating func replaceStack(with stages: [FITSStretchConfiguration]) {
        precondition(!stages.isEmpty)
        precondition(stages.allSatisfy { $0.validationMessage == nil })
        guard stages != appliedStages else { return }
        undoStacks.append(appliedStages)
        appliedStages = stages
        redoStacks.removeAll()
    }

    @discardableResult
    mutating func undo() -> Bool {
        guard let previous = undoStacks.popLast() else { return false }
        redoStacks.append(appliedStages)
        appliedStages = previous
        return true
    }

    @discardableResult
    mutating func redo() -> Bool {
        guard let next = redoStacks.popLast() else { return false }
        undoStacks.append(appliedStages)
        appliedStages = next
        return true
    }
}

private struct StretchModelPayload: Encodable {
    let configuration: FITSStretchConfiguration

    private enum CodingKeys: String, CodingKey {
        case type
        case targetMedian = "target_median"
        case shadowsClip = "shadows_clip"
        case blackPercentile = "black_percentile"
        case whitePercentile = "white_percentile"
        case strength
        case black
        case white
        case shadows
        case midtone
        case highlights
        case stretchFactor = "stretch_factor"
        case localIntensity = "local_intensity"
        case symmetryPoint = "symmetry_point"
        case protectShadows = "protect_shadows"
        case protectHighlights = "protect_highlights"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        let configuration = configuration
        switch configuration.type {
        case .autoMtf:
            try container.encode("auto-mtf", forKey: .type)
            try container.encode(configuration.targetMedian, forKey: .targetMedian)
            try container.encode(configuration.shadowsClip, forKey: .shadowsClip)
        case .percentileAsinh:
            try container.encode("percentile-asinh", forKey: .type)
            try container.encode(configuration.blackPercentile, forKey: .blackPercentile)
            try container.encode(configuration.whitePercentile, forKey: .whitePercentile)
            try container.encode(configuration.strength, forKey: .strength)
        case .linear:
            try container.encode("linear", forKey: .type)
            try container.encode(configuration.black, forKey: .black)
            try container.encode(configuration.white, forKey: .white)
        case .asinh:
            try container.encode("asinh", forKey: .type)
            try container.encode(configuration.black, forKey: .black)
            try container.encode(configuration.white, forKey: .white)
            try container.encode(configuration.strength, forKey: .strength)
        case .mtf:
            try container.encode("mtf", forKey: .type)
            try container.encode(configuration.shadows, forKey: .shadows)
            try container.encode(configuration.midtone, forKey: .midtone)
            try container.encode(configuration.highlights, forKey: .highlights)
        case .ghs:
            try container.encode("ghs", forKey: .type)
            try container.encode(configuration.stretchFactor, forKey: .stretchFactor)
            try container.encode(configuration.localIntensity, forKey: .localIntensity)
            try container.encode(configuration.symmetryPoint, forKey: .symmetryPoint)
            try container.encode(configuration.protectShadows, forKey: .protectShadows)
            try container.encode(configuration.protectHighlights, forKey: .protectHighlights)
            try container.encode(configuration.black, forKey: .black)
            try container.encode(configuration.white, forKey: .white)
        case .identity:
            try container.encode("identity", forKey: .type)
        }
    }
}

private struct StretchModelDecodingPayload: Decodable {
    let type: String
    let targetMedian: Double?
    let shadowsClip: Double?
    let blackPercentile: Double?
    let whitePercentile: Double?
    let strength: Double?
    let black: Double?
    let white: Double?
    let shadows: Double?
    let midtone: Double?
    let highlights: Double?
    let stretchFactor: Double?
    let localIntensity: Double?
    let symmetryPoint: Double?
    let protectShadows: Double?
    let protectHighlights: Double?

    private enum CodingKeys: String, CodingKey {
        case type
        case targetMedian = "target_median"
        case shadowsClip = "shadows_clip"
        case blackPercentile = "black_percentile"
        case whitePercentile = "white_percentile"
        case strength
        case black
        case white
        case shadows
        case midtone
        case highlights
        case stretchFactor = "stretch_factor"
        case localIntensity = "local_intensity"
        case symmetryPoint = "symmetry_point"
        case protectShadows = "protect_shadows"
        case protectHighlights = "protect_highlights"
    }

    func required(_ value: Double?, named name: String) throws -> Double {
        guard let value else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: [],
                    debugDescription: "Stretch model is missing \(name)."
                )
            )
        }
        return value
    }
}

struct ImageStatistics: Decodable {
    let minimum: Int
    let maximum: Int
    let mean: Double
    let median: Int
    let mad: Double
}

struct SolveResult: Decodable {
    let centerRaDegrees: Double
    let centerDecDegrees: Double
    let scaleArcsecPerPixel: Double
    let matchedStars: Int
    let rmsArcsec: Double
    let detectedStars: Int
    let elapsedMilliseconds: Int
    let detectedStarPositions: [SolveImagePoint]
    let catalogStarPositions: [SolveCatalogStarPoint]
    let objectPositions: [SolveObjectPoint]
    let objectCatalogError: String?
    let captureTime: String?
    let overlayAvailability: [String: Bool]?
    let overlayUnavailableReasons: [String: String]?
    let overlayCounts: [String: Int]?
    let wcs: WCSResult
}

struct SolveImagePoint: Decodable {
    let x: Double
    let y: Double
}

struct SolveCatalogStarPoint: Decodable {
    let x: Double
    let y: Double
    let magnitude: Double
}

struct SolveObjectPoint: Decodable {
    let stableId: String?
    let name: String
    let commonName: String
    let kind: String
    let source: String
    let catalogSource: String?
    let x: Double
    let y: Double
    let semiMajorPixels: Double
    let semiMinorPixels: Double
    let angleDegrees: Double?
    let prominence: Double?
    let raDegrees: Double?
    let decDegrees: Double?
    let discovered: String?
    let nearCapture: Bool?
    let distanceAu: Double?
    let motionArcsecPerHour: Double?
    let directionPositionAngleDegrees: Double?
    let directionImageAngleDegrees: Double?
    let outlines: [SolveObjectOutline]

    var displayName: String {
        commonName.isEmpty || commonName == name ? name : "\(name) · \(commonName)"
    }

    var deepSkyCatalog: DeepSkyCatalog? {
        DeepSkyCatalog.classify(name: name, kind: kind)
    }
}

enum DeepSkyCatalog: String, CaseIterable, Identifiable {
    case messier
    case ngc
    case ic
    case sharplessVDB = "sharpless-vdb"
    case lbn
    case cederblad
    case darkNebulae = "dark-nebulae"
    case supernovaRemnants = "snr"
    case ugc
    case pgc
    case other = "other-deep-sky"

    var id: Self { self }

    var title: String {
        switch self {
        case .messier: "Messier"
        case .ngc: "NGC"
        case .ic: "IC"
        case .sharplessVDB: "Sharpless / vdB"
        case .lbn: "LBN (bright nebulae)"
        case .cederblad: "Cederblad"
        case .darkNebulae: "Dark nebulae (B / LDN)"
        case .supernovaRemnants: "Supernova remnants"
        case .ugc: "UGC galaxies"
        case .pgc: "PGC galaxies"
        case .other: "Other / default catalogs"
        }
    }

    static func classify(name: String, kind: String) -> DeepSkyCatalog? {
        if [
            "star", "double-star", "identified-star", "field-star",
            "transient", "comet", "asteroid", "satellite",
        ].contains(kind) {
            return nil
        }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if matches("^PGC(?:\\s|$)", name) { return .pgc }
        if matches("^UGC(?:\\s|$)", name) { return .ugc }
        if matches("^LBN(?:\\s|$)", name) { return .lbn }
        if matches("^(?:Ced|Cederblad)(?:\\s|$)", name) { return .cederblad }
        if matches("^(?:LDN(?:\\s|$)|B\\s*\\d)", name) { return .darkNebulae }
        if matches("^SNR(?:\\s|$)", name) { return .supernovaRemnants }
        if matches("^(?:Sh\\s*2[- ]|vdB(?:\\s|$))", name) { return .sharplessVDB }
        if matches("^M\\s*\\d", name) { return .messier }
        if matches("^NGC\\s*\\d", name) { return .ngc }
        if matches("^IC\\s*\\d", name) { return .ic }
        return .other
    }

    private static func matches(_ pattern: String, _ value: String) -> Bool {
        value.range(
            of: pattern,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }
}

struct SolveObjectOutline: Decodable {
    let geometryId: String
    let sourceRecordId: String
    let role: String
    let quality: String
    let level: String?
    let contours: [SolveObjectContour]
}

struct SolveObjectContour: Decodable {
    let closed: Bool
    let points: [[Double]]
}

struct WCSResult: Decodable {
    let crval: [Double]
    let crpix: [Double]
    let cd: [[Double]]
    let sip: SIPResult?
}

struct SIPResult: Decodable {
    let order: Int
    let a: [Double]
    let b: [Double]
    let ap: [Double]
    let bp: [Double]
}

enum JSONValue: Decodable, CustomStringConvertible {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    var description: String {
        switch self {
        case .string(let value): value
        case .number(let value): value.formatted(.number.precision(.significantDigits(8)))
        case .bool(let value): value ? "T" : "F"
        case .null: ""
        }
    }
}

enum SeizaCoreError: LocalizedError {
    case message(String)
    case invalidCABIResponse

    var errorDescription: String? {
        switch self {
        case .message(let message): message
        case .invalidCABIResponse: "The Seiza C ABI returned an invalid response."
        }
    }
}

enum SeizaCore {
    private static let astronomyImageExtensions: Set<String> = [
        "fits", "fit", "fts", "xisf",
    ]

    static var version: String {
        guard let pointer = seiza_core_version() else { return "unknown" }
        return String(cString: pointer)
    }

    static var gitCommit: String {
        guard let pointer = seiza_mac_core_git_commit() else { return "unknown" }
        return String(cString: pointer)
    }

    static func catalogStatus(catalogDirectory: URL?) throws -> CatalogStatus {
        var errorPointer: UnsafeMutablePointer<CChar>?
        let resultPointer: UnsafeMutablePointer<CChar>? = if let catalogDirectory {
            catalogDirectory.path.withCString { path in
                seiza_catalog_status_json(path, &errorPointer)
            }
        } else {
            seiza_catalog_status_json(nil, &errorPointer)
        }
        guard let resultPointer else { throw cabiError(&errorPointer) }
        defer { seiza_string_free(resultPointer) }
        let data = Data(bytes: resultPointer, count: strlen(resultPointer))
        return try JSONDecoder().decode(CatalogStatus.self, from: data)
    }

    static func setupCatalogs(
        catalogDirectory: URL?,
        preset: CatalogSetupPreset,
        onProgress: @escaping (CatalogSetupProgress) -> Void
    ) throws {
        let sink = Unmanaged.passRetained(CatalogSetupProgressSink(handler: onProgress))
        defer { sink.release() }
        var errorPointer: UnsafeMutablePointer<CChar>?
        let succeeded: Bool = if let catalogDirectory {
            catalogDirectory.path.withCString { path in
                seiza_catalog_setup(
                    path,
                    preset.rawValue,
                    catalogSetupProgressCallback,
                    sink.toOpaque(),
                    &errorPointer
                )
            }
        } else {
            seiza_catalog_setup(
                nil,
                preset.rawValue,
                catalogSetupProgressCallback,
                sink.toOpaque(),
                &errorPointer
            )
        }
        guard succeeded else { throw cabiError(&errorPointer) }
    }

    static func render(
        url: URL,
        maxDimension: UInt32 = 0,
        processing: FITSImageProcessingConfiguration = .default
    ) throws -> RenderedImage {
        var errorPointer: UnsafeMutablePointer<CChar>?
        let extensionName = url.pathExtension.lowercased()
        let usesAstronomyPipeline = astronomyImageExtensions.contains(extensionName)
        let handle: OpaquePointer?
        if usesAstronomyPipeline {
            let configurationJSON = String(
                decoding: try processing.jsonData,
                as: UTF8.self
            )
            handle = url.path.withCString { path in
                configurationJSON.withCString { configuration in
                    seiza_rendered_image_open_with_stretch_config(
                        path,
                        configuration,
                        maxDimension,
                        &errorPointer
                    )
                }
            }
        } else {
            handle = url.path.withCString { path in
                seiza_rendered_image_open(
                    path,
                    0.2,
                    -2.8,
                    maxDimension,
                    &errorPointer
                )
            }
        }
        guard let handle else { throw cabiError(&errorPointer) }
        defer { seiza_rendered_image_free(handle) }

        let width = Int(seiza_rendered_image_width(handle))
        let height = Int(seiza_rendered_image_height(handle))
        let byteCount = seiza_rendered_image_rgba_length(handle)
        guard
            width > 0,
            height > 0,
            byteCount == width * height * 4,
            let bytes = seiza_rendered_image_rgba(handle),
            let metadataBytes = seiza_rendered_image_metadata_json(handle)
        else {
            throw SeizaCoreError.invalidCABIResponse
        }

        let data = Data(bytes: bytes, count: byteCount)
        guard
            let provider = CGDataProvider(data: data as CFData),
            let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )
        else {
            throw SeizaCoreError.invalidCABIResponse
        }
        let metadataData = Data(bytes: metadataBytes, count: strlen(metadataBytes))
        let metadata = try JSONDecoder().decode(ImageMetadata.self, from: metadataData)
        return RenderedImage(image: image, metadata: metadata)
    }

    /// Renders directly into native-endian RGBA16 for high-bit-depth export.
    /// Display and thumbnail callers continue to use `render`, so they do not
    /// allocate this larger buffer.
    static func render16(
        url: URL,
        maxDimension: UInt32 = 0,
        processing: FITSImageProcessingConfiguration = .default
    ) throws -> RenderedImage {
        var errorPointer: UnsafeMutablePointer<CChar>?
        let extensionName = url.pathExtension.lowercased()
        let usesAstronomyPipeline = astronomyImageExtensions.contains(extensionName)
        let handle: OpaquePointer?
        if usesAstronomyPipeline {
            let configurationJSON = String(
                decoding: try processing.jsonData,
                as: UTF8.self
            )
            handle = url.path.withCString { path in
                configurationJSON.withCString { configuration in
                    seiza_rendered_image16_open_with_stretch_config(
                        path,
                        configuration,
                        maxDimension,
                        &errorPointer
                    )
                }
            }
        } else {
            handle = url.path.withCString { path in
                seiza_rendered_image16_open(
                    path,
                    0.2,
                    -2.8,
                    maxDimension,
                    &errorPointer
                )
            }
        }
        guard let handle else { throw cabiError(&errorPointer) }
        defer { seiza_rendered_image16_free(handle) }

        let width = Int(seiza_rendered_image16_width(handle))
        let height = Int(seiza_rendered_image16_height(handle))
        let elementCount = seiza_rendered_image16_rgba_length(handle)
        let pixelCount = width.multipliedReportingOverflow(by: height)
        let expectedElementCount = pixelCount.partialValue.multipliedReportingOverflow(by: 4)
        let byteCount = elementCount.multipliedReportingOverflow(
            by: MemoryLayout<UInt16>.stride
        )
        guard
            width > 0,
            height > 0,
            !pixelCount.overflow,
            !expectedElementCount.overflow,
            elementCount == expectedElementCount.partialValue,
            !byteCount.overflow,
            let samples = seiza_rendered_image16_rgba(handle),
            let metadataBytes = seiza_rendered_image16_metadata_json(handle)
        else {
            throw SeizaCoreError.invalidCABIResponse
        }

        let data = Data(bytes: samples, count: byteCount.partialValue)
        var bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)
        #if _endian(little)
        bitmapInfo.insert(.byteOrder16Little)
        #else
        bitmapInfo.insert(.byteOrder16Big)
        #endif
        guard
            let provider = CGDataProvider(data: data as CFData),
            let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 16,
                bitsPerPixel: 64,
                bytesPerRow: width * 8,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: bitmapInfo,
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )
        else {
            throw SeizaCoreError.invalidCABIResponse
        }
        let metadataData = Data(bytes: metadataBytes, count: strlen(metadataBytes))
        let metadata = try JSONDecoder().decode(ImageMetadata.self, from: metadataData)
        return RenderedImage(image: image, metadata: metadata)
    }

    static func solve(
        url: URL,
        catalogDirectory: URL?,
        minimumScale: Double = 0.1,
        maximumScale: Double = 20,
        sipOrder: UInt8 = 0
    ) throws -> SolveResult {
        var errorPointer: UnsafeMutablePointer<CChar>?
        let resultPointer: UnsafeMutablePointer<CChar>? = url.path.withCString { path in
            if let catalogDirectory {
                return catalogDirectory.path.withCString { catalogPath in
                    seiza_solve_image_json(
                        path,
                        catalogPath,
                        minimumScale,
                        maximumScale,
                        sipOrder,
                        &errorPointer
                    )
                }
            }
            return seiza_solve_image_json(
                path,
                nil,
                minimumScale,
                maximumScale,
                sipOrder,
                &errorPointer
            )
        }
        guard let resultPointer else { throw cabiError(&errorPointer) }
        defer { seiza_string_free(resultPointer) }
        let data = Data(bytes: resultPointer, count: strlen(resultPointer))
        return try JSONDecoder().decode(SolveResult.self, from: data)
    }

    private static func cabiError(
        _ pointer: inout UnsafeMutablePointer<CChar>?
    ) -> SeizaCoreError {
        guard let value = pointer else { return .invalidCABIResponse }
        pointer = nil
        let message = String(cString: value)
        seiza_string_free(value)
        return .message(message)
    }
}
