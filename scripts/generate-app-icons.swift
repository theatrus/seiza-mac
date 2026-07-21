#!/usr/bin/env swift

import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let markURL = root.appendingPathComponent(
    "App/Assets.xcassets/SeizaMark.imageset/seiza-mark.png"
)
let outputDirectory = root.appendingPathComponent(
    "App/Assets.xcassets/AppIcon.appiconset"
)

guard let mark = NSImage(contentsOf: markURL) else {
    fatalError("Could not read the Seiza website mark at \(markURL.path)")
}

let icons: [(filename: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

for icon in icons {
    let pixels = icon.pixels
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        fatalError("Could not allocate the \(pixels)-pixel app icon")
    }

    bitmap.size = NSSize(width: pixels, height: pixels)
    guard let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
        fatalError("Could not create the \(pixels)-pixel drawing context")
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    graphics.imageInterpolation = .high

    let canvas = NSRect(x: 0, y: 0, width: pixels, height: pixels)
    NSColor.clear.setFill()
    canvas.fill()

    // Match the colorful tile on WelcomeView: the exact website mark on the
    // Seiza navy background, with a modern macOS rounded-square silhouette.
    let outerInset = CGFloat(pixels) * 0.055
    let tile = canvas.insetBy(dx: outerInset, dy: outerInset)
    let tilePath = NSBezierPath(
        roundedRect: tile,
        xRadius: tile.width * 0.22,
        yRadius: tile.height * 0.22
    )
    NSColor(
        calibratedRed: 7.0 / 255.0,
        green: 16.0 / 255.0,
        blue: 24.0 / 255.0,
        alpha: 1
    ).setFill()
    tilePath.fill()

    mark.draw(
        in: tile,
        from: .zero,
        operation: .sourceOver,
        fraction: 1,
        respectFlipped: false,
        hints: [.interpolation: NSImageInterpolation.high]
    )

    NSGraphicsContext.restoreGraphicsState()

    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("Could not encode \(icon.filename)")
    }
    try png.write(to: outputDirectory.appendingPathComponent(icon.filename))
}
