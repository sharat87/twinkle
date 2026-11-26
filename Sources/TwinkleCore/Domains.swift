import Foundation

/// What settings.json's `domains` keeps for one domain, like
/// `"example.com": {"zoom": 1.25}`. Every key is optional; a missing one
/// means the default.
public struct DomainSettings: Codable, Equatable, Sendable {
    /// Page zoom, 1 being 100%.
    public var zoom: Double?

    public init(zoom: Double? = nil) {
        self.zoom = zoom
    }

    public var isEmpty: Bool { self == DomainSettings() }
}

/// settings.json's `domains`: settings per domain. An entry covers its
/// subdomains, and for each setting the most specific entry that has it wins,
/// like containers' `sites`.
public struct Domains: Codable, Equatable, Sendable {
    public var entries: [String: DomainSettings]

    public init(_ entries: [String: DomainSettings] = [:]) {
        self.entries = entries
    }

    /// The most specific entry covering `host` that has `setting`.
    private func key<T>(for host: String, having setting: KeyPath<DomainSettings, T?>) -> String? {
        entries.filter { Hosts.covers($0.key, host) && $0.value[keyPath: setting] != nil }
            .keys.max { $0.count < $1.count }
    }

    public func value<T>(_ setting: KeyPath<DomainSettings, T?>, forHost host: String?) -> T? {
        guard let host, !host.isEmpty, let key = key(for: host, having: setting) else { return nil }
        return entries[key]?[keyPath: setting]
    }

    /// Sets `setting` for `host`'s site (nil removes it). The entry that
    /// already decides it for `host` is the one changed, so a level set on
    /// www.example.com stays the same across example.com. Entries left empty
    /// are removed. Returns the key it was stored under.
    @discardableResult
    public mutating func set<T>(_ setting: WritableKeyPath<DomainSettings, T?>, _ value: T?, forHost host: String) -> String {
        let target = key(for: host, having: setting) ?? Hosts.siteKey(host)
        var entry = entries[target] ?? DomainSettings()
        entry[keyPath: setting] = value
        entries[target] = entry.isEmpty ? nil : entry
        return target
    }

    public func zoom(forHost host: String?) -> Double {
        value(\.zoom, forHost: host) ?? 1
    }

    /// 100% is forgotten rather than stored.
    @discardableResult
    public mutating func setZoom(_ level: Double, forHost host: String) -> String {
        set(\.zoom, abs(level - 1) < 0.001 ? nil : level, forHost: host)
    }

    // In the file it's the plain map.
    public init(from decoder: Decoder) throws {
        entries = try decoder.singleValueContainer().decode([String: DomainSettings].self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(entries)
    }
}
