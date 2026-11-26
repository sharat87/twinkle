import CryptoKit
import Foundation
import TwinkleCore
import WebKit

/// The ad blocker. Filter lists are converted to WebKit content-blocker rules
/// and compiled once; WebKit then enforces them inside its network process,
/// before a request is made, so blocking costs nothing per request.
///
/// Sources, each compiled into its own list:
/// - a small built-in list,
/// - every URL in `filterLists` in settings.json, downloaded to filters/cache/,
/// - filters/custom.txt, your own rules.
@MainActor
final class Blocker {
    static let shared = Blocker()

    /// A profile compiles its lists into its own folder, so it can't replace
    /// or delete the usual Twinkle's.
    private let store: WKContentRuleListStore = AppState.shared.profile == nil
        ? WKContentRuleListStore.default()!
        : WKContentRuleListStore(url: AppState.shared.files.directory.appendingPathComponent("filters/compiled", isDirectory: true))!
    private(set) var lists: [WKContentRuleList] = []

    private let controllers = NSHashTable<WKUserContentController>.weakObjects()
    private let applied = NSMapTable<WKUserContentController, NSNumber>.weakToStrongObjects()
    private let hosts = NSMapTable<WKUserContentController, NSString>.weakToStrongObjects()

    private var ready = false
    private var waiting: [() -> Void] = []
    private var refreshing = false
    private var lastFilterLists: [String] = []

    var filtersDirectory: URL { AppState.shared.files.directory.appendingPathComponent("filters", isDirectory: true) }
    var customFile: URL { filtersDirectory.appendingPathComponent("custom.txt") }
    private var cacheDirectory: URL { filtersDirectory.appendingPathComponent("cache", isDirectory: true) }

    func start() {
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: customFile.path) {
            try? Self.customTemplate.write(to: customFile, atomically: true, encoding: .utf8)
        }
        lastFilterLists = AppState.shared.settings.filterLists
        // Pages wait for the lists at launch, but never more than a second.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.markReady() }
        Task {
            await rebuild()
            markReady()
            await refresh(force: false)
        }
        NotificationCenter.default.addObserver(forName: .settingsChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingsChanged() }
        }
    }

    /// Runs `load` once the lists are ready (or a second has passed), so the
    /// first pages of a launch don't slip their ads in before the blocker.
    func whenReady(_ load: @escaping () -> Void) {
        if ready { load() } else { waiting.append(load) }
    }

    private func markReady() {
        guard !ready else { return }
        ready = true
        let pending = waiting
        waiting = []
        pending.forEach { $0() }
    }

    /// Every tab's content controller is registered so new lists reach it.
    func register(_ controller: WKUserContentController) {
        guard !controllers.contains(controller) else { return }
        controllers.add(controller)
        apply(to: controller, force: true)
    }

    /// Called as a tab heads to a new page: the lists go on or off for that
    /// site before its first request.
    func tune(_ controller: WKUserContentController, host: String?) {
        hosts.setObject(host.map { $0 as NSString }, forKey: controller)
        apply(to: controller, force: false)
    }

    private func apply(to controller: WKUserContentController, force: Bool) {
        let host = hosts.object(forKey: controller) as String?
        let on = AppState.shared.blocks(on: host)
        if !force, applied.object(forKey: controller)?.boolValue == on { return }
        controller.removeAllContentRuleLists()
        if on { lists.forEach(controller.add) }
        applied.setObject(NSNumber(value: on), forKey: controller)
    }

    private func applyEverywhere() {
        for controller in controllers.allObjects { apply(to: controller, force: true) }
    }

    private func settingsChanged() {
        let lists = AppState.shared.settings.filterLists
        if lists != lastFilterLists {
            lastFilterLists = lists
            Task {
                await rebuild()
                await refresh(force: false)
            }
        } else {
            for controller in controllers.allObjects { apply(to: controller, force: false) }
        }
    }

    // MARK: Compiling

    func rebuild() async {
        var sources: [(name: String, text: String)] = [("built-in list", BuiltinFilters.text)]
        for url in AppState.shared.settings.filterLists {
            if let text = try? String(contentsOf: cacheFile(for: url), encoding: .utf8) {
                sources.append((url, text))
            }
        }
        if let custom = try? String(contentsOf: customFile, encoding: .utf8) {
            sources.append(("custom.txt", custom))
        }

        var compiled: [WKContentRuleList] = []
        for source in sources {
            if let list = await compiledList(source.text, name: source.name) { compiled.append(list) }
        }
        lists = compiled
        applyEverywhere()
        removeStale(keeping: Set(compiled.compactMap(\.identifier)))
    }

    private func compiledList(_ text: String, name: String) async -> WKContentRuleList? {
        let id = "twinkle-v\(FilterConverter.version)-" + Self.hash(text)
        if let found = await lookUp(id) { return found }

        // Converting and compiling a big list is a few seconds of one core.
        // Without this, App Nap stretches that to minutes when Twinkle isn't
        // the frontmost app.
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled], reason: "Compiling filter lists")
        defer { ProcessInfo.processInfo.endActivity(activity) }

        let started = Date()
        let result = await Task.detached(priority: .utility) { FilterConverter.convert(text) }.value
        guard !result.rules.isEmpty else { return nil }
        do {
            let list = try await compile(id, rules: result.rules)
            NSLog("Twinkle: compiled %@: %d rules, %d skipped, %.1fs", name, result.rules.count, result.skipped, Date().timeIntervalSince(started))
            return list
        } catch {
            // Most likely a selector WebKit rejected. Keep the network rules.
            NSLog("Twinkle: compiling %@ failed (%@); retrying without element hiding", name, error.localizedDescription)
            let networkOnly = result.rules.filter { $0.action.type != "css-display-none" }
            if let list = try? await compile(id, rules: networkOnly) {
                Status.show("\(name): element hiding rules failed to compile; network blocking still works.")
                return list
            }
            Status.show("\(name) could not be compiled: \(error.localizedDescription)", sticky: true)
            return nil
        }
    }

    private func lookUp(_ id: String) async -> WKContentRuleList? {
        await withCheckedContinuation { continuation in
            store.lookUpContentRuleList(forIdentifier: id) { list, _ in
                continuation.resume(returning: list)
            }
        }
    }

    private func compile(_ id: String, rules: [ContentRule]) async throws -> WKContentRuleList {
        let json = String(decoding: try JSONEncoder().encode(rules), as: UTF8.self)
        return try await withCheckedThrowingContinuation { continuation in
            store.compileContentRuleList(forIdentifier: id, encodedContentRuleList: json) { list, error in
                if let list {
                    continuation.resume(returning: list)
                } else {
                    continuation.resume(throwing: error ?? CocoaError(.featureUnsupported))
                }
            }
        }
    }

    private func removeStale(keeping: Set<String>) {
        store.getAvailableContentRuleListIdentifiers { [store] ids in
            for id in ids ?? [] where id.hasPrefix("twinkle-") && !keeping.contains(id) {
                store.removeContentRuleList(forIdentifier: id) { _ in }
            }
        }
    }

    // MARK: Downloading lists

    /// Downloads lists older than `filterListRefreshDays` (or all, if forced)
    /// and recompiles if anything changed.
    func refresh(force: Bool) async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }

        let settings = AppState.shared.settings
        var changed = false
        var failures: [String] = []
        for source in settings.filterLists {
            guard let url = URL(string: source) else { continue }
            let file = cacheFile(for: source)
            if !force, let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
               Date().timeIntervalSince(date) < settings.filterListRefreshDays * 86_400 {
                continue
            }
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else {
                    failures.append(url.host() ?? source)
                    continue
                }
                let old = try? Data(contentsOf: file)
                try data.write(to: file, options: .atomic)
                if old != data { changed = true }
            } catch {
                failures.append(url.host() ?? source)
            }
        }
        if changed {
            await rebuild()
            Status.show("Filter lists updated.")
        }
        if !failures.isEmpty {
            Status.show("Couldn't download filter lists from \(failures.joined(separator: ", ")).")
        }
    }

    private func cacheFile(for source: String) -> URL {
        cacheDirectory.appendingPathComponent(Self.hash(source) + ".txt")
    }

    private static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private static let customTemplate = """
    ! Your own filter rules, in EasyList / uBlock Origin syntax. Examples:
    !
    !   ||annoying-widget.example^          block a domain
    !   ||cdn.example/ads/*$script          block scripts under a path
    !   news.example##.newsletter-popup     hide an element on one site
    !   ##.cookie-banner                    hide an element everywhere
    !   @@||cdn.example/needed.js           never block this
    !
    ! Saved changes apply after View > Reload Filter Lists.

    """
}
