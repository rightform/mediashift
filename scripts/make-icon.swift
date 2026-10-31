// Draws the app icon: the wheel from the main gesture, with one format picked.
// usage: swift scripts/make-icon.swift scripts/AppIcon.icns
import AppKit

func render(size: Int) -> Data {
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    bitmap.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let scale = CGFloat(size) / 1024
    NSGraphicsContext.current?.cgContext.scaleBy(x: scale, y: scale)

    func color(_ hex: Int) -> NSColor {
        NSColor(srgbRed: CGFloat(hex >> 16 & 255) / 255, green: CGFloat(hex >> 8 & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
    }

    // Apple's macOS grid: an 824 pt tile centred on the 1024 canvas.
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    let outline = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.shadowBlurRadius = 28
    shadow.set()
    color(0x1F1D1A).setFill()
    outline.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    outline.addClip()
    NSGradient(starting: color(0x34302A), ending: color(0x171512))?.draw(in: tile, angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    let center = NSPoint(x: 512, y: 512)
    let count = 8
    let radius: CGFloat = 268
    for index in 0..<count {
        let angle = CGFloat(index) / CGFloat(count) * 2 * .pi
        let point = NSPoint(x: center.x + sin(angle) * radius, y: center.y + cos(angle) * radius)
        let picked = index == 1
        let width: CGFloat = picked ? 128 : 104
        let rect = NSRect(x: point.x - width / 2, y: point.y - width / 2, width: width, height: width)
        (picked ? color(0xFF7350) : color(0xEFEAE2).withAlphaComponent(0.92)).setFill()
        NSBezierPath(ovalIn: rect).fill()
    }

    // The hub, where the pointer starts.
    let hubRect = NSRect(x: center.x - 92, y: center.y - 92, width: 184, height: 184)
    color(0xEFEAE2).setFill()
    NSBezierPath(ovalIn: hubRect).fill()

    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "AppIcon.icns")
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }
for base in [16, 32, 128, 256, 512] {
    try render(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try process.run()
process.waitUntilExit()
exit(process.terminationStatus)
