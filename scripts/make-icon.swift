#!/usr/bin/env swift
// Renders the Slurm Monitor app icon and packs it into an .icns file.
// Usage: swift scripts/make-icon.swift [output.icns] [preview.png]
// Default output: Resources/AppIcon.icns (relative to the repo root).

import AppKit

let args = CommandLine.arguments
let scriptDir = URL(fileURLWithPath: args[0]).deletingLastPathComponent()
let rootDir = scriptDir.deletingLastPathComponent()
let outputURL = args.count > 1
    ? URL(fileURLWithPath: args[1])
    : rootDir.appendingPathComponent("Resources/AppIcon.icns")
let previewURL = args.count > 2 ? URL(fileURLWithPath: args[2]) : nil

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

/// Draws the icon into the current graphics context on a `size` x `size` canvas.
func drawIcon(size s: CGFloat) {
    // macOS icon grid: 824/1024 body with ~22.5% corner radius, leaving room for the shadow.
    let inset = s * 100 / 1024
    let body = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let radius = body.width * 0.225
    let squircle = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = s * 0.025
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
    shadow.set()
    color(0x2550D0).setFill()
    squircle.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Blue gradient, lighter at the top (Zest-like CPU blue).
    NSGradient(starting: color(0x4C8DFF), ending: color(0x1E3FA6))?.draw(in: squircle, angle: -90)

    // Subtle top highlight.
    NSGraphicsContext.saveGraphicsState()
    squircle.addClip()
    let highlight = NSRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2)
    NSGradient(starting: NSColor.white.withAlphaComponent(0.14), ending: NSColor.white.withAlphaComponent(0))?
        .draw(in: highlight, angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // Three "job" rows: status dot + time bar, echoing the panel's Ending-soon card.
    let w = body.width
    let rows: [(dot: NSColor, fill: CGFloat, y: CGFloat)] = [
        (color(0x34C759), 0.86, 0.68),
        (color(0x34C759), 0.55, 0.50),
        (color(0xFF9F0A), 0.28, 0.32),
    ]
    let dotD = w * 0.10
    let dotX = body.minX + w * 0.17
    let trackX = body.minX + w * 0.33
    let trackW = w * 0.50
    let trackH = w * 0.085

    for row in rows {
        let cy = body.minY + w * row.y

        let dotRect = NSRect(x: dotX, y: cy - dotD / 2, width: dotD, height: dotD)
        NSColor.white.withAlphaComponent(0.95).setFill()
        NSBezierPath(ovalIn: dotRect.insetBy(dx: -w * 0.012, dy: -w * 0.012)).fill()
        row.dot.setFill()
        NSBezierPath(ovalIn: dotRect).fill()

        let track = NSRect(x: trackX, y: cy - trackH / 2, width: trackW, height: trackH)
        NSColor.white.withAlphaComponent(0.25).setFill()
        NSBezierPath(roundedRect: track, xRadius: trackH / 2, yRadius: trackH / 2).fill()

        let fill = NSRect(x: trackX, y: cy - trackH / 2, width: max(trackH, trackW * row.fill), height: trackH)
        NSColor.white.setFill()
        NSBezierPath(roundedRect: fill, xRadius: trackH / 2, yRadius: trackH / 2).fill()
    }
}

func renderPNG(pixels: Int) throws -> Data {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { throw NSError(domain: "make-icon", code: 1) }
    rep.size = NSSize(width: pixels, height: pixels)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    drawIcon(size: CGFloat(pixels))
    NSGraphicsContext.restoreGraphicsState()

    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "make-icon", code: 2)
    }
    return data
}

let fm = FileManager.default
let iconset = fm.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: iconset) }

for base in [16, 32, 128, 256, 512] {
    try renderPNG(pixels: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try renderPNG(pixels: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}

try fm.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", outputURL.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write("iconutil failed\n".data(using: .utf8)!)
    exit(1)
}

if let previewURL {
    try renderPNG(pixels: 1024).write(to: previewURL)
}
print("Wrote \(outputURL.path)")
