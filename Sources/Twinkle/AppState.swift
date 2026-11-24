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
        return containers.first { $0.id == id }
    }

    @discardableResult
    func addContainer(named name: String) -> Container {
        let list = ContainerList(containers: containers)
        let container = Container(name: name, color: list.nextColor())
        containers.append(container)
        try? files.save(ContainerList(containers: containers), to: Self.containersFile)
        containersDate = files.modificationDate(Self.containersFile)
        NotificationCenter.default.post(name: .containersChanged, object: nil)
        return container
    }

    /// The cookie jar, storage and cache for a container. nil is "no
    /// container": WebKit's default store. One instance per container, shared
    /// by all its tabs, so they also share a network process.
    func dataStore(for id: UUID?) -> WKWebsiteDataStore {
        guard let id else { return .default() }
        if let store = stores[id] { return store }
        let store = WKWebsiteDataStore(forIdentifier: id)
        stores[id] = store
        return store
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
