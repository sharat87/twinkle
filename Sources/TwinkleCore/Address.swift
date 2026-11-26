import Foundation

/// Turns what was typed in the address field into a URL to load: an address
/// if it looks like one, otherwise a search.
public enum Address {
    public static func resolve(_ raw: String, searchTemplate: String) -> URL? {
        let input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return nil }
        if let url = asURL(input) { return url }
        return search(input, template: searchTemplate)
    }

    public static func search(_ query: String, template: String) -> URL? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#/;")
        let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) ?? query
        return URL(string: template.replacingOccurrences(of: "%s", with: encoded))
    }

    /// Whether two addresses are the same page, for reusing an open tab:
    /// scheme and host ignore case, and `https://a.com` is `https://a.com/`.
    public static func samePage(_ a: URL, _ b: URL) -> Bool {
        key(a) == key(b)
    }

    static func key(_ url: URL) -> String {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        parts.scheme = parts.scheme?.lowercased()
        parts.host = parts.host?.lowercased()
        if parts.host != nil, parts.path.isEmpty { parts.path = "/" }
        return parts.string ?? url.absoluteString
    }

    public static func asURL(_ input: String) -> URL? {
        let lower = input.lowercased()
        for prefix in ["about:", "data:", "file:"] where lower.hasPrefix(prefix) {
            return URL(string: input)
        }
        if input.contains(where: \.isWhitespace) { return nil }
        if let schemeEnd = input.range(of: "://") {
            let scheme = input[..<schemeEnd.lowerBound]
            guard !scheme.isEmpty, scheme.allSatisfy({ $0.isLetter || $0.isNumber || "+.-".contains($0) }) else { return nil }
            return URL(string: input)
        }
        guard let host = host(of: input), looksLikeHost(host, hasPort: hasPort(input)) else { return nil }
        let scheme = isLocal(host) ? "http" : "https"
        return URL(string: "\(scheme)://\(input)")
    }

    /// The host part of something like `user@example.com:8080/path?q#f`.
    static func host(of input: String) -> String? {
        var rest = Substring(input)
        if let end = rest.firstIndex(where: { "/?#".contains($0) }) { rest = rest[..<end] }
        if let at = rest.lastIndex(of: "@") { rest = rest[rest.index(after: at)...] }
        if rest.hasPrefix("[") {
            // IPv6 literal.
            guard let close = rest.firstIndex(of: "]") else { return nil }
            return String(rest[...close])
        }
        if let colon = rest.firstIndex(of: ":") {
            let port = rest[rest.index(after: colon)...]
            guard !port.isEmpty, port.allSatisfy(\.isNumber) else { return nil }
            rest = rest[..<colon]
        }
        return rest.isEmpty ? nil : String(rest).lowercased()
    }

    static func hasPort(_ input: String) -> Bool {
        guard let h = host(of: input) else { return false }
        return input.lowercased().contains(h + ":")
    }

    static func looksLikeHost(_ host: String, hasPort: Bool) -> Bool {
        if host == "localhost" || host.hasPrefix("[") || isIPv4(host) { return true }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        let validLabels = labels.allSatisfy { label in
            !label.isEmpty && label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
        }
        guard validLabels else { return false }
        // A single word with a port, like `myserver:8080`.
        if labels.count == 1 { return hasPort }
        // `example.com`; the last label has to be a plausible TLD.
        guard let tld = labels.last, tld.count >= 2, tld.allSatisfy(\.isLetter) else { return false }
        return true
    }

    static func isIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { p in
            !p.isEmpty && p.count <= 3 && p.allSatisfy(\.isNumber) && (Int(p) ?? 256) <= 255
        }
    }

    /// The `https:` address to try first for an `http:` one, or nil when it
    /// should load as it is: local hosts, and addresses with a port (an
    /// HTTP server on :8080 seldom answers TLS there).
    public static func httpsUpgrade(_ url: URL) -> URL? {
        guard url.scheme?.lowercased() == "http", url.port == nil,
              let host = url.host()?.lowercased(), !host.isEmpty, !isLocal(host),
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        parts.scheme = "https"
        return parts.url
    }

    /// Hosts that usually don't speak HTTPS: local machines and the LAN.
    static func isLocal(_ host: String) -> Bool {
        if host == "localhost" || host.hasPrefix("[") || isIPv4(host) { return true }
        if !host.contains(".") { return true }
        return [".localhost", ".local", ".lan", ".internal", ".home.arpa", ".test"].contains { host.hasSuffix($0) }
    }
}
