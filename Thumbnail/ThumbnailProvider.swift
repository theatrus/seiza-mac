import CoreGraphics
import OSLog
import QuickLookThumbnailing

final class ThumbnailProvider: QLThumbnailProvider {
    private static let renderQueue = DispatchQueue(
        label: "fyi.seiza.mac.thumbnail-render",
        qos: .userInitiated
    )
    private static let maximumRenderDimension = 4_096

    override func provideThumbnail(
        for request: QLFileThumbnailRequest,
        _ handler: @escaping (QLThumbnailReply?, Error?) -> Void
    ) {
        Self.renderQueue.async {
            let logger = Logger(
                subsystem: "fyi.seiza.mac.thumbnail",
                category: "thumbnail"
            )
            let url = request.fileURL
            let isAccessing = url.startAccessingSecurityScopedResource()
            defer {
                if isAccessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            do {
                let maximumPointDimension = max(
                    request.maximumSize.width,
                    request.maximumSize.height,
                    1
                )
                let maximumPixelDimension = min(
                    Int(ceil(maximumPointDimension * max(request.scale, 1))),
                    Self.maximumRenderDimension
                )
                let rendered = try SeizaCore.render(
                    url: url,
                    maxDimension: UInt32(maximumPixelDimension)
                )
                let image = rendered.image
                let drawingRect = Self.aspectFitRect(
                    imageSize: CGSize(width: image.width, height: image.height),
                    in: request.maximumSize
                )
                let reply = QLThumbnailReply(
                    contextSize: request.maximumSize,
                    drawing: { context in
                        context.interpolationQuality = .high
                        context.draw(image, in: drawingRect)
                        return true
                    }
                )
                reply.extensionBadge = url.pathExtension.uppercased()
                logger.info("Rendered Finder thumbnail: \(image.width)x\(image.height)")
                handler(reply, nil)
            } catch {
                logger.error("Finder thumbnail render failed: \(error.localizedDescription)")
                handler(nil, error)
            }
        }
    }

    private static func aspectFitRect(
        imageSize: CGSize,
        in bounds: CGSize
    ) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return CGRect(origin: .zero, size: bounds)
        }

        let scale = min(
            bounds.width / imageSize.width,
            bounds.height / imageSize.height
        )
        let fittedSize = CGSize(
            width: imageSize.width * scale,
            height: imageSize.height * scale
        )
        return CGRect(
            x: (bounds.width - fittedSize.width) / 2,
            y: (bounds.height - fittedSize.height) / 2,
            width: fittedSize.width,
            height: fittedSize.height
        )
    }
}
