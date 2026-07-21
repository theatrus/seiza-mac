#!/usr/bin/env swift

import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let markURL = root.appendingPathComponent(
    "App/Assets.xcassets/SeizaMark.imageset/seiza-mark.png"
)
let resourceDirectory = root.appendingPathComponent("App/Resources")
let iconsetDirectory = resourceDirectory.appendingPathComponent("FITSFile.iconset")
let icnsURL = resourceDirectory.appendingPathComponent("FITSFile.icns")

guard let mark = NSImage(contentsOf: markURL) else {
    fatalError("Could not read the Seiza mark at \(markURL.path)")
}

try FileManager.default.createDirectory(
    at: iconsetDirectory,
    withIntermediateDirectories: true
)

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

func sheetPath(size: CGFloat) -> NSBezierPath {
    let path = NSBezierPath()
    path.move(to: NSPoint(x: size * 0.23, y: size * 0.09))
    path.curve(
        to: NSPoint(x: size * 0.16, y: size * 0.16),
        controlPoint1: NSPoint(x: size * 0.19, y: size * 0.09),
        controlPoint2: NSPoint(x: size * 0.16, y: size * 0.12)
    )
    path.line(to: NSPoint(x: size * 0.16, y: size * 0.84))
    path.curve(
        to: NSPoint(x: size * 0.23, y: size * 0.91),
        controlPoint1: NSPoint(x: size * 0.16, y: size * 0.88),
        controlPoint2: NSPoint(x: size * 0.19, y: size * 0.91)
    )
    path.line(to: NSPoint(x: size * 0.65, y: size * 0.91))
    path.line(to: NSPoint(x: size * 0.84, y: size * 0.72))
    path.line(to: NSPoint(x: size * 0.84, y: size * 0.16))
    path.curve(
        to: NSPoint(x: size * 0.77, y: size * 0.09),
        controlPoint1: NSPoint(x: size * 0.84, y: size * 0.12),
        controlPoint2: NSPoint(x: size * 0.81, y: size * 0.09)
    )
    path.close()
    return path
}

func drawIcon(pixels: Int) throws -> Data {
    let size = CGFloat(pixels)
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
    ), let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw CocoaError(.fileWriteUnknown)
    }

    bitmap.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    graphics.imageInterpolation = .high

    let canvas = NSRect(x: 0, y: 0, width: size, height: size)
    NSColor.clear.setFill()
    canvas.fill()

    let sheet = sheetPath(size: size)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.30)
    shadow.shadowBlurRadius = max(1, size * 0.035)
    shadow.shadowOffset = NSSize(width: 0, height: -size * 0.022)
    NSGraphicsContext.current?.saveGraphicsState()
    shadow.set()
    NSGradient(
        starting: NSColor(calibratedWhite: 1.0, alpha: 1),
        ending: NSColor(calibratedRed: 0.88, green: 0.91, blue: 0.94, alpha: 1)
    )!.draw(in: sheet, angle: -90)
    NSGraphicsContext.current?.restoreGraphicsState()

    NSColor(calibratedWhite: 0.64, alpha: 0.50).setStroke()
    sheet.lineWidth = max(0.5, size * 0.006)
    sheet.stroke()

    let fold = NSBezierPath()
    fold.move(to: NSPoint(x: size * 0.65, y: size * 0.91))
    fold.line(to: NSPoint(x: size * 0.65, y: size * 0.72))
    fold.line(to: NSPoint(x: size * 0.84, y: size * 0.72))
    fold.close()
    NSGradient(
        starting: NSColor(calibratedRed: 0.82, green: 0.87, blue: 0.91, alpha: 1),
        ending: NSColor(calibratedRed: 0.96, green: 0.98, blue: 0.99, alpha: 1)
    )!.draw(in: fold, angle: 45)
    NSColor(calibratedWhite: 0.62, alpha: 0.45).setStroke()
    fold.lineWidth = max(0.5, size * 0.005)
    fold.stroke()

    let imagePanel = NSRect(
        x: size * 0.225,
        y: size * 0.355,
        width: size * 0.55,
        height: size * 0.39
    )
    let panelPath = NSBezierPath(
        roundedRect: imagePanel,
        xRadius: size * 0.045,
        yRadius: size * 0.045
    )
    NSGradient(
        starting: NSColor(calibratedRed: 0.035, green: 0.075, blue: 0.11, alpha: 1),
        ending: NSColor(calibratedRed: 0.01, green: 0.025, blue: 0.045, alpha: 1)
    )!.draw(in: panelPath, angle: -65)

    NSGraphicsContext.current?.saveGraphicsState()
    panelPath.addClip()
    let starColor = NSColor(
        calibratedRed: 112.0 / 255.0,
        green: 225.0 / 255.0,
        blue: 239.0 / 255.0,
        alpha: pixels >= 64 ? 0.72 : 0.55
    )
    starColor.setFill()
    let starCenters: [(CGFloat, CGFloat, CGFloat)] = [
        (0.29, 0.66, 0.008),
        (0.69, 0.68, 0.006),
        (0.72, 0.43, 0.009),
        (0.33, 0.43, 0.005),
        (0.55, 0.70, 0.004),
    ]
    for star in starCenters {
        let diameter = max(1, size * star.2)
        NSBezierPath(
            ovalIn: NSRect(
                x: size * star.0 - diameter / 2,
                y: size * star.1 - diameter / 2,
                width: diameter,
                height: diameter
            )
        ).fill()
    }

    let markInset = pixels < 64 ? size * 0.075 : size * 0.045
    let markRect = imagePanel.insetBy(dx: markInset, dy: -size * 0.01)
    mark.draw(
        in: markRect,
        from: .zero,
        operation: .sourceOver,
        fraction: 1,
        respectFlipped: false,
        hints: [.interpolation: NSImageInterpolation.high]
    )
    NSGraphicsContext.current?.restoreGraphicsState()

    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let labelRect = NSRect(
        x: size * 0.20,
        y: size * 0.145,
        width: size * 0.60,
        height: size * 0.16
    )
    let label = NSAttributedString(
        string: "FITS",
        attributes: [
            .font: NSFont.systemFont(
                ofSize: max(5, size * (pixels <= 32 ? 0.115 : 0.105)),
                weight: .semibold
            ),
            .foregroundColor: NSColor(
                calibratedRed: 0.035,
                green: 0.12,
                blue: 0.18,
                alpha: 1
            ),
            .kern: pixels <= 32 ? 0 : size * 0.008,
            .paragraphStyle: paragraph,
        ]
    )
    label.draw(in: labelRect)

    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    return png
}

for icon in icons {
    try drawIcon(pixels: icon.pixels).write(
        to: iconsetDirectory.appendingPathComponent(icon.filename)
    )
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = [
    "--convert", "icns",
    "--output", icnsURL.path,
    iconsetDirectory.path,
]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    fatalError("iconutil failed with status \(iconutil.terminationStatus)")
}

print("Wrote \(icnsURL.path)")
