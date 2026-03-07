#!/usr/bin/env swift

import AppKit

struct IconSpec {
    let fileName: String
    let pixels: Int
}

let icons = [
    IconSpec(fileName: "app-icon-20@2x.png", pixels: 40),
    IconSpec(fileName: "app-icon-20@3x.png", pixels: 60),
    IconSpec(fileName: "app-icon-29@2x.png", pixels: 58),
    IconSpec(fileName: "app-icon-29@3x.png", pixels: 87),
    IconSpec(fileName: "app-icon-40@2x.png", pixels: 80),
    IconSpec(fileName: "app-icon-40@3x.png", pixels: 120),
    IconSpec(fileName: "app-icon-60@2x.png", pixels: 120),
    IconSpec(fileName: "app-icon-60@3x.png", pixels: 180),
    IconSpec(fileName: "app-icon-20-ipad@1x.png", pixels: 20),
    IconSpec(fileName: "app-icon-20-ipad@2x.png", pixels: 40),
    IconSpec(fileName: "app-icon-29-ipad@1x.png", pixels: 29),
    IconSpec(fileName: "app-icon-29-ipad@2x.png", pixels: 58),
    IconSpec(fileName: "app-icon-40-ipad@1x.png", pixels: 40),
    IconSpec(fileName: "app-icon-40-ipad@2x.png", pixels: 80),
    IconSpec(fileName: "app-icon-76@1x.png", pixels: 76),
    IconSpec(fileName: "app-icon-76@2x.png", pixels: 152),
    IconSpec(fileName: "app-icon-83.5@2x.png", pixels: 167),
    IconSpec(fileName: "app-icon-1024.png", pixels: 1024),
]

guard CommandLine.arguments.count == 2 else {
    fputs("usage: generate_ios_app_icons.swift <output-directory>\n", stderr)
    exit(1)
}

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(
    at: outputDirectory,
    withIntermediateDirectories: true,
    attributes: nil
)

func makeMasterIcon() -> NSImage {
    let size = NSSize(width: 1024, height: 1024)
    let image = NSImage(size: size)

    image.lockFocus()
    defer { image.unlockFocus() }

    let bounds = NSRect(origin: .zero, size: size)
    // App Store icons must be fully opaque; iOS applies corner masking itself.
    let background = NSBezierPath(rect: bounds)
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.10, green: 0.14, blue: 0.21, alpha: 1),
        NSColor(calibratedRed: 0.18, green: 0.11, blue: 0.12, alpha: 1),
        NSColor(calibratedRed: 0.09, green: 0.14, blue: 0.16, alpha: 1),
    ])!
    gradient.draw(in: background, angle: 315)

    NSGraphicsContext.current?.cgContext.setShadow(
        offset: CGSize(width: 0, height: -18),
        blur: 32,
        color: NSColor.black.withAlphaComponent(0.35).cgColor
    )

    let panelRect = NSRect(x: 144, y: 164, width: 736, height: 696)
    let panel = NSBezierPath(roundedRect: panelRect, xRadius: 120, yRadius: 120)
    NSColor(calibratedRed: 0.97, green: 0.74, blue: 0.35, alpha: 1).setFill()
    panel.fill()

    NSGraphicsContext.current?.cgContext.setShadow(offset: .zero, blur: 0, color: nil)

    let previewRect = NSRect(x: 216, y: 248, width: 592, height: 412)
    let preview = NSBezierPath(roundedRect: previewRect, xRadius: 72, yRadius: 72)
    NSColor(calibratedRed: 0.11, green: 0.14, blue: 0.17, alpha: 1).setFill()
    preview.fill()

    let lensOuter = NSBezierPath(ovalIn: NSRect(x: 344, y: 324, width: 336, height: 336))
    NSColor(calibratedRed: 0.09, green: 0.10, blue: 0.12, alpha: 1).setFill()
    lensOuter.fill()

    let lensRing = NSBezierPath(ovalIn: NSRect(x: 384, y: 364, width: 256, height: 256))
    let lensGradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.18, green: 0.74, blue: 0.66, alpha: 1),
        NSColor(calibratedRed: 0.07, green: 0.24, blue: 0.32, alpha: 1),
        NSColor(calibratedRed: 0.06, green: 0.08, blue: 0.11, alpha: 1),
    ])!
    lensGradient.draw(in: lensRing, relativeCenterPosition: NSZeroPoint)

    let lensCore = NSBezierPath(ovalIn: NSRect(x: 448, y: 428, width: 128, height: 128))
    NSColor(calibratedRed: 0.96, green: 0.95, blue: 0.93, alpha: 0.18).setFill()
    lensCore.fill()

    let led = NSBezierPath(ovalIn: NSRect(x: 676, y: 584, width: 48, height: 48))
    NSColor(calibratedRed: 0.21, green: 0.76, blue: 0.65, alpha: 1).setFill()
    led.fill()

    let topWave = NSBezierPath()
    topWave.lineWidth = 32
    topWave.lineCapStyle = .round
    topWave.move(to: NSPoint(x: 258, y: 760))
    topWave.curve(to: NSPoint(x: 766, y: 760), controlPoint1: NSPoint(x: 390, y: 816), controlPoint2: NSPoint(x: 622, y: 704))
    NSColor.white.withAlphaComponent(0.15).setStroke()
    topWave.stroke()

    return image
}

func writePNG(image: NSImage, pixels: Int, to destination: URL) throws {
    guard let representation = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 3,
        hasAlpha: false,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw NSError(domain: "IconGeneration", code: 1)
    }

    representation.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()

    guard let data = representation.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "IconGeneration", code: 2)
    }
    try data.write(to: destination, options: .atomic)
}

let master = makeMasterIcon()

for icon in icons {
    let destination = outputDirectory.appendingPathComponent(icon.fileName)
    try writePNG(image: master, pixels: icon.pixels, to: destination)
}
