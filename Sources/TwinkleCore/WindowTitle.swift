import Foundation

/// What the window is called. KeePassXC auto-type matches on the window title,
/// so the page's host is part of it: an entry with a window association like
/// `*github.com*` fills on any GitHub page without a browser extension.
public enum WindowTitle {
    public static let appName = "Twinkle"

    public static func make(title: String, url: URL?, format: String) -> String {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = url?.host(percentEncoded: false) ?? ""
        guard let url, !host.isEmpty else { return title.isEmpty ? appName : title }
        let values = [
            "title": title.isEmpty ? host : title,
            "host": host,
            "url": url.absoluteString,
        ]
        return fill(format, values)
    }

    /// Replaces `{name}` tokens in one pass, so a page title that happens to
    /// contain `{host}` isn't expanded again.
    static func fill(_ format: String, _ values: [String: String]) -> String {
        var out = ""
        var rest = Substring(format)
        while let open = rest.firstIndex(of: "{") {
            out += rest[..<open]
            let after = rest[rest.index(after: open)...]
            if let close = after.firstIndex(of: "}"), let value = values[String(after[..<close])] {
                out += value
                rest = after[after.index(after: close)...]
            } else {
                out += "{"
                rest = after
            }
        }
        return out + rest
    }
}
