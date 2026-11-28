import AppKit
import TwinkleCore
import WebKit

/// AppleScript (Resources/Twinkle.sdef). Any tab's address and title can be
/// read, which is what launchers like Alfred ask for. Opening, changing,
/// closing and running JavaScript need a tab in a container that allows it
/// (`appleScriptEnabled`, or a temporary container a script made), so a
/// script never touches pages or cookies in your other containers. macOS
/// also asks you once per app before it may script Twinkle at all.
@MainActor
enum Scripting {
    static var browser: BrowserWindowController? {
        NSApp.orderedWindows.lazy.compactMap { $0.windowController as? BrowserWindowController }.first
    }

    /// Whether scripts may drive `tab`; if not, the current command fails
    /// with an error saying why.
    static func check(_ tab: Tab) -> Bool {
        if AppState.shared.allowsAppleScript(tab.containerID) { return true }
        let name = AppState.shared.container(tab.containerID)?.name
        fail("The tab is in \(name.map { "the \($0) container" } ?? "no container"), which doesn't allow AppleScript. "
            + "Set \"appleScriptEnabled\": true on a container in settings.json, or open the page with new tab.")
        return false
    }

    static func fail(_ message: String, number: Int = errAEPrivilegeError) {
        guard let command = NSScriptCommand.current() else { return }
        command.scriptErrorNumber = number
        command.scriptErrorString = message
    }

    static func url(_ text: String) -> URL? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespaces)), url.scheme != nil else {
            fail("Not an address: \(text). Give the whole address, like https://example.com.", number: errAEParamMissed)
            return nil
        }
        return url
    }

    /// What `do JavaScript` returns: text, numbers and booleans as they are,
    /// anything else as JSON text.
    /// A result of type "any" has to be a descriptor: Foundation can't
    /// convert a plain string or number to it, and the failure takes the
    /// app down.
    nonisolated static func result(_ value: Any?) -> NSAppleEventDescriptor? {
        switch value {
        case nil, is NSNull: return nil
        case let text as String: return NSAppleEventDescriptor(string: text)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return NSAppleEventDescriptor(boolean: number.boolValue)
            }
            let double = number.doubleValue
            if double == double.rounded(), abs(double) <= Double(Int32.max) {
                return NSAppleEventDescriptor(int32: Int32(double))
            }
            return NSAppleEventDescriptor(double: double)
        case let other?:
            if JSONSerialization.isValidJSONObject(other),
               let data = try? JSONSerialization.data(withJSONObject: other, options: [.sortedKeys, .withoutEscapingSlashes]) {
                return NSAppleEventDescriptor(string: String(decoding: data, as: UTF8.self))
            }
            return NSAppleEventDescriptor(string: String(describing: other))
        }
    }
}

extension NSWindow {
    private var browser: BrowserWindowController? { windowController as? BrowserWindowController }

    @objc var scriptTabs: [Tab] { browser?.tabs ?? [] }
    @objc var scriptActiveTab: Tab? { browser?.current }

    @objc func valueInScriptTabsWithUniqueID(_ id: String) -> Tab? {
        scriptTabs.first { $0.id.uuidString == id }
    }
}

extension Tab {
    @objc var scriptID: String { id.uuidString }
    @objc var scriptTitle: String { title }
    @objc var scriptLoading: Bool { isLoading }
    @objc var scriptContainer: String { AppState.shared.container(containerID)?.name ?? "" }

    @objc var scriptURL: String {
        get { url?.absoluteString ?? "" }
        set {
            guard Scripting.check(self), let url = Scripting.url(newValue) else { return }
            load(url)
        }
    }

    override var objectSpecifier: NSScriptObjectSpecifier? {
        guard let window = host?.window, let windowSpecifier = window.objectSpecifier,
              let description = window.classDescription as? NSScriptClassDescription else { return nil }
        return NSUniqueIDSpecifier(containerClassDescription: description, containerSpecifier: windowSpecifier,
                                   key: "scriptTabs", uniqueID: scriptID)
    }

    @objc func handleCloseScriptCommand(_ command: NSCloseCommand) -> Any? {
        if Scripting.check(self) { host?.tabWantsClose(self) }
        return nil
    }
}

/// `search "query" [limit 30]`: bookmarks and history, ranked as in the
/// address bar (bookmarks a step ahead of plain history), each page once.
/// What the Alfred workflow (alfred/) lists, since other apps can't read
/// Twinkle's files themselves.
@objc(TwinkleSearchCommand)
final class SearchCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let query = (directParameter as? String ?? "").trimmingCharacters(in: .whitespaces)
        let limit = max(1, evaluatedArguments?["limit"] as? Int ?? 30)
        guard !query.isEmpty else { return [] as [Any] }
        nonisolated(unsafe) var result: [[String: Any]] = []
        MainActor.assumeIsolated {
            let state = AppState.shared
            let now = Date()
            let ranked = (state.bookmarkIndex.search(query, limit: limit, now: now).map { ($0.entry, $0.score + 25, true) }
                + state.suggestionIndex.search(query, limit: limit, now: now).map { ($0.entry, $0.score, false) })
                .sorted { $0.1 > $1.1 }
            var shown = Set<String>()
            for (entry, _, bookmarked) in ranked where result.count < limit {
                guard shown.insert(HistoryIndex.bare(entry.url)).inserted else { continue }
                result.append(["title": entry.title, "URL": entry.url, "bookmarked": bookmarked])
            }
        }
        return result
    }
}

/// `new tab "https://…" [in container "Agent"]`: opens a tab in the
/// background and loads it. Without a container, in a new temporary one.
@objc(TwinkleNewTabCommand)
final class NewTabCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let text = directParameter as? String ?? ""
        let name = evaluatedArguments?["container"] as? String
        nonisolated(unsafe) var result: Any?
        MainActor.assumeIsolated {
            guard let url = Scripting.url(text), let browser = Scripting.browser else { return }
            let state = AppState.shared
            let container: Container
            if let name {
                let wanted = name.lowercased()
                let allowed = state.containers.filter(\.appleScriptEnabled)
                    + state.temporaries.filter { state.scriptTemporaries.contains($0.id) }
                guard let match = allowed.first(where: { $0.name.lowercased() == wanted }) else {
                    Scripting.fail("No container named \(name) allows AppleScript. "
                        + "Set \"appleScriptEnabled\": true on it in settings.json, or leave out the container for a temporary one.")
                    return
                }
                container = match
            } else {
                container = state.newScriptTemporaryContainer()
            }
            let tab = browser.openTab(url: url, container: container.id, select: false, exempt: true)
            _ = tab.viewForDisplay()
            result = tab
        }
        return result
    }
}

/// `do JavaScript "…" in tab`: runs the script as the body of an async
/// function in the page, so `return` gives the result and `await` works.
/// Pages' Content Security Policies don't apply, as with Safari's.
@objc(TwinkleDoJavaScriptCommand)
final class DoJavaScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let code = directParameter as? String ?? ""
        nonisolated(unsafe) let command = self
        MainActor.assumeIsolated {
            guard let tab = evaluatedArguments?["tab"] as? Tab else {
                Scripting.fail("Say which tab: do JavaScript \"…\" in active tab of front window.", number: errAEParamMissed)
                return
            }
            guard Scripting.check(tab) else { return }
            guard let webView = tab.viewForDisplay() else {
                Scripting.fail("The tab has no page.", number: errAEEventFailed)
                return
            }
            command.suspendExecution()
            webView.callAsyncJavaScript(code, arguments: [:], in: nil, in: .page) { outcome in
                switch outcome {
                case .success(let value):
                    command.resumeExecution(withResult: Scripting.result(value))
                case .failure(let error):
                    let info = (error as NSError).userInfo
                    let message = info["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
                    command.scriptErrorNumber = errAEEventFailed
                    command.scriptErrorString = "JavaScript error: \(message)"
                    command.resumeExecution(withResult: nil)
                }
            }
        }
        return nil
    }
}
