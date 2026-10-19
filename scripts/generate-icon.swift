import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fatalError("Usage: swift generate-icon.swift output.icns")
}
let destination = URL(fileURLWithPath: CommandLine.arguments[1])
let iconset = destination.deletingLastPathComponent().appendingPathComponent("AndroidOnMac.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }

func rounded(_ rect: NSRect, radius: CGFloat, color: NSColor) {
    color.setFill()
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
}

func render(pixels: Int) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                 isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    let background = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 205, yRadius: 205)
    NSGradient(starting: NSColor(calibratedRed: 0.13, green: 0.23, blue: 0.24, alpha: 1),
               ending: NSColor(calibratedRed: 0.055, green: 0.11, blue: 0.12, alpha: 1))!.draw(in: background, angle: -55)
    let sage = NSColor(calibratedRed: 0.65, green: 0.91, blue: 0.79, alpha: 1)
    let screen = NSColor(calibratedRed: 0.17, green: 0.37, blue: 0.36, alpha: 1)
    rounded(NSRect(x: 164, y: 339, width: 590, height: 395), radius: 36, color: sage)
    rounded(NSRect(x: 187, y: 383, width: 544, height: 327), radius: 17, color: screen)
    rounded(NSRect(x: 387, y: 282, width: 140, height: 68), radius: 10, color: sage)
    rounded(NSRect(x: 297, y: 259, width: 320, height: 29), radius: 14, color: sage)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.4)
    shadow.shadowBlurRadius = 28
    shadow.shadowOffset = NSSize(width: -10, height: -10)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    rounded(NSRect(x: 597, y: 197, width: 237, height: 475), radius: 46, color: NSColor(calibratedWhite: 0.94, alpha: 1))
    NSGraphicsContext.restoreGraphicsState()
    rounded(NSRect(x: 614, y: 218, width: 203, height: 432), radius: 31, color: screen)
    rounded(NSRect(x: 674, y: 623, width: 84, height: 10), radius: 5, color: sage)
    rounded(NSRect(x: 681, y: 234, width: 72, height: 7), radius: 4, color: sage)
    let connection = NSBezierPath()
    connection.move(to: NSPoint(x: 321, y: 552))
    connection.line(to: NSPoint(x: 541, y: 552))
    connection.move(to: NSPoint(x: 503, y: 590))
    connection.line(to: NSPoint(x: 541, y: 552))
    connection.line(to: NSPoint(x: 503, y: 514))
    connection.move(to: NSPoint(x: 528, y: 460))
    connection.line(to: NSPoint(x: 308, y: 460))
    connection.move(to: NSPoint(x: 346, y: 498))
    connection.line(to: NSPoint(x: 308, y: 460))
    connection.line(to: NSPoint(x: 346, y: 422))
    connection.lineWidth = 21
    connection.lineCapStyle = .round
    connection.lineJoinStyle = .round
    sage.setStroke()
    connection.stroke()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        try render(pixels: size * scale).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", destination.path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else { fatalError("iconutil failed") }
