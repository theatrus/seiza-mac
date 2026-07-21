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
}

final class ImageExportCoordinator: ObservableObject {
    @Published private(set) var requestNumber = 0

    func requestExport() {
        requestNumber &+= 1
    }
}

@MainActor
final class ImageExportOptions: ObservableObject {
    @Published var format: ImageExportFormat = .png
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
    case couldNotEncode

    var errorDescription: String? {
        switch self {
        case .couldNotCreateDestination:
            "The destination could not be prepared for writing."
        case .couldNotEncode:
            "ImageIO could not encode the image in the selected format."
        }
    }
}

enum ImageFileWriter {
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
}
