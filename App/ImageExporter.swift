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
