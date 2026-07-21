import CoreGraphics
import Foundation

struct RenderedImage {
    let image: CGImage
    let metadata: ImageMetadata
}

struct ImageMetadata: Decodable {
    let width: Int
    let height: Int
    let planes: Int
    let format: String
    let colorKind: String
    let statistics: ImageStatistics
    let headers: [String: JSONValue]
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
    let name: String
    let commonName: String
    let kind: String
    let source: String
    let x: Double
    let y: Double
    let semiMajorPixels: Double
    let semiMinorPixels: Double
    let angleDegrees: Double?
    let prominence: Double?
    let outlines: [SolveObjectOutline]

    var displayName: String {
        commonName.isEmpty || commonName == name ? name : "\(name) · \(commonName)"
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

    static func render(
        url: URL,
        targetMedian: Double = 0.2,
        shadowsClip: Double = -2.8,
        maxDimension: UInt32 = 0
    ) throws -> RenderedImage {
        var errorPointer: UnsafeMutablePointer<CChar>?
        let handle = url.path.withCString { path in
            seiza_rendered_image_open(
                path,
                targetMedian,
                shadowsClip,
                maxDimension,
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
