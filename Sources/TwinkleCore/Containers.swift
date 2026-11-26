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
    /// AppleScript may open, change, close and run JavaScript in this
    /// container's tabs. Other containers' tabs only show their address and
    /// title to scripts.
    public var appleScriptEnabled: Bool

    public init(id: UUID = UUID(), name: String, color: String, appleScriptEnabled: Bool = false) {
        self.id = id
        self.name = name
        self.color = color
        self.appleScriptEnabled = appleScriptEnabled
    }

    enum CodingKeys: String, CodingKey { case id, name, color, appleScriptEnabled }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        color = try c.decodeIfPresent(String.self, forKey: .color) ?? ContainerList.palette[0]
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

    /// A colour not used yet, if there is one.
    public func nextColor() -> String {
        let used = Set(containers.map { $0.color.uppercased() })
        return Self.palette.first { !used.contains($0) }
            ?? Self.palette[containers.count % Self.palette.count]
    }
}
