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

enum RGBStretchMode: UInt32, CaseIterable, Identifiable {
    case auto = 0
    case linkedAuto = 1
    case linear = 2

    var id: Self { self }

    var title: String {
        switch self {
        case .auto: "Auto"
        case .linkedAuto: "Linked Auto"
        case .linear: "Linear"
        }
    }

    var help: String {
        switch self {
        case .auto: "Stretch each RGB channel independently."
        case .linkedAuto: "Use one shared automatic stretch for all RGB channels."
        case .linear: "Map the native 16-bit RGB range directly to the display."
        }
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
        targetMedian: Double = 0.2,
        shadowsClip: Double = -2.8,
        maxDimension: UInt32 = 0,
        rgbStretchMode: RGBStretchMode = .auto
    ) throws -> RenderedImage {
        var errorPointer: UnsafeMutablePointer<CChar>?
        let handle = url.path.withCString { path in
            seiza_rendered_image_open_with_rgb_stretch(
                path,
                targetMedian,
                shadowsClip,
                maxDimension,
                rgbStretchMode.rawValue,
                &errorPointer
            )
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
