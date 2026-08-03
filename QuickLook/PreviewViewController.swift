import AppKit
import OSLog
import QuickLookUI

private final class AspectFitImageView: NSView {
    var image: NSImage? {
        didSet {
            needsDisplay = true
        }
    }

    override var isOpaque: Bool {
        true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()

        guard let image else { return }
        let drawingRect = ThumbnailLayout.aspectFitRect(
            imageSize: image.size,
            in: bounds
        )
        image.draw(
            in: drawingRect,
            from: NSRect(origin: .zero, size: image.size),
            operation: .copy,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
    }
}

@MainActor
final class PreviewViewController: NSViewController, QLPreviewingController {
    private static let renderQueue = DispatchQueue(
        label: "fyi.seiza.mac.quicklook-render",
        qos: .userInitiated
    )
    private let imageView = AspectFitImageView()

    override func loadView() {
        view = imageView
    }

    func preparePreviewOfFile(at url: URL) async throws {
        let logger = Logger(
            subsystem: "fyi.seiza.mac.quicklook",
            category: "preview"
        )
        let rendered: RenderedImage = try await withCheckedThrowingContinuation { continuation in
            Self.renderQueue.async {
                logger.info("Rendering Quick Look preview")
                let isAccessing = url.startAccessingSecurityScopedResource()
                defer {
                    if isAccessing {
                        url.stopAccessingSecurityScopedResource()
                    }
                }

                do {
                    let rendered = try SeizaCore.render(url: url, maxDimension: 4096)
                    logger.info(
                        "Rendered Quick Look preview: \(rendered.image.width)x\(rendered.image.height)"
                    )
                    continuation.resume(returning: rendered)
                } catch {
                    logger.error("Quick Look render failed: \(error.localizedDescription)")
                    continuation.resume(throwing: error)
                }
            }
        }

        let pixelSize = NSSize(
            width: rendered.image.width,
            height: rendered.image.height
        )
        imageView.image = NSImage(cgImage: rendered.image, size: pixelSize)
        preferredContentSize = Self.previewSize(for: pixelSize)
    }

    private static func previewSize(for imageSize: NSSize) -> NSSize {
        let maximum = NSSize(width: 1_200, height: 900)
        let scale = min(
            maximum.width / max(imageSize.width, 1),
            maximum.height / max(imageSize.height, 1),
            1
        )
        return NSSize(
            width: max(imageSize.width * scale, 320),
            height: max(imageSize.height * scale, 240)
        )
    }
}
