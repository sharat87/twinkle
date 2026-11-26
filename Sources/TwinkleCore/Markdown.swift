import Foundation

public enum Markdown {
    /// `[title](address)`: brackets in the title escaped, and parentheses
    /// and spaces in the address encoded so the link doesn't end early. A
    /// page without a title uses its host.
    public static func link(title: String, url: URL) -> String {
        var text = title.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        if text.isEmpty { text = url.host() ?? url.absoluteString }
        var escaped = ""
        for c in text {
            if "\\[]".contains(c) { escaped.append("\\") }
            escaped.append(c)
        }
        var address = ""
        for c in url.absoluteString {
            switch c {
            case "(": address += "%28"
            case ")": address += "%29"
            case " ": address += "%20"
            case "<": address += "%3C"
            case ">": address += "%3E"
            default: address.append(c)
            }
        }
        return "[\(escaped)](\(address))"
    }
}
