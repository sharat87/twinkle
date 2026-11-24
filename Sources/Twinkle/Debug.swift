import AppKit
import WebKit

/// A way to look inside a running Twinkle from the shell, without screen
/// recording permission: `./debug.sh` posts a distributed notification and
/// Twinkle writes its state to ~/Library/Application Support/Twinkle/debug/:
///
/// - state.json  the tabs, their addresses, titles, loading state, container
/// - window.png  the window's own views (sidebar, toolbar)
/// - page.png    the current page, as WebKit renders it
///
/// It only writes files on this Mac, and only when asked.
@MainActor
enum Debug {
    static let notification = Notification.Name("dev.twinkle.debug.dump")
    static let openNotification = Notification.Name("dev.twinkle.debug.open")
    static let selectNotification = Notification.Name("dev.twinkle.debug.select")

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
                    "container": AppState.shared.container(tab.containerID)?.name ?? "",
                ]
            },
            "blockerLists": Blocker.shared.lists.compactMap(\.identifier),
        ]
    }
}
