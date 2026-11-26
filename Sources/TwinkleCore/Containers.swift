import Foundation

/// A container: its own cookies, storage and cache, like Firefox's
/// Multi-Account Containers. Tabs in different containers can sit side by side
/// in one window and be signed in to different accounts on the same site.
///
/// The `id` is what the engine's data store is keyed on, so renaming or
/// recolouring a container keeps its data.
public struct Container: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    /// `#RRGGBB`.
    public var color: String
    /// Sites that always open in this container, like Firefox's "Always Open
    /// in". An entry covers its subdomains.
    public var sites: [String]
    /// AppleScript may open, change, close and run JavaScript in this
    /// container's tabs. Other containers' tabs only show their address and
    /// title to scripts.
    public var appleScriptEnabled: Bool

    public init(id: UUID = UUID(), name: String, color: String, sites: [String] = [],
                appleScriptEnabled: Bool = false) {
        self.id = id
        self.name = name
        self.color = color
        self.sites = sites
        self.appleScriptEnabled = appleScriptEnabled
    }

    enum CodingKeys: String, CodingKey { case id, name, color, sites, appleScriptEnabled }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        color = try c.decodeIfPresent(String.self, forKey: .color) ?? ContainerList.palette[0]
        sites = try c.decodeIfPresent([String].self, forKey: .sites) ?? []
        appleScriptEnabled = try c.decodeIfPresent(Bool.self, forKey: .appleScriptEnabled) ?? false
    }
}

/// The `containers` in settings.json.
public struct ContainerList: Codable, Equatable, Sendable {
    public var containers: [Container]

    public init(containers: [Container]) {
        self.containers = containers
    }

    public static let palette = [
        "#3B82F6", // blue
        "#14B8A6", // turquoise
        "#22C55E", // green
        "#EAB308", // yellow
        "#F97316", // orange
        "#EF4444", // red
        "#EC4899", // pink
        "#A855F7", // purple
    ]

    public static let starter = ContainerList(containers: [
        Container(name: "Personal", color: palette[0]),
        Container(name: "Work", color: palette[4]),
    ])

    /// The container `host` is assigned to. When several entries cover it,
    /// the longest (most specific) wins: "mail.example.com" in Work beats
    /// "example.com" in Personal.
    public func container(forHost host: String?) -> Container? {
        assignment(forHost: host)?.container
    }

    /// The container and the `sites` entry that assigns `host` to it.
    public func assignment(forHost host: String?) -> (container: Container, site: String)? {
        guard let host, !host.isEmpty else { return nil }
        var best: (container: Container, site: String)?
        for container in containers {
            for site in container.sites where Hosts.covers(site, host) {
                if site.count > (best?.site.count ?? -1) { best = (container, site) }
            }
        }
        return best
    }

    /// Assigns `host`'s site to `container`, or to none when nil, removing
    /// it from any other container.
    public mutating func assign(host: String, to container: UUID?) {
        let key = Hosts.siteKey(host)
        for i in containers.indices {
            containers[i].sites.removeAll { Hosts.siteKey($0) == key }
            if containers[i].id == container { containers[i].sites.append(key) }
        }
    }

    /// A colour not used yet, if there is one.
    public func nextColor() -> String {
        let used = Set(containers.map { $0.color.uppercased() })
        return Self.palette.first { !used.contains($0) }
            ?? Self.palette[containers.count % Self.palette.count]
    }
}
