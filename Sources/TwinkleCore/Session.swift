import Foundation

/// One tab as it is saved between launches.
public struct SavedTab: Codable, Equatable, Sendable {
    /// Stays the same across launches.
    public var id: UUID
    public var url: String
    public var title: String
    /// nil: no container (the default store).
    public var container: UUID?

    public init(id: UUID = UUID(), url: String, title: String, container: UUID?) {
        self.id = id
        self.url = url
        self.title = title
        self.container = container
    }

    enum CodingKeys: String, CodingKey { case id, url, title, container }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        url = try c.decode(String.self, forKey: .url)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        container = try c.decodeIfPresent(UUID.self, forKey: .container)
    }
}

/// `session.json`: the open tabs, restored at launch. Only the selected tab
/// loads straight away; the rest load when you first click them.
public struct Session: Codable, Equatable, Sendable {
    public var tabs: [SavedTab]
    public var selected: Int

    public init(tabs: [SavedTab], selected: Int) {
        self.tabs = tabs
        self.selected = selected
    }
}

