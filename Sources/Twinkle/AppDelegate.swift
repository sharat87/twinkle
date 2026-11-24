import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: BrowserWindowController?
    /// Links opened from other apps before the window exists.
    private var pendingURLs: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = AppState.shared
        AppState.shared.linkQueryHelper()
        Blocker.shared.start()
        NSApp.mainMenu = MainMenu.build(app: self)
        NotificationCenter.default.addObserver(forName: .containersChanged, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { MainMenu.rebuildContainerMenus() }
        }

        let controller = BrowserWindowController()
        self.controller = controller
        Debug.install { [weak self] in self?.controller }
        controller.restoreSession()
        for url in pendingURLs { controller.open(url) }
        pendingURLs = []
        controller.showWindow(nil)
        NSApp.activate()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let controller else {
            pendingURLs.append(contentsOf: urls)
            return
        }
        for url in urls { controller.open(url) }
        controller.showWindow(nil)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Picks up hand edits to settings.json and containers.json.
        AppState.shared.reload()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.saveSession()
    }

    // MARK: Menu actions

    @objc func openSettings(_ sender: Any?) {
        edit(AppState.shared.files.url(AppState.settingsFile))
    }

    @objc func openContainers(_ sender: Any?) {
        edit(AppState.shared.files.url(AppState.containersFile))
    }

    @objc func openCustomFilters(_ sender: Any?) {
        edit(Blocker.shared.customFile)
    }

    @objc func openDataFolder(_ sender: Any?) {
        NSWorkspace.shared.open(AppState.shared.files.directory)
    }

    @objc func clearHistory(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Clear all history?"
        alert.informativeText = "Every page in history.sqlite is forgotten. Open tabs stay open."
        alert.addButton(withTitle: "Clear History")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        AppState.shared.clearHistory()
        Status.show("History cleared.")
    }

    @objc func openDownloads(_ sender: Any?) {
        NSWorkspace.shared.open(AppState.shared.downloadsDirectory)
    }

    @objc func reloadFilterLists(_ sender: Any?) {
        Task {
            await Blocker.shared.rebuild()
            Status.show("Filter lists reloaded.")
        }
    }

    @objc func downloadFilterLists(_ sender: Any?) {
        Status.show("Downloading filter lists…", sticky: true)
        Task { await Blocker.shared.refresh(force: true) }
    }

    /// Opens a file in the app the user picked for its type, or TextEdit.
    private func edit(_ file: URL) {
        let workspace = NSWorkspace.shared
        if workspace.urlForApplication(toOpen: file) != nil {
            workspace.open(file)
        } else {
            let textEdit = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
            workspace.open([file], withApplicationAt: textEdit, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}
