import Foundation

/// Page zoom: the steps ⌘+ and ⌘- move through, and the level remembered
/// for each site in `zoom.json` (`{"example.com": 1.25}`). A site's level
/// covers its subdomains, the most specific entry winning, like containers.
public struct ZoomLevels: Codable, Equatable, Sendable {
    public var sites: [String: Double]

    public init(sites: [String: Double] = [:]) {
        self.sites = sites
    }

    public static let steps: [Double] = [0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3]

    /// The next step in or out from `level`, which needn't be a step itself.
    public static func step(from level: Double, in zoomIn: Bool) -> Double {
        let next = zoomIn
            ? steps.first { $0 > level + 0.001 }
            : steps.last { $0 < level - 0.001 }
        return next ?? (zoomIn ? steps.last! : steps.first!)
    }

    public func level(forHost host: String?) -> Double {
        guard let host, !host.isEmpty else { return 1 }
        let match = sites.keys.filter { Hosts.covers($0, host) }.max { $0.count < $1.count }
        return match.flatMap { sites[$0] } ?? 1
    }

    /// Remembers `level` for `host`'s site; 100% is forgotten rather than
    /// stored. Returns the site key it was stored under.
    @discardableResult
    public mutating func set(_ level: Double, forHost host: String) -> String {
        let key = Hosts.siteKey(host)
        // A more general entry (example.com for www.example.com) is the one
        // to change, so the level stays the same across the site.
        let target = sites.keys.filter { Hosts.covers($0, host) }.max { $0.count < $1.count } ?? key
        if abs(level - 1) < 0.001 { sites[target] = nil } else { sites[target] = level }
        return target
    }

    // The file is the plain map.
    public init(from decoder: Decoder) throws {
        sites = try decoder.singleValueContainer().decode([String: Double].self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(sites)
    }
}
