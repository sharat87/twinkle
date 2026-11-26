import Foundation

/// What settings.json's `domains` keeps for one domain, like
/// `"example.com": {"zoom": 1.25}`. Every key is optional; a missing one
/// means the default.
public struct DomainSettings: Codable, Equatable, Sendable {
    /// Page zoom, 1 being 100%.
    public var zoom: Double?
    /// Whether the content blocker is off for this domain.
    public var adBlockingOff: Bool?
    /// Name of the container that URLs with this domain open in.
    public var container: String?

    public init(zoom: Double? = nil, adBlockingOff: Bool? = nil, container: String? = nil) {
        self.zoom = zoom
        self.adBlockingOff = adBlockingOff
        self.container = container
    }

    public var isEmpty: Bool { self == DomainSettings() }
}

/// settings.json's `domains`: settings per domain (and `"*"` as a wildcard
/// fallback). An entry covers its subdomains, and for each setting the most
/// specific entry that has it wins.
public struct Domains: Codable, Equatable, Sendable {
    public static let wildcard = "*"

    public var entries: [String: DomainSettings]

    public init(_ entries: [String: DomainSettings] = [:]) {
        self.entries = entries
    }

    /// The most specific domain entry covering `host` that has `setting`.
    private func key<T>(for host: String, having setting: KeyPath<DomainSettings, T?>, excluding excludedKey: String? = nil) -> String? {
        entries.filter {
            $0.key != Self.wildcard && $0.key != excludedKey && Hosts.covers($0.key, host) && $0.value[keyPath: setting] != nil
        }.keys.max { $0.count < $1.count }
    }

    public func entry<T>(_ setting: KeyPath<DomainSettings, T?>, forHost host: String?) -> (value: T, key: String)? {
        if let host, !host.isEmpty, let key = key(for: host, having: setting), let value = entries[key]?[keyPath: setting] {
            return (value, key)
        }
        if let value = entries[Self.wildcard]?[keyPath: setting] {
            return (value, Self.wildcard)
        }
        return nil
    }

    public func value<T>(_ setting: KeyPath<DomainSettings, T?>, forHost host: String?) -> T? {
        entry(setting, forHost: host)?.value
    }

    private func inheritedValue<T>(_ setting: KeyPath<DomainSettings, T?>, forHost host: String, excluding excludedKey: String) -> T? {
        if let key = key(for: host, having: setting, excluding: excludedKey) {
            return entries[key]?[keyPath: setting]
        }
        return entries[Self.wildcard]?[keyPath: setting]
    }

    private mutating func setEntry<T>(_ setting: WritableKeyPath<DomainSettings, T?>, _ value: T?, on target: String) {
        var entry = entries[target] ?? DomainSettings()
        entry[keyPath: setting] = value
        entries[target] = entry.isEmpty ? nil : entry
    }

    /// Sets `setting` for `host`'s site (nil removes it). The entry that
    /// already decides it for `host` is the one changed, so a level set on
    /// www.example.com stays the same across example.com. Entries left empty
    /// are removed. Returns the key it was stored under.
    @discardableResult
    public mutating func set<T>(_ setting: WritableKeyPath<DomainSettings, T?>, _ value: T?, forHost host: String) -> String {
        let target = key(for: host, having: setting) ?? Hosts.siteKey(host)
        setEntry(setting, value, on: target)
        return target
    }

    public func zoom(forHost host: String?) -> Double {
        value(\.zoom, forHost: host) ?? 1
    }

    /// Matches `inheritedValue` (or 1) is forgotten rather than stored.
    @discardableResult
    public mutating func setZoom(_ level: Double, forHost host: String) -> String {
        let target = key(for: host, having: \.zoom) ?? Hosts.siteKey(host)
        let fallback = inheritedValue(\.zoom, forHost: host, excluding: target) ?? 1
        setEntry(\.zoom, abs(level - fallback) < 0.001 ? nil : level, on: target)
        return target
    }

    /// Whether the blocker should run on pages from `host`.
    public func blocks(on host: String?) -> Bool {
        !(value(\.adBlockingOff, forHost: host) ?? false)
    }

    @discardableResult
    public mutating func setAdBlockingOff(_ off: Bool, forHost host: String) -> String {
        let target = key(for: host, having: \.adBlockingOff) ?? Hosts.siteKey(host)
        let fallback = inheritedValue(\.adBlockingOff, forHost: host, excluding: target) ?? false
        setEntry(\.adBlockingOff, off == fallback ? nil : off, on: target)
        return target
    }

    /// The container assigned to `host` and the `domains` entry that matched it.
    public func assignment(forHost host: String?, in containers: [Container]) -> (container: Container, site: String)? {
        guard let (name, site) = entry(\.container, forHost: host), !name.isEmpty else { return nil }
        let match = containers.first { $0.name == name }
            ?? containers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        return match.map { ($0, site) }
    }

    @discardableResult
    public mutating func setContainer(_ name: String?, forHost host: String) -> String {
        let target = Hosts.siteKey(host)
        let fallback = inheritedValue(\.container, forHost: host, excluding: target)
        let stored: String?
        if let name, !name.isEmpty {
            stored = fallback.map { $0.caseInsensitiveCompare(name) == .orderedSame } == true ? nil : name
        } else {
            stored = (fallback?.isEmpty == false) ? "" : nil
        }
        setEntry(\.container, stored, on: target)
        return target
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
