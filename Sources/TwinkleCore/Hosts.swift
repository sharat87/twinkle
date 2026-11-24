import Foundation

/// Host names as settings use them: an entry covers that host and every
/// subdomain of it, so "example.com" covers "www.example.com" too.
public enum Hosts {
    public static func covers(_ entry: String, _ host: String) -> Bool {
        let entry = normalize(entry), host = normalize(host)
        guard !entry.isEmpty else { return false }
        return host == entry || host.hasSuffix("." + entry)
    }

    /// Lowercased, without a trailing dot or a leading "www.", which is how
    /// Twinkle writes hosts into settings: "www.example.com" is saved as
    /// "example.com" so it covers the rest of the site.
    public static func siteKey(_ host: String) -> String {
        let h = normalize(host)
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }

    static func normalize(_ host: String) -> String {
        var h = host.trimmingCharacters(in: .whitespaces).lowercased()
        while h.hasSuffix(".") { h.removeLast() }
        return h
    }
}
