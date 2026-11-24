import AppKit
import CryptoKit
import TwinkleCore

/// Site icons for the tab list. WKWebView doesn't expose favicons, so after a
/// page loads its `<link rel=icon>` elements are read and the best one is
/// fetched, falling back to /favicon.ico.
///
/// Icons are fetched without cookies (an ephemeral session), so fetching one
/// tells the site nothing a container's cookies would. They are kept per host,
/// in memory and as small PNGs in favicons/ so restored tabs have them at
/// launch. Temporary containers' icons stay in memory only.
@MainActor
final class Favicons {
    static let shared = Favicons()

    private var memory: [String: NSImage] = [:]
    private var inFlight: Set<String> = []
    private let directory: URL
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config)
    }()

    private init() {
        directory = AppState.shared.files.directory.appendingPathComponent("favicons", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// `[href, sizes, type]` for each icon link on the page.
    static let linksScript = """
    [...document.querySelectorAll('link[rel~="icon" i], link[rel~="apple-touch-icon" i]')]
      .map(l => [l.href, l.getAttribute('sizes') || '', l.type || ''])
    """

    func cached(for page: URL, container: UUID?) -> NSImage? {
        guard let host = page.host()?.lowercased() else { return nil }
        if let image = memory[host] { return image }
        if AppState.shared.isTemporary(container) { return nil }
        guard let data = try? Data(contentsOf: file(for: host)), let image = NSImage(data: data) else { return nil }
        memory[host] = image
        return image
    }

    func load(for page: URL, links: [[String]], container: UUID?, done: @escaping (NSImage?) -> Void) {
        guard let host = page.host()?.lowercased() else { return done(nil) }
        if let image = memory[host] { return done(image) }
        guard !inFlight.contains(host) else { return done(nil) }
        inFlight.insert(host)
        let candidates = Self.rank(links, page: page)
        let persist = !AppState.shared.isTemporary(container)
        Task {
            let image = await self.firstImage(candidates)
            self.inFlight.remove(host)
            if let image {
                self.memory[host] = image
                if persist, let png = image.pngData() { try? png.write(to: self.file(for: host)) }
            }
            done(image)
        }
    }

    private func firstImage(_ urls: [URL]) async -> NSImage? {
        for url in urls {
            guard let (data, response) = try? await session.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode ?? 200 < 400,
                  data.count < 1_000_000,
                  let image = NSImage(data: data), image.isValid,
                  image.size.width > 0 else { continue }
            return image.resized(to: 32)
        }
        return nil
    }

    /// Icons nearest 32px first (bigger before smaller), then the rest, then
    /// /favicon.ico.
    static func rank(_ links: [[String]], page: URL) -> [URL] {
        func score(_ link: [String]) -> Int {
            let sizes = link.count > 1 ? link[1].lowercased() : ""
            if sizes == "any" { return 40 }
            let sides = sizes.split(separator: " ").compactMap { $0.split(separator: "x").first.flatMap { Int($0) } }
            guard let side = sides.min(by: { abs($0 - 32) < abs($1 - 32) }) else { return 100 }
            return side >= 32 ? side - 32 : 1000 + (32 - side)
        }
        var urls = links.sorted { score($0) < score($1) }.compactMap { $0.first.flatMap(URL.init(string:)) }
        if let ico = URL(string: "/favicon.ico", relativeTo: page)?.absoluteURL { urls.append(ico) }
        var seen = Set<URL>()
        return urls.filter { ["http", "https"].contains($0.scheme ?? "") && seen.insert($0).inserted }
    }

    private func file(for host: String) -> URL {
        let digest = SHA256.hash(data: Data(host.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest + ".png")
    }
}

extension NSImage {
    func resized(to side: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            self.draw(in: rect, from: .zero, operation: .copy, fraction: 1)
            return true
        }
    }

    func pngData() -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}
