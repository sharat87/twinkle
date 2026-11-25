import AppKit
import TwinkleCore
import WebKit

extension Notification.Name {
    static let settingsChanged = Notification.Name("TwinkleSettingsChanged")
    static let containersChanged = Notification.Name("TwinkleContainersChanged")
    static let status = Notification.Name("TwinkleStatus")
}

/// Settings, containers and the data store for each container. Both files are
/// read again whenever the app comes to the front, so editing them in a text
/// editor takes effect as soon as you switch back.
@MainActor
final class AppState {
    static let shared = AppState()

    let files: FileStore
    private(set) var settings = Settings()
    private(set) var containers: [Container] = []

    private var settingsDate: Date?
    private var containersDate: Date?
    private var settingsBroken = false
    private var stores: [UUID: WKWebsiteDataStore] = [:]

    static let settingsFile = "settings.json"
    static let containersFile = "containers.json"
    static let sessionFile = "session.json"
    static let zoomFile = "zoom.json"

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        do {
            files = try FileStore(directory: support.appendingPathComponent("Twinkle", isDirectory: true))
        } catch {
            fatalError("Can't create Twinkle's folder in Application Support: \(error)")
        }
        reload()
    }

    /// Reads the files again if they changed on disk. Missing files are
    /// written out with defaults so there is something to edit.
    func reload() {
        if !files.exists(Self.settingsFile) { try? files.save(Settings(), to: Self.settingsFile) }
        if !files.exists(Self.containersFile) { try? files.save(ContainerList.starter, to: Self.containersFile) }

        let sDate = files.modificationDate(Self.settingsFile)
        if sDate != settingsDate {
            settingsDate = sDate
            do {
                let loaded = try files.load(Settings.self, from: Self.settingsFile) ?? Settings()
                settingsBroken = false
                if loaded != settings {
                    settings = loaded
                    NotificationCenter.default.post(name: .settingsChanged, object: nil)
                }
            } catch {
                settingsBroken = true
                Status.show("settings.json has an error and was not applied: \(Self.describe(error))", sticky: true)
            }
        }

        let cDate = files.modificationDate(Self.containersFile)
        if cDate != containersDate {
            containersDate = cDate
            do {
                let loaded = try files.load(ContainerList.self, from: Self.containersFile)?.containers ?? []
                if loaded != containers {
                    containers = loaded
                    NotificationCenter.default.post(name: .containersChanged, object: nil)
                }
            } catch {
                Status.show("containers.json has an error and was not applied: \(Self.describe(error))", sticky: true)
            }
        }
    }

    func updateSettings(_ change: (inout Settings) -> Void) {
        guard !settingsBroken else {
            Status.show("Fix settings.json first; Twinkle won't overwrite it while it has an error.", sticky: true)
            return
        }
        change(&settings)
        try? files.save(settings, to: Self.settingsFile)
        settingsDate = files.modificationDate(Self.settingsFile)
        NotificationCenter.default.post(name: .settingsChanged, object: nil)
    }

    // MARK: Containers

    func container(_ id: UUID?) -> Container? {
        guard let id else { return nil }
        return containers.first { $0.id == id } ?? temporaries.first { $0.id == id }
    }

    /// The container a site always opens in, from the containers' `sites`.
    func assignment(forHost host: String?) -> (container: Container, site: String)? {
        ContainerList(containers: containers).assignment(forHost: host)
    }

    /// Makes `host`'s site always open in `container` (nil: in whatever
    /// container the tab is in) and saves containers.json.
    func assign(host: String, to container: UUID?) {
        var list = ContainerList(containers: containers)
        list.assign(host: host, to: container)
        saveContainers(list.containers)
    }

    private func saveContainers(_ list: [Container]) {
        containers = list
        try? files.save(ContainerList(containers: containers), to: Self.containersFile)
        containersDate = files.modificationDate(Self.containersFile)
        NotificationCenter.default.post(name: .containersChanged, object: nil)
    }

    // MARK: Temporary containers

    /// Containers that live only in memory: their cookies and storage are
    /// never written to disk and are gone once their last tab closes. Their
    /// tabs aren't saved in the session.
    private(set) var temporaries: [Container] = []
    private var temporaryCount = 0

    func newTemporaryContainer() -> Container {
        temporaryCount += 1
        let container = Container(name: "Temporary \(temporaryCount)", color: "#8E8E93")
        temporaries.append(container)
        return container
    }

    func isTemporary(_ id: UUID?) -> Bool {
        guard let id else { return false }
        return temporaries.contains { $0.id == id }
    }

    /// Forgets a temporary container, and with it its data store.
    func releaseTemporary(_ id: UUID) {
        temporaries.removeAll { $0.id == id }
        stores[id] = nil
    }

    @discardableResult
    func addContainer(named name: String) -> Container {
        let list = ContainerList(containers: containers)
        let container = Container(name: name, color: list.nextColor())
        saveContainers(containers + [container])
        return container
    }

    /// The cookie jar, storage and cache for a container. nil is "no
    /// container": WebKit's default store. One instance per container, shared
    /// by all its tabs, so they also share a network process.
    func dataStore(for id: UUID?) -> WKWebsiteDataStore {
        guard let id else { return .default() }
        if let store = stores[id] { return store }
        let store = isTemporary(id) ? WKWebsiteDataStore.nonPersistent() : WKWebsiteDataStore(forIdentifier: id)
        stores[id] = store
        return store
    }

    // MARK: History

    static let historyFile = "history.sqlite"

    /// Opened on first use; nil when history is off (historyDays 0).
    private lazy var history: History? = {
        guard settings.historyDays > 0 else { return nil }
        do {
            let history = try History(path: files.url(Self.historyFile).path)
            try? history.forget(before: Date().addingTimeInterval(-settings.historyDays * 86_400))
            historyIndex = HistoryIndex((try? history.all()) ?? [])
            return history
        } catch {
            Status.show("History is unavailable: \(error)", sticky: true)
            return nil
        }
    }()

    /// History in memory, for the address bar. Filled when history opens.
    private(set) var historyIndex = HistoryIndex()

    /// The address bar's view of history: opens it if need be.
    var suggestionIndex: HistoryIndex {
        _ = history
        return historyIndex
    }

    /// Web pages only, and nothing from temporary containers.
    private func recordable(_ url: URL, _ container: UUID?) -> Bool {
        settings.historyDays > 0 && ["http", "https"].contains(url.scheme?.lowercased() ?? "") && !isTemporary(container)
    }

    func recordVisit(_ url: URL, title: String, container: UUID?) {
        guard recordable(url, container) else { return }
        try? history?.recordVisit(url: url.absoluteString, title: title)
        historyIndex.recordVisit(url: url.absoluteString, title: title)
    }

    func recordTitle(_ title: String, for url: URL, container: UUID?) {
        guard recordable(url, container) else { return }
        try? history?.setTitle(title, for: url.absoluteString)
        historyIndex.setTitle(title, for: url.absoluteString)
    }

    /// Pages from another browser, merged in; the in-memory index is
    /// rebuilt. Pages older than `historyDays` are left out.
    func importHistory(_ pages: [HistoryEntry]) throws -> Int {
        guard let history else { return 0 }
        let cutoff = Date().addingTimeInterval(-settings.historyDays * 86_400)
        let recent = pages.filter { $0.lastVisit >= cutoff }
        try history.importPages(recent)
        historyIndex = HistoryIndex((try? history.all()) ?? [])
        bookmarkIndexCache = nil
        return recent.count
    }

    // MARK: Bookmarks

    /// bookmarks.json, searched by the address bar. Read again when it
    /// changes on disk, like the other files.
    private(set) var bookmarks: [Bookmark] = []
    private(set) var bookmarkFolders: [String: String] = [:]
    private var bookmarksDate: Date?
    private var bookmarkIndexCache: HistoryIndex?

    private func loadBookmarks() {
        let date = files.modificationDate(Bookmark.file)
        guard date != bookmarksDate else { return }
        bookmarksDate = date
        bookmarks = (try? files.load([Bookmark].self, from: Bookmark.file)) ?? []
        bookmarkFolders = Dictionary(bookmarks.map { ($0.url, $0.folder) }, uniquingKeysWith: { a, _ in a })
        bookmarkIndexCache = nil
    }

    /// Bookmarks as an index, with visits from history where there are any.
    var bookmarkIndex: HistoryIndex {
        loadBookmarks()
        if let index = bookmarkIndexCache { return index }
        let history = suggestionIndex
        let index = HistoryIndex(bookmarks.map { b in
            history.entry(for: b.url).map { HistoryEntry(url: b.url, title: b.title.isEmpty ? $0.title : b.title,
                                                         visits: $0.visits, lastVisit: $0.lastVisit) }
                ?? HistoryEntry(url: b.url, title: b.title, visits: 0, lastVisit: .distantPast)
        })
        bookmarkIndexCache = index
        return index
    }

    /// Adds bookmarks not already there; returns how many were new.
    func addBookmarks(_ new: [Bookmark]) throws -> Int {
        loadBookmarks()
        var known = Set(bookmarks.map(\.url))
        let added = new.filter { known.insert($0.url).inserted }
        guard !added.isEmpty else { return 0 }
        try files.save(bookmarks + added, to: Bookmark.file)
        bookmarksDate = nil
        loadBookmarks()
        return added.count
    }

    func clearHistory() {
        try? history?.forgetAll()
        historyIndex.removeAll()
    }

    // MARK: Zoom

    private var zoomLevelsCache: ZoomLevels?
    private var zoomDate: Date?

    /// zoom.json, re-read if it was edited by hand.
    private var zoomLevels: ZoomLevels {
        get {
            let date = files.modificationDate(Self.zoomFile)
            if zoomLevelsCache == nil || date != zoomDate {
                zoomDate = date
                zoomLevelsCache = (try? files.load(ZoomLevels.self, from: Self.zoomFile)) ?? zoomLevelsCache ?? ZoomLevels()
            }
            return zoomLevelsCache!
        }
        set {
            zoomLevelsCache = newValue
            try? files.save(newValue, to: Self.zoomFile)
            zoomDate = files.modificationDate(Self.zoomFile)
        }
    }

    func zoom(forHost host: String?) -> Double {
        zoomLevels.level(forHost: host)
    }

    func setZoom(_ level: Double, forHost host: String) {
        zoomLevels.set(level, forHost: host)
    }

    var downloadsDirectory: URL {
        let path = (settings.downloadsDirectory as NSString).expandingTildeInPath
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    static func describe(_ error: Error) -> String {
        if let decoding = error as? DecodingError {
            switch decoding {
            case .dataCorrupted(let c), .typeMismatch(_, let c), .valueNotFound(_, let c), .keyNotFound(_, let c):
                let path = c.codingPath.map(\.stringValue).joined(separator: ".")
                return path.isEmpty ? c.debugDescription : "\(path): \(c.debugDescription)"
            @unknown default:
                break
            }
        }
        return error.localizedDescription
    }
}

/// A line of text at the bottom of the sidebar: downloads, errors, updates.
@MainActor
enum Status {
    static func show(_ text: String, file: URL? = nil, sticky: Bool = false) {
        NSLog("Twinkle: %@", text)
        var info: [String: Any] = ["text": text, "sticky": sticky]
        if let file { info["file"] = file }
        NotificationCenter.default.post(name: .status, object: nil, userInfo: info)
    }
}

extension NSColor {
    convenience init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        let v = UInt32(s, radix: 16) ?? 0x888888
        self.init(
            srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
            green: CGFloat((v >> 8) & 0xFF) / 255,
            blue: CGFloat(v & 0xFF) / 255,
            alpha: 1
        )
    }
}

extension NSImage {
    /// A coloured dot for container menus.
    static func dot(_ color: NSColor, size: CGFloat = 10) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }
    }
}
