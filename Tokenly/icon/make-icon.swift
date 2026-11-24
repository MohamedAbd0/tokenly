// Draws the Tokenly app icon and writes AppIcon.iconset (run: swift make-icon.swift, then iconutil -c icns AppIcon.iconset).
import AppKit

func draw(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let k = CGFloat(px) / 1024                       // design on a 1024 grid
    func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect { NSRect(x: x * k, y: y * k, width: w * k, height: h * k) }

    // macOS icon shape: 824pt rounded square centred in 1024
    let body = NSBezierPath(roundedRect: r(100, 100, 824, 824), xRadius: 185 * k, yRadius: 185 * k)
    NSGradient(colors: [NSColor(srgbRed: 0.10, green: 0.12, blue: 0.20, alpha: 1), NSColor(srgbRed: 0.20, green: 0.22, blue: 0.38, alpha: 1)])!
        .draw(in: body, angle: -60)

    // two progress bars, same colours as the menu bar: green = 5h, purple = week
    func bar(y: CGFloat, h: CGFloat, fill: CGFloat, color: NSColor) {
        let x: CGFloat = 212, w: CGFloat = 600
        NSColor.white.withAlphaComponent(0.16).setFill()
        NSBezierPath(roundedRect: r(x, y, w, h), xRadius: h / 2 * k, yRadius: h / 2 * k).fill()
        color.setFill()
        NSBezierPath(roundedRect: r(x, y, w * fill, h), xRadius: h / 2 * k, yRadius: h / 2 * k).fill()
    }
    bar(y: 506, h: 120, fill: 0.68, color: NSColor(srgbRed: 0.29, green: 0.85, blue: 0.42, alpha: 1))
    bar(y: 366, h: 96, fill: 0.42, color: NSColor(srgbRed: 0.72, green: 0.40, blue: 0.95, alpha: 1))

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let dir = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "AppIcon.iconset")
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                   ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! draw(px).write(to: dir.appendingPathComponent("icon_\(name).png"))
}
