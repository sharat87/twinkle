import Foundation

/// `settings.json`. Every key is optional in the file; missing ones take the
/// defaults below, so the file only needs what you want to change.
public struct Settings: Codable, Equatable, Sendable {
    /// Search engines keyed by prefix (`""` is the default; another key like
    /// `"!"` or `"ai"` matches `<key> <query>`). `%s` becomes the query.
    public var search: [String: String]
    /// Where downloads are saved. `~` is expanded. Default: ~/Downloads.
    public var downloadsDirectory: String
    /// Filter lists (EasyList/uBlock syntax, or hosts files) to download.
    public var filterLists: [String]
    /// How often the filter lists are downloaded again.
    public var filterListRefreshDays: Double
    /// Background tabs left alone this long are unloaded to free memory, and
    /// load again (with their history) when clicked. 0 turns it off.
    public var unloadTabsAfterMinutes: Double
    /// How long history is kept. 0 keeps no history at all.
    public var historyDays: Double
    /// The monospace font: what pages asking for `monospace` get, and what
    /// plain text and JSON are shown in. Size in CSS pixels.
    public var monospaceFont: String
    public var monospaceFontSize: Double

    public static let defaultSearchURL = "https://duckduckgo.com/?q=%s"

    public static let defaultFilterLists = [
        "https://easylist.to/easylist/easylist.txt",
        "https://easylist.to/easylist/easyprivacy.txt",
    ]

    public init() {
        search = ["": Settings.defaultSearchURL]
        downloadsDirectory = "~/Downloads"
        filterLists = Settings.defaultFilterLists
        filterListRefreshDays = 4
        unloadTabsAfterMinutes = 30
        historyDays = 180
        monospaceFont = "Monaco"
        monospaceFontSize = 18
    }

    enum CodingKeys: String, CodingKey {
        case search, downloadsDirectory, filterLists, filterListRefreshDays,
             unloadTabsAfterMinutes, historyDays, monospaceFont, monospaceFontSize
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        search = try c.decodeIfPresent([String: String].self, forKey: .search) ?? d.search
        downloadsDirectory = try c.decodeIfPresent(String.self, forKey: .downloadsDirectory) ?? d.downloadsDirectory
        filterLists = try c.decodeIfPresent([String].self, forKey: .filterLists) ?? d.filterLists
        filterListRefreshDays = try c.decodeIfPresent(Double.self, forKey: .filterListRefreshDays) ?? d.filterListRefreshDays
        unloadTabsAfterMinutes = try c.decodeIfPresent(Double.self, forKey: .unloadTabsAfterMinutes) ?? d.unloadTabsAfterMinutes
        historyDays = try c.decodeIfPresent(Double.self, forKey: .historyDays) ?? d.historyDays
        monospaceFont = try c.decodeIfPresent(String.self, forKey: .monospaceFont) ?? d.monospaceFont
        monospaceFontSize = try c.decodeIfPresent(Double.self, forKey: .monospaceFontSize) ?? d.monospaceFontSize
    }
}

/// `settings.json` as a whole: the settings, the containers under
/// `"containers"` and settings per domain under `"domains"`. `containers` is
/// nil when the key is missing, which is told apart from an empty list so a
/// deleted key never costs a container its data.
public struct SettingsFile: Codable, Equatable, Sendable {
    public var settings: Settings
    public var containers: [Container]?
    public var domains: Domains

    public init(settings: Settings = Settings(), containers: [Container]? = ContainerList.starter.containers,
                domains: Domains = Domains()) {
        self.settings = settings
        self.containers = containers
        self.domains = domains
    }

    enum CodingKeys: String, CodingKey { case containers, domains }

    public init(from decoder: Decoder) throws {
        settings = try Settings(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if !c.contains(.containers) {
            containers = nil
        } else if try c.decodeNil(forKey: .containers) {
            containers = nil
        } else if let legacy = try? c.decode([Container].self, forKey: .containers) {
            containers = legacy
        } else {
            let values = try c.decode([String: ContainerSettingsValue].self, forKey: .containers)
            containers = values.sorted { $0.key < $1.key }.map { entry in
                let value = entry.value
                return Container(id: value.id, name: entry.key, color: value.color,
                                 appleScriptEnabled: value.appleScriptEnabled)
            }
        }
        domains = try c.decodeIfPresent(Domains.self, forKey: .domains) ?? Domains()
    }

    public func encode(to encoder: Encoder) throws {
        try settings.encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        if let containers {
            var values: [String: ContainerSettingsValue] = [:]
            for container in containers {
                guard values[container.name] == nil else {
                    throw EncodingError.invalidValue(
                        containers,
                        .init(codingPath: encoder.codingPath + [CodingKeys.containers],
                              debugDescription: "Container names must be unique.")
                    )
                }
                values[container.name] = ContainerSettingsValue(container: container)
            }
            try c.encode(values, forKey: .containers)
        }
        try c.encode(domains, forKey: .domains)
    }
}

private struct ContainerSettingsValue: Codable {
    var id: UUID
    var color: String
    var appleScriptEnabled: Bool

    init(container: Container) {
        id = container.id
        color = container.color
        appleScriptEnabled = container.appleScriptEnabled
    }

    enum CodingKeys: String, CodingKey { case id, color, appleScriptEnabled }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        color = try c.decodeIfPresent(String.self, forKey: .color) ?? ContainerList.palette[0]
        appleScriptEnabled = try c.decodeIfPresent(Bool.self, forKey: .appleScriptEnabled) ?? false
    }
}
