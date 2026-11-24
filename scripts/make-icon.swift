// Draws Twinkle's app icon and writes an .icns.
// Usage: swift scripts/make-icon.swift <out.icns>
//
// A night-sky squircle (deep indigo into violet) with one bright four-point
// star and two small ones, in the macOS icon grid (824pt body on 1024).
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
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.shadowBlurRadius = 24
    shadow.set()
    NSColor(srgbRed: 0.12, green: 0.10, blue: 0.30, alpha: 1).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    NSGradient(colors: [
        NSColor(srgbRed: 0.07, green: 0.08, blue: 0.24, alpha: 1),
        NSColor(srgbRed: 0.25, green: 0.16, blue: 0.52, alpha: 1),
        NSColor(srgbRed: 0.62, green: 0.32, blue: 0.70, alpha: 1),
    ], atLocations: [0, 0.6, 1], colorSpace: .sRGB)!.draw(in: body, angle: -60)

    // A glow behind the main star.
    let glowCenter = CGPoint(x: 540, y: 540)
    NSGradient(colors: [NSColor(srgbRed: 1, green: 0.93, blue: 0.75, alpha: 0.45), .clear])!
        .draw(fromCenter: glowCenter, radius: 0, toCenter: glowCenter, radius: 380, options: [])

    // Faint background stars.
    for (x, y, r) in [(250.0, 760.0, 7.0), (330, 300, 5), (760, 260, 6), (800, 720, 4), (220, 470, 4), (640, 820, 5)] {
        NSColor.white.withAlphaComponent(0.55).setFill()
        NSBezierPath(ovalIn: NSRect(x: x - r, y: y - r, width: r * 2, height: r * 2)).fill()
    }

    // The main star, warm white with a light gradient.
    let main = star(center: glowCenter, radius: 300, waist: 0.16)
    NSGraphicsContext.saveGraphicsState()
    main.addClip()
    NSGradient(colors: [.white, NSColor(srgbRed: 1, green: 0.88, blue: 0.62, alpha: 1)])!
        .draw(in: main.bounds, angle: -70)
    NSGraphicsContext.restoreGraphicsState()

    // Two small companions.
    NSColor.white.setFill()
    star(center: CGPoint(x: 290, y: 690), radius: 82, waist: 0.17).fill()
    NSColor.white.withAlphaComponent(0.85).setFill()
    star(center: CGPoint(x: 755, y: 330), radius: 56, waist: 0.17).fill()
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
