import AppKit
import WebKit

/// A way to look inside a running Twinkle from the shell, without screen
/// recording permission: `./debug.sh` posts a distributed notification and
/// Twinkle writes its state to debug/ in its folder
/// (~/Library/Application Support/Twinkle/, or the `--profile` folder):
///
/// - state.json  the tabs, their addresses, titles, loading state, container
/// - window.png  the window's own views (sidebar, toolbar)
/// - page.png    the current page, as WebKit renders it
///
/// It only writes files on this Mac, and only when asked.
@MainActor
enum Debug {
    static let notification = name("dump")
    static let openNotification = name("open")
    static let selectNotification = name("select")

    /// "dev.twinkle.debug.<command>", with ":<folder>" for a `--profile`
    /// Twinkle, so `TWINKLE_PROFILE=<folder> ./debug.sh` drives only that one.
    static func name(_ command: String) -> Notification.Name {
        Notification.Name("dev.twinkle.debug.\(command)" + (AppState.shared.profile.map { ":" + $0 } ?? ""))
    }

    static func install(_ controller: @escaping () -> BrowserWindowController?) {
        DistributedNotificationCenter.default().addObserver(forName: notification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                if let c = controller() { dump(c) }
            }
        }
        // `./debug.sh open <url> [container name]`: opens a tab, for testing
        // containers from the shell. The object is "<url>\t<container>".
        DistributedNotificationCenter.default().addObserver(forName: openNotification, object: nil, queue: .main) { note in
            let request = note.object as? String ?? ""
            MainActor.assumeIsolated {
                let parts = request.split(separator: "\t", maxSplits: 1).map(String.init)
                guard let c = controller(), let first = parts.first, let url = URL(string: first),
                      ["http", "https"].contains(url.scheme ?? "") else { return }
                let name = parts.count > 1 ? parts[1].lowercased() : ""
                let container = name == "temporary"
                    ? AppState.shared.newTemporaryContainer()
                    : AppState.shared.containers.first { $0.name.lowercased() == name }
                c.openTab(url: url, container: container?.id)
            }
        }
        // `./debug.sh type <text>` and `./debug.sh key <name>`: the address
        // field, as if typed, one character at a time.
        DistributedNotificationCenter.default().addObserver(forName: name("type"), object: nil, queue: .main) { note in
            let text = note.object as? String ?? ""
            MainActor.assumeIsolated { controller()?.debugType(text) }
        }
        DistributedNotificationCenter.default().addObserver(forName: name("key"), object: nil, queue: .main) { note in
            let key = note.object as? String ?? ""
            MainActor.assumeIsolated { controller()?.debugKey(key) }
        }
        // `./debug.sh action <selector>`: a menu command, e.g. clearSiteData:
        DistributedNotificationCenter.default().addObserver(forName: name("action"), object: nil, queue: .main) { note in
            let name = note.object as? String ?? ""
            MainActor.assumeIsolated {
                // To the window directly: with Twinkle in the background
                // there's no key window for a nil-targeted action to reach.
                let selector = NSSelectorFromString(name)
                let target: AnyObject? = controller().flatMap { $0.responds(to: selector) ? $0 : nil } ?? NSApp.delegate
                _ = NSApp.sendAction(selector, to: target, from: nil)
            }
        }
        // `./debug.sh mouse <button>`: a click of that mouse button in the
        // middle of the window (3 is the back side button, 4 forward),
        // queued like a real one so event monitors see it.
        DistributedNotificationCenter.default().addObserver(forName: name("mouse"), object: nil, queue: .main) { note in
            let button = Int(note.object as? String ?? "") ?? 3
            MainActor.assumeIsolated {
                guard let window = controller()?.window, let view = window.contentView else { return }
                let point = NSPoint(x: view.bounds.midX, y: view.bounds.midY)
                for type in [NSEvent.EventType.otherMouseDown, .otherMouseUp] {
                    guard let event = NSEvent.mouseEvent(
                        with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)
                    else { continue }
                    // mouseEvent(with:) has no button argument; CGEvent does.
                    guard let cg = event.cgEvent else { continue }
                    cg.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button))
                    if let withButton = NSEvent(cgEvent: cg) { NSApp.postEvent(withButton, atStart: false) }
                }
            }
        }
        // `./debug.sh appearance <light|dark|system>`: for screenshots of
        // both, without changing the Mac's own setting.
        DistributedNotificationCenter.default().addObserver(forName: name("appearance"), object: nil, queue: .main) { note in
            let value = note.object as? String ?? ""
            MainActor.assumeIsolated {
                NSApp.appearance = value == "dark" ? NSAppearance(named: .darkAqua)
                    : value == "light" ? NSAppearance(named: .aqua) : nil
            }
        }
        // `./debug.sh select <index>`
        DistributedNotificationCenter.default().addObserver(forName: selectNotification, object: nil, queue: .main) { note in
            let index = Int(note.object as? String ?? "") ?? -1
            MainActor.assumeIsolated { controller()?.select(index) }
        }
    }

    static func dump(_ controller: BrowserWindowController) {
        let dir = AppState.shared.files.directory.appendingPathComponent("debug", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let state = controller.debugState()
        if let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: dir.appendingPathComponent("state.json"))
        }

        if let panel = controller.debugSuggestionsView(), let rep = panel.bitmapImageRepForCachingDisplay(in: panel.bounds) {
            panel.cacheDisplay(in: panel.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("suggestions.png"))
        }

        if let frame = controller.window?.contentView?.superview,
           let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) {
            frame.cacheDisplay(in: frame.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("window.png"))
        }

        // text.json: the first 500 characters of each loaded tab's text.
        let textFile = dir.appendingPathComponent("text.json")
        try? FileManager.default.removeItem(at: textFile)
        let loaded = controller.tabs.enumerated().filter { $0.element.webView != nil }
        var texts: [String: String] = [:]
        var remaining = loaded.count
        for (i, tab) in loaded {
            tab.webView?.evaluateJavaScript("document.body ? document.body.innerText.slice(0, 500) : ''") { value, _ in
                texts[String(i)] = value as? String ?? ""
                remaining -= 1
                if remaining == 0, let data = try? JSONSerialization.data(withJSONObject: texts, options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: textFile)
                }
            }
        }

        let page = dir.appendingPathComponent("page.png")
        try? FileManager.default.removeItem(at: page)
        let problem = dir.appendingPathComponent("page-error.txt")
        try? FileManager.default.removeItem(at: problem)
        guard let webView = controller.current?.webView else { return }
        webView.takeSnapshot(with: nil) { image, error in
            guard let image, let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
                // WebKit doesn't paint pages in windows that are hidden or
                // covered, so a snapshot of those fails.
                let occluded = !(webView.window?.occlusionState.contains(.visible) ?? false)
                let text = "snapshot failed: \(error?.localizedDescription ?? "no image")\nwindow visible: \(!occluded)\n"
                try? text.write(to: problem, atomically: true, encoding: .utf8)
                return
            }
            try? png.write(to: page)
        }
    }
}

extension BrowserWindowController {
    /// Whether the address field is on screen rather than in the toolbar's
    /// overflow menu.
    var addressFieldVisible: Bool {
        window?.toolbar?.visibleItems?.contains { $0.itemIdentifier == .address } ?? false
    }

    func debugState() -> [String: Any] {
        [
            "windowTitle": window?.title ?? "",
            "selected": tabs.firstIndex { $0 === current } ?? -1,
            "pageFrame": NSStringFromRect(current?.webView?.frame ?? .zero),
            "addressFieldInWindow": addressFieldVisible,
            "firstResponder": window?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil",
            "tabs": tabs.map { tab -> [String: Any] in
                [
                    "url": tab.url?.absoluteString ?? "",
                    "title": tab.pageTitle,
                    "loading": tab.isLoading,
                    "progress": tab.progress,
                    "hasWebView": tab.webView != nil,
                    "unloaded": tab.isUnloaded,
                    "hasIcon": tab.icon != nil,
                    "exemptSite": tab.exemptSite ?? "",
                    "unloadCheck": tab.unloadCheck,
                    "zoom": tab.webView?.pageZoom ?? 0,
                    "container": AppState.shared.container(tab.containerID)?.name ?? "",
                ]
            },
            "blockerLists": Blocker.shared.lists.compactMap(\.identifier),
            "address": debugAddress(),
        ]
    }
}
