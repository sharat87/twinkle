import AppKit

/// The menu bar. Items with no target go down the responder chain to the
/// window controller.
@MainActor
enum MainMenu {
    static let newTabInContainer = NSMenu(title: "New Tab in Container")
    static let reopenInContainer = NSMenu(title: "Reopen Tab in Container")

    static func build(app: AppDelegate) -> NSMenu {
        let main = NSMenu()

        main.addItem(submenu("Twinkle", [
            item("About Twinkle", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("Settings…", #selector(AppDelegate.openSettings(_:)), ",", target: app),
            item("Edit Containers…", #selector(AppDelegate.openContainers(_:)), target: app),
            item("Edit Custom Filters…", #selector(AppDelegate.openCustomFilters(_:)), target: app),
            item("Show Twinkle Folder", #selector(AppDelegate.openDataFolder(_:)), target: app),
            .separator(),
            item("Hide Twinkle", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("Quit Twinkle", #selector(NSApplication.terminate(_:)), "q"),
        ]))

        let newInContainer = NSMenuItem(title: "New Tab in Container", action: nil, keyEquivalent: "")
        newInContainer.submenu = newTabInContainer
        main.addItem(submenu("File", [
            item("New Tab", #selector(BrowserWindowController.newTab(_:)), "t"),
            newInContainer,
            item("New Container…", #selector(BrowserWindowController.newContainer(_:)), "n", [.command, .shift]),
            item("Open Location…", #selector(BrowserWindowController.focusAddress(_:)), "l"),
            .separator(),
            item("Reopen Closed Tab", #selector(BrowserWindowController.reopenClosedTab(_:)), "t", [.command, .shift]),
            item("Close Tab", #selector(BrowserWindowController.closeCurrentTab(_:)), "w"),
            item("Close Window", #selector(NSWindow.performClose(_:)), "w", [.command, .shift]),
        ]))

        main.addItem(submenu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Paste and Match Style", #selector(NSTextView.pasteAsPlainText(_:)), "v", [.command, .option, .shift]),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            item("Copy Page Address", #selector(BrowserWindowController.copyAddress(_:)), "c", [.command, .shift]),
            .separator(),
            item("Find…", #selector(BrowserWindowController.showFind(_:)), "f"),
            item("Find Next", #selector(BrowserWindowController.findNext(_:)), "g"),
            item("Find Previous", #selector(BrowserWindowController.findPrevious(_:)), "g", [.command, .shift]),
        ]))

        main.addItem(submenu("View", [
            item("Reload Page", #selector(BrowserWindowController.reloadPage(_:)), "r"),
            item("Reload from Origin", #selector(BrowserWindowController.reloadFromOrigin(_:)), "r", [.command, .option]),
            item("Stop", #selector(BrowserWindowController.stopLoading(_:)), "."),
            .separator(),
            item("Zoom In", #selector(BrowserWindowController.zoomIn(_:)), "="),
            item("Zoom Out", #selector(BrowserWindowController.zoomOut(_:)), "-"),
            item("Actual Size", #selector(BrowserWindowController.actualSize(_:)), "0"),
            .separator(),
            item("Toggle Sidebar", #selector(NSSplitViewController.toggleSidebar(_:)), "s", [.command, .control]),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ]))

        main.addItem(submenu("History", [
            item("Back", #selector(BrowserWindowController.goBack(_:)), "["),
            item("Forward", #selector(BrowserWindowController.goForward(_:)), "]"),
        ]))

        let reopen = NSMenuItem(title: "Reopen Tab in Container", action: nil, keyEquivalent: "")
        reopen.submenu = reopenInContainer
        main.addItem(submenu("Tools", [
            reopen,
            .separator(),
            item("Turn Off Ad Blocking for This Site", #selector(BrowserWindowController.toggleBlockingForSite(_:))),
            item("Reload Filter Lists", #selector(AppDelegate.reloadFilterLists(_:)), target: app),
            item("Download Filter Lists Now", #selector(AppDelegate.downloadFilterLists(_:)), target: app),
            .separator(),
            item("Show Downloads Folder", #selector(AppDelegate.openDownloads(_:)), "j", [.command, .option], target: app),
        ]))

        var tabItems: [NSMenuItem] = [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
            .separator(),
            item("Show Next Tab", #selector(BrowserWindowController.nextTab(_:)), "]", [.command, .shift]),
            item("Show Previous Tab", #selector(BrowserWindowController.previousTab(_:)), "[", [.command, .shift]),
        ]
        for n in 1...9 {
            let i = item(n == 9 ? "Last Tab" : "Tab \(n)", #selector(BrowserWindowController.selectTabByNumber(_:)), String(n))
            i.tag = n
            tabItems.append(i)
        }
        let window = submenu("Window", tabItems)
        main.addItem(window)
        NSApp.windowsMenu = window.submenu

        rebuildContainerMenus()
        return main
    }

    /// Called at launch and whenever containers.json changes, so the ⌃⌘1–9
    /// shortcuts always match the file.
    static func rebuildContainerMenus() {
        ContainerMenus.fill(newTabInContainer, action: #selector(BrowserWindowController.newTabInContainer(_:)),
                            target: nil, shortcuts: true)
        ContainerMenus.fill(reopenInContainer, action: #selector(BrowserWindowController.reopenInContainer(_:)),
                            target: nil, shortcuts: false)
    }

    private static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private static func item(_ title: String, _ action: Selector, _ key: String = "",
                             _ modifiers: NSEvent.ModifierFlags = [.command], target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = target
        return item
    }
}
