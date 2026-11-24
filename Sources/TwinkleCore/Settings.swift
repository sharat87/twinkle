import Foundation

/// `settings.json`. Every key is optional in the file; missing ones take the
/// defaults below, so the file only needs what you want to change.
public struct Settings: Codable, Equatable, Sendable {
    /// Where words typed in the address field go. `%s` becomes the query.
    public var searchURL: String
    /// The window's title, which KeePassXC auto-type and window managers match
    /// against. `{title}`, `{host}` and `{url}` are replaced.
    public var windowTitleFormat: String
    /// Where downloads are saved. `~` is expanded. Default: ~/Downloads.
    public var downloadsDirectory: String
    /// Master switch for the content blocker.
    public var adBlocking: Bool
    /// Hosts the blocker is off for. A host also covers its subdomains.
    public var adBlockingOffFor: [String]
    /// Filter lists (EasyList/uBlock syntax, or hosts files) to download.
    public var filterLists: [String]
    /// How often the filter lists are downloaded again.
    public var filterListRefreshDays: Double
    /// Background tabs left alone this long are unloaded to free memory, and
    /// load again (with their history) when clicked. 0 turns it off.
    public var unloadTabsAfterMinutes: Double

    public static let defaultFilterLists = [
        "https://easylist.to/easylist/easylist.txt",
        "https://easylist.to/easylist/easyprivacy.txt",
    ]

    public init() {
        searchURL = "https://duckduckgo.com/?q=%s"
        windowTitleFormat = "{title} - {host}"
        downloadsDirectory = "~/Downloads"
        adBlocking = true
        adBlockingOffFor = []
        filterLists = Settings.defaultFilterLists
        filterListRefreshDays = 4
        unloadTabsAfterMinutes = 30
    }

    enum CodingKeys: String, CodingKey {
        case searchURL, windowTitleFormat, downloadsDirectory, adBlocking,
             adBlockingOffFor, filterLists, filterListRefreshDays, unloadTabsAfterMinutes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        searchURL = try c.decodeIfPresent(String.self, forKey: .searchURL) ?? d.searchURL
        windowTitleFormat = try c.decodeIfPresent(String.self, forKey: .windowTitleFormat) ?? d.windowTitleFormat
        downloadsDirectory = try c.decodeIfPresent(String.self, forKey: .downloadsDirectory) ?? d.downloadsDirectory
        adBlocking = try c.decodeIfPresent(Bool.self, forKey: .adBlocking) ?? d.adBlocking
        adBlockingOffFor = try c.decodeIfPresent([String].self, forKey: .adBlockingOffFor) ?? d.adBlockingOffFor
        filterLists = try c.decodeIfPresent([String].self, forKey: .filterLists) ?? d.filterLists
        filterListRefreshDays = try c.decodeIfPresent(Double.self, forKey: .filterListRefreshDays) ?? d.filterListRefreshDays
        unloadTabsAfterMinutes = try c.decodeIfPresent(Double.self, forKey: .unloadTabsAfterMinutes) ?? d.unloadTabsAfterMinutes
    }

    /// Whether the blocker should run on pages from `host`.
    public func blocks(on host: String?) -> Bool {
        guard adBlocking else { return false }
        guard let host, !host.isEmpty else { return true }
        return !adBlockingOffFor.contains { Hosts.covers($0, host) }
    }
}
