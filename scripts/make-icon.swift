// Draws Twinkle's app icon and writes an .icns.
// Usage: swift scripts/make-icon.swift <out.icns>
//
// A warm cream squircle with one bold glint: four long tapered rays, four
// short diagonal ones, coral into amber. The macOS grid: an 824pt body on
// a 1024 canvas.
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns"

func star(center: CGPoint, radius: CGFloat, waist: CGFloat) -> NSBezierPath {
    // Four points joined by inward curves: a sparkle, not a cross.
    let path = NSBezierPath()
    let tips = (0..<4).map { i -> CGPoint in
        let a = CGFloat(i) * .pi / 2 + .pi / 2
        return CGPoint(x: center.x + cos(a) * radius, y: center.y + sin(a) * radius)
    }
    path.move(to: tips[0])
    for i in 0..<4 {
        let next = tips[(i + 1) % 4]
        let c = CGPoint(x: center.x + (tips[i].x - center.x + next.x - center.x) * waist,
                        y: center.y + (tips[i].y - center.y + next.y - center.y) * waist)
        path.curve(to: next, controlPoint1: c, controlPoint2: c)
    }
    path.close()
    return path
}

func draw(size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: s / 1024, y: s / 1024)

    // Body with a soft drop shadow, per the macOS grid.
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.shadowBlurRadius = 24
    shadow.set()
    NSColor.white.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    NSGradient(colors: [
        NSColor(srgbRed: 1.00, green: 0.98, blue: 0.94, alpha: 1),
        NSColor(srgbRed: 0.99, green: 0.92, blue: 0.82, alpha: 1),
    ])!.draw(in: body, angle: -90)

    let center = CGPoint(x: 512, y: 512)
    let warm = NSGradient(colors: [
        NSColor(srgbRed: 1.00, green: 0.42, blue: 0.36, alpha: 1),   // coral
        NSColor(srgbRed: 1.00, green: 0.66, blue: 0.20, alpha: 1),   // amber
    ])!

    // The glint: long rays up/down/left/right, short ones on the diagonals.
    var parts = [star(center: center, radius: 330, waist: 0.13)]
    for i in 0..<4 {
        let a = CGFloat(i) * .pi / 2 + .pi / 4
        let tip = CGPoint(x: center.x + cos(a) * 190, y: center.y + sin(a) * 190)
        let ray = NSBezierPath()
        let side = CGPoint(x: -sin(a) * 34, y: cos(a) * 34)
        ray.move(to: CGPoint(x: center.x + side.x, y: center.y + side.y))
        ray.line(to: tip)
        ray.line(to: CGPoint(x: center.x - side.x, y: center.y - side.y))
        ray.close()
        parts.append(ray)
    }
    NSGraphicsContext.saveGraphicsState()
    let glow = NSShadow()
    glow.shadowColor = NSColor(srgbRed: 1, green: 0.55, blue: 0.3, alpha: 0.45)
    glow.shadowBlurRadius = 40
    glow.shadowOffset = .zero
    glow.set()
    NSColor(srgbRed: 1, green: 0.5, blue: 0.3, alpha: 1).setFill()
    parts.forEach { $0.fill() }
    NSGraphicsContext.restoreGraphicsState()
    // Each part clipped on its own, one shared gradient: no seams, and
    // overlaps don't cancel out.
    for part in parts {
        NSGraphicsContext.saveGraphicsState()
        part.addClip()
        warm.draw(in: NSRect(x: 180, y: 180, width: 664, height: 664), angle: 45)
        NSGraphicsContext.restoreGraphicsState()
    }

    // A bright core.
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.9), NSColor.white.withAlphaComponent(0)])!
        .draw(fromCenter: center, radius: 0, toCenter: center, radius: 70, options: [])
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Twinkle-\(getpid()).iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! draw(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! draw(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", out]
try! task.run()
task.waitUntilExit()
try? fm.removeItem(at: iconset)
exit(task.terminationStatus)
