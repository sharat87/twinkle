// Draws the Alfred workflow's result icons: a star for bookmarks, a clock
// for history, as SF Symbols in Twinkle's coral and amber.
// Usage: swift scripts/make-alfred-icons.swift <folder>
import AppKit

let folder = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")

func write(_ symbol: String, _ color: NSColor, to name: String) {
    let size = 256
    let config = NSImage.SymbolConfiguration(pointSize: 200, weight: .semibold)
        .applying(.init(paletteColors: [color]))
    guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config),
          let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else { fatalError("Can't draw \(symbol)") }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    // Centred, scaled to fit with a little margin.
    let s = CGFloat(size) * 0.86 / max(image.size.width, image.size.height)
    let w = image.size.width * s, h = image.size.height * s
    image.draw(in: NSRect(x: (CGFloat(size) - w) / 2, y: (CGFloat(size) - h) / 2, width: w, height: h))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent(name))
}

write("star.fill", NSColor(srgbRed: 0.96, green: 0.65, blue: 0.14, alpha: 1), to: "bookmark.png")
write("clock.fill", NSColor(srgbRed: 0.93, green: 0.40, blue: 0.33, alpha: 1), to: "history.png")
