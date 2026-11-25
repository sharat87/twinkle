import AppKit
import TwinkleCore
import WebKit

/// File › Import from Safari…: history into history.sqlite, bookmarks into
/// bookmarks.json, cookies into the data stores. A cookie for a site that's
/// assigned to a container goes into that container, so you stay signed in
/// where the site opens; the rest go to "no container".
///
/// Safari's files are behind Full Disk Access, which Twinkle has to be given
/// first (and can be taken away again afterwards).
@MainActor
enum SafariImporter {
    static func run() {
        let confirm = NSAlert()
        confirm.messageText = "Import from Safari?"
        confirm.informativeText = """
        History, bookmarks and cookies are copied from Safari into Twinkle. Cookies for sites that \
        always open in a container go into that container; the rest have no container. \
        Running it again adds anything new and doesn't duplicate.
        """
        confirm.addButton(withTitle: "Import")
        confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        var lines: [String] = []
        var blocked = false

        do {
            let pages = try Safari.history()
            let count = try AppState.shared.importHistory(pages)
            lines.append("History: \(count) pages" + (count < pages.count ? " (older than \(Int(AppState.shared.settings.historyDays)) days left out)" : "") + ".")
        } catch Safari.Failure.unreadable {
            blocked = true
        } catch {
            lines.append("History: \(error)")
        }

        do {
            let bookmarks = try Safari.bookmarks()
            let added = try AppState.shared.addBookmarks(bookmarks)
            lines.append("Bookmarks: \(added) new of \(bookmarks.count).")
        } catch Safari.Failure.unreadable {
            blocked = true
        } catch {
            lines.append("Bookmarks: \(error)")
        }

        var cookies: [Safari.Cookie] = []
        var cookieError: String?
        var cookieBlocked = true
        for file in Safari.cookieFiles {
            guard let data = try? Data(contentsOf: file) else { continue }
            cookieBlocked = false
            do {
                cookies += try Safari.cookies(binary: data)
            } catch {
                cookieError = "\(error)"
            }
        }
        if cookieBlocked { blocked = true }

        if blocked && lines.isEmpty && cookies.isEmpty {
            askForAccess()
            return
        }

        Task { @MainActor in
            if !cookies.isEmpty {
                Status.show("Importing \(cookies.count) cookies from Safari…")
                lines.append(await importCookies(cookies))
                Status.show("Imported from Safari.")
            } else if let cookieError {
                lines.append("Cookies: \(cookieError)")
            }
            if blocked {
                lines.append("Some of Safari's files couldn't be read: Twinkle needs Full Disk Access for all of them.")
            }
            let done = NSAlert()
            done.messageText = "Imported from Safari"
            done.informativeText = lines.joined(separator: "\n")
                + "\n\nYou can now turn off Full Disk Access for Twinkle in System Settings."
            done.runModal()
        }
    }

    /// Each cookie into its site's container (or none). Expired ones and
    /// ones WebKit won't take are skipped.
    private static func importCookies(_ cookies: [Safari.Cookie]) async -> String {
        let now = Date()
        var perContainer: [String: Int] = [:]
        var skipped = 0
        for c in cookies {
            guard c.expires > now, let cookie = httpCookie(c) else {
                skipped += 1
                continue
            }
            let container = AppState.shared.assignment(forHost: c.host)?.container
            await AppState.shared.dataStore(for: container?.id).httpCookieStore.setCookie(cookie)
            perContainer[container?.name ?? "no container", default: 0] += 1
        }
        let total = perContainer.values.reduce(0, +)
        let breakdown = perContainer.sorted { $0.value > $1.value }.map { "\($0.value) in \($0.key)" }.joined(separator: ", ")
        return "Cookies: \(total)" + (breakdown.isEmpty ? "" : " (\(breakdown))") + (skipped > 0 ? "; \(skipped) expired or invalid skipped." : ".")
    }

    private static func httpCookie(_ c: Safari.Cookie) -> HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .domain: c.domain,
            .path: c.path.isEmpty ? "/" : c.path,
            .name: c.name,
            .value: c.value,
            .expires: c.expires,
        ]
        if c.secure { properties[.secure] = "TRUE" }
        if c.httpOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        return HTTPCookie(properties: properties)
    }

    private static func askForAccess() {
        let alert = NSAlert()
        alert.messageText = "Twinkle can't read Safari's data"
        alert.informativeText = """
        macOS keeps Safari's history, bookmarks and cookies behind Full Disk Access. In System Settings › \
        Privacy & Security › Full Disk Access, add Twinkle (\(Bundle.main.bundlePath)) and turn it on. \
        Then quit and reopen Twinkle, and choose File › Import from Safari… again.
        """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}
