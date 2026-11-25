import Foundation
import TwinkleCore
import WebKit

/// Moves the data an unsandboxed Twinkle kept in ~/Library into the sandbox
/// container, once, at the first sandboxed launch of the usual Twinkle:
/// Application Support/Twinkle, and WebKit's data stores. Files are moved,
/// not copied, so no readable copy stays behind; caches are deleted.
///
/// The cookies outside any container are the exception: WebKit keeps them
/// somewhere else in a sandbox, so they're moved aside and put back through
/// WebKit (`importDefaultCookies`) before the first page loads.
enum Migration {
    private static let fm = FileManager.default
    private static let bundle = "dev.twinkle.Twinkle"
    private static var oldLibrary: URL { Home.url.appendingPathComponent("Library") }
    private static var newLibrary: URL { URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library") }
    private static var oldSupport: URL { oldLibrary.appendingPathComponent("Application Support/Twinkle") }
    private static var newSupport: URL { newLibrary.appendingPathComponent("Application Support/Twinkle") }
    /// The old default store's cookies, waiting for `importDefaultCookies`.
    private static var pendingCookies: URL { newSupport.appendingPathComponent("migrated-cookies.binarycookies") }

    /// Before anything reads or writes data. Does nothing once moved.
    static func run() {
        guard Home.url != URL(fileURLWithPath: NSHomeDirectory()),
              fm.fileExists(atPath: oldSupport.appendingPathComponent("settings.json").path) else { return }
        // Each file replaces what a sandboxed Twinkle may have written before
        // there was anything to move. settings.json goes last: while it's
        // still in the old folder, the move isn't finished and runs again.
        try? fm.createDirectory(at: newSupport, withIntermediateDirectories: true)
        moveChildren(of: oldSupport, into: newSupport, except: "settings.json")

        let oldWebKit = oldLibrary.appendingPathComponent("WebKit/\(bundle)")
        let newWebKit = newLibrary.appendingPathComponent("WebKit")
        // Each container's store: cookies, local storage, IndexedDB and cache.
        let stores = newWebKit.appendingPathComponent("WebsiteDataStore")
        try? fm.createDirectory(at: stores, withIntermediateDirectories: true)
        moveChildren(of: oldWebKit.appendingPathComponent("WebsiteDataStore"), into: stores)
        // The default store's site data (its cookies are below).
        let data = newWebKit.appendingPathComponent("WebsiteData")
        try? fm.createDirectory(at: data, withIntermediateDirectories: true)
        moveChildren(of: oldWebKit.appendingPathComponent("WebsiteData"), into: data)

        let oldCookies = oldLibrary.appendingPathComponent("HTTPStorages/\(bundle).binarycookies")
        if fm.fileExists(atPath: oldCookies.path) {
            try? fm.removeItem(at: pendingCookies)
            try? fm.moveItem(at: oldCookies, to: pendingCookies)
        }

        moveChildren(of: oldSupport, into: newSupport)

        // Compiled filter lists, caches and URLSession's storage are rebuilt.
        for dir in [oldWebKit.appendingPathComponent("ContentRuleLists"),
                    oldLibrary.appendingPathComponent("Caches/\(bundle)"),
                    oldLibrary.appendingPathComponent("HTTPStorages/\(bundle)")] {
            removeChildren(of: dir)
        }
        // The emptied folders themselves, where the sandbox allows it. rmdir
        // only removes empty ones: anything that failed to move stays put.
        for dir in [oldSupport, oldWebKit.appendingPathComponent("WebsiteDataStore"),
                    oldWebKit.appendingPathComponent("WebsiteData"), oldWebKit.appendingPathComponent("ContentRuleLists"),
                    oldWebKit, oldLibrary.appendingPathComponent("Caches/\(bundle)"),
                    oldLibrary.appendingPathComponent("HTTPStorages/\(bundle)")] {
            rmdir(dir.path)
        }
    }

    /// The old default store's cookies into WebKit's default store.
    @MainActor static func importDefaultCookies() async {
        // Kept if it can't be read, rather than losing the cookies.
        guard let data = try? Data(contentsOf: pendingCookies),
              let cookies = try? Safari.cookies(binary: data) else { return }
        let store = WKWebsiteDataStore.default().httpCookieStore
        let now = Date()
        for cookie in cookies where cookie.expires > now {
            if let http = SafariImporter.httpCookie(cookie) { await store.setCookie(http) }
        }
        try? fm.removeItem(at: pendingCookies)
    }

    private static func moveChildren(of source: URL, into destination: URL, except skipped: String? = nil) {
        for child in (try? fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)) ?? []
        where child.lastPathComponent != skipped {
            let target = destination.appendingPathComponent(child.lastPathComponent)
            try? fm.removeItem(at: target)
            try? fm.moveItem(at: child, to: target)
        }
    }

    private static func removeChildren(of dir: URL) {
        for child in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
            try? fm.removeItem(at: child)
        }
    }
}
