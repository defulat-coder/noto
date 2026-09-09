import AppKit

// Run from the project root: swift scripts/make-icon.swift
let source = NSImage(contentsOfFile: "design/app-icon-selected.png")!
let directory = "build/AppIcon.iconset"
try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels,
            pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.current!.imageInterpolation = .high
        let unit = CGFloat(pixels) / 1024
        let frame = NSRect(x: 100 * unit, y: 100 * unit, width: 824 * unit, height: 824 * unit)
        NSBezierPath(roundedRect: frame, xRadius: 185 * unit, yRadius: 185 * unit).addClip()
        source.draw(in: frame, from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(
            to: URL(fileURLWithPath: "\(directory)/icon_\(size)x\(size)\(suffix).png"))
    }
}
