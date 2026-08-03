import CoreGraphics

enum ThumbnailLayout {
    static func contextSize(
        imageSize: CGSize,
        minimumSize: CGSize,
        maximumSize: CGSize
    ) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return maximumSize
        }

        let scale = min(
            maximumSize.width / imageSize.width,
            maximumSize.height / imageSize.height
        )
        return CGSize(
            width: min(
                max(imageSize.width * scale, minimumSize.width),
                maximumSize.width
            ),
            height: min(
                max(imageSize.height * scale, minimumSize.height),
                maximumSize.height
            )
        )
    }

    static func draw(_ image: CGImage, in context: CGContext) {
        let bounds = CGSize(
            width: CGFloat(context.width),
            height: CGFloat(context.height)
        )
        let imageSize = CGSize(width: image.width, height: image.height)
        let scale = min(
            bounds.width / imageSize.width,
            bounds.height / imageSize.height
        )
        let drawingSize = CGSize(
            width: imageSize.width * scale,
            height: imageSize.height * scale
        )
        context.interpolationQuality = .high
        context.draw(
            image,
            in: CGRect(
                x: (bounds.width - drawingSize.width) / 2,
                y: (bounds.height - drawingSize.height) / 2,
                width: drawingSize.width,
                height: drawingSize.height
            )
        )
    }
}
