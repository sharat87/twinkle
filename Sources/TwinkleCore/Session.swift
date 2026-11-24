import Foundation

/// One tab as it is saved between launches.
public struct SavedTab: Codable, Equatable, Sendable {
    public var url: String
    public var title: String
    /// nil: no container (the default store).
    public var container: UUID?

    public init(url: String, title: String, container: UUID?) {
        self.url = url
        self.title = title
        self.container = container
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
