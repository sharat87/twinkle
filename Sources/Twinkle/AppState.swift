import AppKit
import CryptoKit
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

    /// Set by `--profile <folder>`: a separate Twinkle, for testing, that
    /// keeps everything in that folder and nothing in the usual one. Its web
    /// data stores and compiled filter lists are its own too, and the debug
    /// notifications it listens for carry the folder's path.
    let profile: String?
    /// A random id kept in the profile folder; WebKit's data stores for the
    /// profile are derived from it, so a deleted folder starts afresh.
    private var profileID: UUID?

    private init() {
        do {
            if let path = Self.profileArgument() {
                let url = URL(fileURLWithPath: Home.expand(path)).standardizedFileURL
                files = try FileStore(directory: url)
                profile = Self.realPath(url.path)
                profileID = Self.loadProfileID(files)
            } else {
                let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                files = try FileStore(directory: support.appendingPathComponent("Twinkle", isDirectory: true))
                profile = nil
            }
        } catch {
            fatalError("Can't create Twinkle's folder: \(error)")
        }
        Self.lockOrExit(files.url(Self.lockFile))
        reload()
    }

    /// Held, never written, for as long as Twinkle runs: two copies on the
    /// same data would overwrite each other's session and history. build.sh
    /// also finds a profile's copy by it (lsof), since a restarted one has no
    /// `--profile` argument to go by.
    static let lockFile = "instance.lock"

    private static func lockOrExit(_ url: URL) {
        let fd = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let alert = NSAlert()
            alert.messageText = "Twinkle is already running"
            alert.informativeText = "Another copy is using \(url.deletingLastPathComponent().path)."
            alert.runModal()
            exit(1)
        }
    }

    /// `--profile <folder>` or `--profile=<folder>`.
    static func profileArgument() -> String? {
        if let handoff = Relaunch.handoff { return handoff }
        let args = CommandLine.arguments
        for (i, arg) in args.enumerated() {
            if arg == "--profile", i + 1 < args.count { return args[i + 1] }
            if arg.hasPrefix("--profile=") { return String(arg.dropFirst("--profile=".count)) }
        }
        return nil
    }

    private static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func loadProfileID(_ files: FileStore) -> UUID {
        let name = "profile-id"
        if let text = try? String(contentsOf: files.url(name), encoding: .utf8),
           let id = UUID(uuidString: text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return id
        }
        let id = UUID()
        try? (id.uuidString + "\n").write(to: files.url(name), atomically: true, encoding: .utf8)
        return id
    }

    /// A profile's own id for a container's store (nil: no container), so a
    /// profile never shares cookies with the usual Twinkle, even when its
    /// containers.json was copied from there.
    private func storeID(_ container: UUID?) -> UUID? {
        guard let profileID else { return container }
        let key = profileID.uuidString + (container?.uuidString ?? "default")
        var bytes = Array(SHA256.hash(data: Data(key.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return NSUUID(uuidBytes: bytes) as UUID
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
                containersLoaded = true
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

    /// containers.json was read without an error at least once.
    private var containersLoaded = false

    /// Deletes the WebKit data stores (cookies, storage, cache) of containers
    /// no longer in containers.json, and of old test profiles. Only the usual
    /// Twinkle does this, at launch, and only once containers.json has been
    /// read cleanly, so a broken file never costs a container its cookies.
    func removeOrphanedStores() async {
        guard profile == nil, containersLoaded else { return }
        let keep = Set(containers.map(\.id))
        var removed = 0
        for id in await WKWebsiteDataStore.allDataStoreIdentifiers where !keep.contains(id) {
            if (try? await WKWebsiteDataStore.remove(forIdentifier: id)) != nil { removed += 1 }
        }
        if removed > 0 { Status.show("Removed the cookies and site data of \(removed) deleted container\(removed == 1 ? "" : "s").") }
    }

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
        guard let id else {
            if let own = storeID(nil) { return defaultProfileStore(own) }
            return .default()
        }
        if let store = stores[id] { return store }
        let store = isTemporary(id) ? WKWebsiteDataStore.nonPersistent() : WKWebsiteDataStore(forIdentifier: storeID(id) ?? id)
        stores[id] = store
        return store
    }

    private var profileDefaultStore: WKWebsiteDataStore?
    private func defaultProfileStore(_ id: UUID) -> WKWebsiteDataStore {
        if let store = profileDefaultStore { return store }
        let store = WKWebsiteDataStore(forIdentifier: id)
        profileDefaultStore = store
        return store
    }

    /// The window's autosave names in user defaults, kept apart per profile.
    func defaultsName(_ name: String) -> String {
        profile.map { "\(name) \($0)" } ?? name
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
    private var bookmarksDate: Date?
    private var bookmarkIndexCache: HistoryIndex?

    private func loadBookmarks() {
        let date = files.modificationDate(Bookmark.file)
        guard date != bookmarksDate else { return }
        bookmarksDate = date
        bookmarks = (try? files.load([Bookmark].self, from: Bookmark.file)) ?? []
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
        let path = Home.expand(settings.downloadsDirectory)
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
    static func show(_ text: String, file: URL? = nil, symbol: String? = nil,
                     cancel: (() -> Void)? = nil, sticky: Bool = false) {
        NSLog("Twinkle: %@", text)
        var info: [String: Any] = ["text": text, "sticky": sticky]
        if let file { info["file"] = file }
        if let symbol { info["symbol"] = symbol }
        if let cancel { info["cancel"] = cancel }
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
