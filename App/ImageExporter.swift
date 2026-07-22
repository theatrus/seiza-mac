import AppKit
import Combine
import CoreGraphics
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

enum ImageExportFormat: String, CaseIterable, Identifiable {
    case png
    case jpeg
    case tiff

    var id: Self { self }

    var title: String {
        switch self {
        case .png: "PNG"
        case .jpeg: "JPEG"
        case .tiff: "TIFF"
        }
    }

    var contentType: UTType {
        switch self {
        case .png: .png
        case .jpeg: .jpeg
        case .tiff: .tiff
        }
    }

    var fileExtension: String {
        switch self {
        case .png: "png"
        case .jpeg: "jpg"
        case .tiff: "tiff"
        }
    }

    var supportedBitDepths: [ImageExportBitDepth] {
        switch self {
        case .png, .tiff: [.sixteen, .eight]
        case .jpeg: [.eight]
        }
    }
}

enum ImageExportBitDepth: Int, CaseIterable, Identifiable {
    case eight = 8
    case sixteen = 16

    var id: Self { self }
    var title: String { "\(rawValue) bits per channel" }
}

final class ImageExportCoordinator: ObservableObject {
    @Published private(set) var requestNumber = 0
    @Published private(set) var copyRequestNumber = 0

    func requestExport() {
        requestNumber &+= 1
    }

    func requestCopy() {
        copyRequestNumber &+= 1
    }
}

@MainActor
final class ImageExportOptions: ObservableObject {
    @Published var format: ImageExportFormat = .png {
        didSet {
            if !format.supportedBitDepths.contains(bitDepth) {
                bitDepth = .eight
            }
        }
    }
    @Published var bitDepth: ImageExportBitDepth = .sixteen
    @Published var includesVisibleOverlays: Bool

    init(overlaysAvailable: Bool) {
        includesVisibleOverlays = overlaysAvailable
    }
}

@MainActor
struct ImageExportAccessoryView: View {
    @ObservedObject var options: ImageExportOptions
    let overlaysAvailable: Bool

    var body: some View {
        Form {
            Picker("Format", selection: $options.format) {
                ForEach(ImageExportFormat.allCases) { format in
                    Text(format.title).tag(format)
                }
            }
            .pickerStyle(.menu)

            Picker("Bit Depth", selection: $options.bitDepth) {
                ForEach(options.format.supportedBitDepths) { bitDepth in
                    Text(bitDepth.title).tag(bitDepth)
                }
            }
            .pickerStyle(.menu)
            .disabled(options.format.supportedBitDepths.count == 1)

            Toggle(
                "Include visible overlays",
                isOn: $options.includesVisibleOverlays
            )
            .disabled(!overlaysAvailable)
        }
        .formStyle(.grouped)
        .frame(width: 300)
    }
}

enum ImageExportError: LocalizedError {
    case couldNotCreateDestination
    case couldNotComposite
    case couldNotEncode
    case couldNotCopy

    var errorDescription: String? {
        switch self {
        case .couldNotCreateDestination:
            "The destination could not be prepared for writing."
        case .couldNotComposite:
            "The visible overlays could not be composited at the requested bit depth."
        case .couldNotEncode:
            "ImageIO could not encode the image in the selected format."
        case .couldNotCopy:
            "The full-resolution image could not be placed on the clipboard."
        }
    }
}

enum WCSExportError: LocalizedError {
    case invalidSolution

    var errorDescription: String? {
        switch self {
        case .invalidSolution:
            "The plate solution does not contain a complete WCS record."
        }
    }
}

enum WCSFileWriter {
    private static let cardLength = 80
    private static let blockLength = 2_880

    static func suggestedFilename(for sourceURL: URL) -> String {
        sourceURL.deletingPathExtension().lastPathComponent + ".wcs"
    }

    static func write(_ wcs: WCSResult, to url: URL) throws {
        try data(for: wcs).write(to: url, options: .atomic)
    }

    static func data(for wcs: WCSResult) throws -> Data {
        guard
            wcs.crval.count == 2,
            wcs.crpix.count == 2,
            wcs.cd.count == 2,
            wcs.cd.allSatisfy({ $0.count == 2 }),
            (wcs.crval + wcs.crpix + wcs.cd.flatMap { $0 }).allSatisfy(\.isFinite)
        else {
            throw WCSExportError.invalidSolution
        }

        let projection = wcs.sip == nil ? "TAN" : "TAN-SIP"
        var cards = [
            card("SIMPLE", value: "T"),
            card("BITPIX", value: "8"),
            card("NAXIS", value: "0"),
            card("CTYPE1", value: "'RA---\(projection)'"),
            card("CTYPE2", value: "'DEC--\(projection)'"),
            card("CUNIT1", value: "'deg'"),
            card("CUNIT2", value: "'deg'"),
            card("EQUINOX", number: 2_000),
            card("CRVAL1", number: wcs.crval[0]),
            card("CRVAL2", number: wcs.crval[1]),
            card("CRPIX1", number: wcs.crpix[0] + 1),
            card("CRPIX2", number: wcs.crpix[1] + 1),
            card("CD1_1", number: wcs.cd[0][0]),
            card("CD1_2", number: wcs.cd[0][1]),
            card("CD2_1", number: wcs.cd[1][0]),
            card("CD2_2", number: wcs.cd[1][1]),
        ]

        if let sip = wcs.sip {
            let forwardTerms = terms(order: sip.order, minimumTotal: 2)
            let inverseTerms = terms(order: sip.order, minimumTotal: 0)
            guard
                (2...5).contains(sip.order),
                sip.a.count == forwardTerms.count,
                sip.b.count == forwardTerms.count,
                sip.ap.count == inverseTerms.count,
                sip.bp.count == inverseTerms.count,
                (sip.a + sip.b + sip.ap + sip.bp).allSatisfy(\.isFinite)
            else {
                throw WCSExportError.invalidSolution
            }

            cards.append(card("A_ORDER", value: "\(sip.order)"))
            cards.append(card("B_ORDER", value: "\(sip.order)"))
            appendSIPCards(prefix: "A", terms: forwardTerms, values: sip.a, to: &cards)
            appendSIPCards(prefix: "B", terms: forwardTerms, values: sip.b, to: &cards)
            cards.append(card("AP_ORDER", value: "\(sip.order)"))
            cards.append(card("BP_ORDER", value: "\(sip.order)"))
            appendSIPCards(prefix: "AP", terms: inverseTerms, values: sip.ap, to: &cards)
            appendSIPCards(prefix: "BP", terms: inverseTerms, values: sip.bp, to: &cards)
        }

        cards.append("END".padding(toLength: cardLength, withPad: " ", startingAt: 0))
        var header = cards.joined()
        let paddedLength = ((header.utf8.count + blockLength - 1) / blockLength) * blockLength
        header.append(String(repeating: " ", count: paddedLength - header.utf8.count))
        guard let data = header.data(using: .ascii) else {
            throw WCSExportError.invalidSolution
        }
        return data
    }

    private static func card(_ keyword: String, number: Double) -> String {
        card(
            keyword,
            value: String(
                format: "%.13E",
                locale: Locale(identifier: "en_US_POSIX"),
                arguments: [number]
            )
        )
    }

    private static func card(_ keyword: String, value: String) -> String {
        let key = keyword.padding(toLength: 8, withPad: " ", startingAt: 0)
        let valuePadding = String(repeating: " ", count: max(20 - value.count, 0))
        let content = key + "= " + valuePadding + value
        return content.padding(toLength: cardLength, withPad: " ", startingAt: 0)
    }

    private static func appendSIPCards(
        prefix: String,
        terms: [(Int, Int)],
        values: [Double],
        to cards: inout [String]
    ) {
        for ((p, q), value) in zip(terms, values) {
            cards.append(card("\(prefix)_\(p)_\(q)", number: value))
        }
    }

    private static func terms(order: Int, minimumTotal: Int) -> [(Int, Int)] {
        guard order >= minimumTotal else { return [] }
        return (0...order).flatMap { p in
            (0...(order - p)).compactMap { q in
                p + q >= minimumTotal ? (p, q) : nil
            }
        }
    }
}

enum ImageClipboard {
    static func copy(
        _ image: CGImage,
        to pasteboard: NSPasteboard = .general
    ) throws {
        let png = try ImageFileWriter.data(image, format: .png)
        let tiff = try ImageFileWriter.data(image, format: .tiff)
        let item = NSPasteboardItem()
        guard
            item.setData(png, forType: .png),
            item.setData(tiff, forType: .tiff)
        else {
            throw ImageExportError.couldNotCopy
        }
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else {
            throw ImageExportError.couldNotCopy
        }
    }
}

enum ImageFileWriter {
    static func compositing(_ overlay: CGImage, over image: CGImage) throws -> CGImage {
        guard image.width == overlay.width, image.height == overlay.height else {
            throw ImageExportError.couldNotComposite
        }

        let bitsPerComponent = image.bitsPerComponent
        let bytesPerPixel: Int
        var bitmapInfo = CGBitmapInfo(
            rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        switch bitsPerComponent {
        case 8:
            bytesPerPixel = 4
        case 16:
            bytesPerPixel = 8
            #if _endian(little)
            bitmapInfo.insert(.byteOrder16Little)
            #else
            bitmapInfo.insert(.byteOrder16Big)
            #endif
        default:
            throw ImageExportError.couldNotComposite
        }

        guard
            let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil,
                width: image.width,
                height: image.height,
                bitsPerComponent: bitsPerComponent,
                bytesPerRow: image.width * bytesPerPixel,
                space: colorSpace,
                bitmapInfo: bitmapInfo.rawValue
            )
        else {
            throw ImageExportError.couldNotComposite
        }

        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.interpolationQuality = .none
        context.draw(image, in: bounds)
        context.draw(overlay, in: bounds)
        guard let composited = context.makeImage() else {
            throw ImageExportError.couldNotComposite
        }
        return composited
    }

    static func write(
        _ image: CGImage,
        to url: URL,
        format: ImageExportFormat
    ) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            format.contentType.identifier as CFString,
            1,
            nil
        ) else {
            throw ImageExportError.couldNotCreateDestination
        }

        let properties: CFDictionary? = switch format {
        case .jpeg:
            [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary
        case .png, .tiff:
            nil
        }
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else {
            throw ImageExportError.couldNotEncode
        }
    }

    static func data(
        _ image: CGImage,
        format: ImageExportFormat
    ) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            format.contentType.identifier as CFString,
            1,
            nil
        ) else {
            throw ImageExportError.couldNotCreateDestination
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ImageExportError.couldNotEncode
        }
        return data as Data
    }
}
