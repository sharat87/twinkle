import Foundation

/// What the window is called. KeePassXC auto-type matches on the window title,
/// so the page's host is part of it: an entry with a window association like
/// `*github.com*` fills on any GitHub page without a browser extension.
public enum WindowTitle {
    public static let appName = "Twinkle"

    public static func make(title: String, url: URL?) -> String {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = url?.host(percentEncoded: false) ?? ""
        if host.isEmpty { return title.isEmpty ? appName : title }
        return "\(title.isEmpty ? host : title) (\(host))"
    }
}
