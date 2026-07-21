import CoreGraphics
import Foundation
import QuickLookUI

final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    func providePreview(
        for request: QLFilePreviewRequest,
        completionHandler handler: @escaping (QLPreviewReply?, Error?) -> Void
    ) {
        do {
            let rendered = try SeizaCore.render(url: request.fileURL, maxDimension: 4096)
            let image = rendered.image
            let size = CGSize(width: image.width, height: image.height)
            let reply = QLPreviewReply(contextSize: size, isBitmap: true) { context, _ in
                context.interpolationQuality = .none
                context.draw(image, in: CGRect(origin: .zero, size: size))
            }
            reply.title = request.fileURL.lastPathComponent
            handler(reply, nil)
        } catch {
            handler(nil, error)
        }
    }
}
