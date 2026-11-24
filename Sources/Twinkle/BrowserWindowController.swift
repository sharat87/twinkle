import AppKit
import TwinkleCore
import WebKit

extension NSPasteboard.PasteboardType {
    static let twinkleTab = NSPasteboard.PasteboardType("dev.twinkle.tab-row")
}

extension NSToolbarItem.Identifier {
    static let address = NSToolbarItem.Identifier("address")
}

/// The window: tabs down the left, the address field in the toolbar, the page.
@MainActor
final class BrowserWindowController: NSWindowController, NSWindowDelegate, TabHost,
    NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSSearchFieldDelegate,
    NSToolbarDelegate, NSMenuDelegate, NSMenuItemValidation {

    private(set) var tabs: [Tab] = []
    private var selected = -1
    private var closedTabs: [SavedTab] = []

    private let split = NSSplitViewController()
    private let table = NSTableView()
    private let statusButton = NSButton(title: "", target: nil, action: nil)
    private let addressField = NSTextField()
    private let badge = NSTextField(labelWithString: "")
    private let badgeBox = NSView()
    private let addressBox = NSStackView()
    private let progressBar = NSView()
    private var progressWidth: NSLayoutConstraint!
    private var findBarHeight: NSLayoutConstraint!
    private let findBar = NSStackView()
    private let findField = NSSearchField()
    private let findResult = NSTextField(labelWithString: "")
    private let pageArea = NSView()

    private var statusFile: URL?
    private var statusTimer: Timer?
    private var saveTimer: Timer?
    private var keyMonitor: Any?
    private var syncingSelection = false

    var current: Tab? { tabs.indices.contains(selected) ? tabs[selected] : nil }

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.titleVisibility = .hidden
        window.toolbarStyle = .unifiedCompact
        window.minSize = NSSize(width: 520, height: 320)
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self

        let sidebar = NSViewController()
        sidebar.view = makeSidebar()
        let content = NSViewController()
        content.view = makeContent()
        let sideItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sideItem.minimumThickness = 150
        sideItem.maximumThickness = 420
        sideItem.canCollapse = true
        split.addSplitViewItem(sideItem)
        split.addSplitViewItem(NSSplitViewItem(viewController: content))
        split.splitView.autosaveName = "TwinkleSidebar"
        window.contentViewController = split

        let toolbar = NSToolbar(identifier: "TwinkleToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar

        if !window.setFrameUsingName("TwinkleWindow") {
            window.setContentSize(NSSize(width: 1280, height: 820))
            window.center()
        }
        window.setFrameAutosaveName("TwinkleWindow")

        let center = NotificationCenter.default
        center.addObserver(forName: .status, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated { self?.showStatus(note.userInfo ?? [:]) }
        }
        for name in [Notification.Name.containersChanged, .settingsChanged] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.table.reloadData()
                    self?.syncTableSelection()
                    self?.updateChrome()
                }
            }
        }
        installKeyMonitor()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Building the window

    private func makeSidebar() -> NSView {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 230, height: 800))

        let column = NSTableColumn(identifier: .init("tab"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .sourceList
        table.rowHeight = 30
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.registerForDraggedTypes([.twinkleTab])
        table.draggingDestinationFeedbackStyle = .gap
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        let plus = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "New Tab")!,
                            target: self, action: #selector(newTab(_:)))
        plus.isBordered = false
        plus.toolTip = "New Tab (⌘T)"

        statusButton.isBordered = false
        statusButton.alignment = .left
        statusButton.lineBreakMode = .byTruncatingMiddle
        statusButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusButton.contentTintColor = .secondaryLabelColor
        statusButton.target = self
        statusButton.action = #selector(revealStatusFile(_:))
        statusButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        for v in [scroll, plus, statusButton] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: plus.topAnchor, constant: -6),
            plus.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            plus.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
            plus.widthAnchor.constraint(equalToConstant: 20),
            statusButton.leadingAnchor.constraint(equalTo: plus.trailingAnchor, constant: 8),
            statusButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            statusButton.centerYAnchor.constraint(equalTo: plus.centerYAnchor),
        ])
        return root
    }

    private func makeContent() -> NSView {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1050, height: 800))

        // The address field lives in the toolbar (see toolbar(_:itemForItemIdentifier:)).
        addressField.placeholderString = "Search or enter address"
        addressField.bezelStyle = .roundedBezel
        addressField.font = .systemFont(ofSize: 13)
        addressField.lineBreakMode = .byTruncatingTail
        addressField.usesSingleLineMode = true
        addressField.cell?.isScrollable = true
        addressField.target = self
        addressField.action = #selector(addressEntered(_:))
        addressField.delegate = self

        badge.font = .systemFont(ofSize: 11, weight: .semibold)
        badge.textColor = .white
        badge.translatesAutoresizingMaskIntoConstraints = false
        badgeBox.wantsLayer = true
        badgeBox.layer?.cornerRadius = 5
        badgeBox.addSubview(badge)
        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(equalTo: badgeBox.leadingAnchor, constant: 7),
            badge.trailingAnchor.constraint(equalTo: badgeBox.trailingAnchor, constant: -7),
            badge.centerYAnchor.constraint(equalTo: badgeBox.centerYAnchor),
            badgeBox.heightAnchor.constraint(equalToConstant: 20),
        ])
        badgeBox.isHidden = true

        addressBox.orientation = .horizontal
        addressBox.spacing = 6
        addressBox.addArrangedSubview(badgeBox)
        addressBox.addArrangedSubview(addressField)
        // A range, not a size: the toolbar gives the item whatever room is
        // left. A large preferred width makes it overflow into the » menu.
        NSLayoutConstraint.activate([
            addressBox.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
            addressBox.widthAnchor.constraint(lessThanOrEqualToConstant: 4000),
        ])

        findField.placeholderString = "Find on page"
        findField.delegate = self
        findField.target = self
        findField.action = #selector(findFieldEntered(_:))
        findField.sendsSearchStringImmediately = false
        findField.sendsWholeSearchString = true
        findField.widthAnchor.constraint(equalToConstant: 260).isActive = true
        findResult.textColor = .secondaryLabelColor
        findResult.font = .systemFont(ofSize: 12)
        let done = NSButton(title: "Done", target: self, action: #selector(hideFind(_:)))
        done.bezelStyle = .rounded
        done.controlSize = .small
        findBar.orientation = .horizontal
        findBar.spacing = 8
        findBar.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
        findBar.addArrangedSubview(findField)
        findBar.addArrangedSubview(findResult)
        findBar.addArrangedSubview(NSView())
        findBar.addArrangedSubview(done)
        findBar.isHidden = true

        for v in [findBar, pageArea] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        findBarHeight = findBar.heightAnchor.constraint(equalToConstant: 0)

        progressBar.wantsLayer = true
        progressBar.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        progressBar.isHidden = true
        root.addSubview(progressBar)
        progressWidth = progressBar.widthAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            findBar.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            findBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            findBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            findBarHeight,
            pageArea.topAnchor.constraint(equalTo: findBar.bottomAnchor),
            pageArea.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            pageArea.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            pageArea.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            progressBar.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            progressBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            progressBar.heightAnchor.constraint(equalToConstant: 2),
            progressWidth,
        ])
        return root
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .address]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard id == .address else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = "Address"
        item.view = addressBox
        item.visibilityPriority = .high
        return item
    }

    // MARK: Tabs

    @discardableResult
    func openTab(url: URL?, container: UUID?, at index: Int? = nil, select: Bool = true, title: String = "") -> Tab {
        let tab = Tab(url: url, title: title, container: container, host: self)
        let at = min(index ?? tabs.count, tabs.count)
        tabs.insert(tab, at: at)
        if at <= selected { selected += 1 }
        table.reloadData()
        if select { self.select(at) } else { syncTableSelection() }
        scheduleSave()
        return tab
    }

    func select(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        let tab = tabs[index]
        let changed = index != selected || pageArea.subviews.first !== tab.webView
        selected = index
        if changed {
            pageArea.subviews.forEach { $0.removeFromSuperview() }
            if let webView = tab.viewForDisplay() {
                webView.frame = pageArea.bounds
                webView.autoresizingMask = [.width, .height]
                pageArea.addSubview(webView)
            }
        }
        syncTableSelection()
        updateChrome()
        scheduleSave()
        if tab.isBlank {
            focusAddress(nil)
        } else if changed, let webView = tab.webView {
            window?.makeFirstResponder(webView)
        }
    }

    func closeTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        let tab = tabs[index]
        if let saved = tab.saved {
            closedTabs.append(saved)
            if closedTabs.count > 50 { closedTabs.removeFirst() }
        }
        tab.close()
        tabs.remove(at: index)

        if tabs.isEmpty {
            selected = -1
            openTab(url: nil, container: tab.containerID)
            return
        }
        var next = selected
        if index < selected {
            next -= 1
        } else if index == selected {
            next = min(index, tabs.count - 1)
        }
        selected = -1
        table.reloadData()
        select(next)
    }

    private func index(of tab: Tab) -> Int? {
        tabs.firstIndex { $0 === tab }
    }

    private func syncTableSelection() {
        syncingSelection = true
        defer { syncingSelection = false }
        if tabs.indices.contains(selected) {
            table.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false)
            table.scrollRowToVisible(selected)
        } else {
            table.deselectAll(nil)
        }
    }

    /// The address field, container badge, progress bar and window title.
    private func updateChrome() {
        guard let tab = current else { return }
        if addressField.currentEditor() == nil {
            addressField.stringValue = tab.url?.absoluteString ?? ""
        }
        if let container = AppState.shared.container(tab.containerID) {
            badge.stringValue = container.name
            badgeBox.layer?.backgroundColor = NSColor(hex: container.color).cgColor
            badgeBox.isHidden = false
        } else {
            badgeBox.isHidden = true
        }
        if tab.isLoading {
            progressBar.isHidden = false
            progressWidth.constant = max(0.05, tab.progress) * pageArea.bounds.width
        } else {
            progressBar.isHidden = true
        }
        window?.title = WindowTitle.make(title: tab.pageTitle, url: tab.url,
                                         format: AppState.shared.settings.windowTitleFormat)
    }

    // MARK: TabHost

    func tabDidChange(_ tab: Tab) {
        guard let row = index(of: tab) else { return }
        table.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
        if row == selected { updateChrome() }
        scheduleSave()
    }

    func tab(_ tab: Tab, open url: URL, inBackground: Bool) {
        let at = (index(of: tab) ?? tabs.count - 1) + 1
        openTab(url: url, container: tab.containerID, at: at, select: !inBackground)
    }

    func tab(_ opener: Tab, popupWith configuration: WKWebViewConfiguration) -> WKWebView? {
        let tab = Tab(popupConfiguration: configuration, container: opener.containerID, host: self)
        let at = (index(of: opener) ?? tabs.count - 1) + 1
        tabs.insert(tab, at: at)
        if at <= selected { selected += 1 }
        table.reloadData()
        select(at)
        return tab.webView
    }

    func tabWantsClose(_ tab: Tab) {
        if let i = index(of: tab) { closeTab(at: i) }
    }

    func reveal(_ tab: Tab) {
        if let i = index(of: tab), i != selected { select(i) }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { tabs.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: TabCell.identifier, owner: nil) as? TabCell ?? TabCell()
        cell.show(tabs[row])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !syncingSelection else { return }
        let row = table.selectedRow
        if row >= 0, row != selected { select(row) }
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString(String(row), forType: .twinkleTab)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
        guard info.draggingSource as? NSTableView === table else { return [] }
        if op == .on { tableView.setDropRow(row, dropOperation: .above) }
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard let s = info.draggingPasteboard.pasteboardItems?.first?.string(forType: .twinkleTab),
              let from = Int(s), tabs.indices.contains(from) else { return false }
        let to = from < row ? row - 1 : row
        guard to != from else { return false }
        let front = current
        let tab = tabs.remove(at: from)
        tabs.insert(tab, at: to)
        selected = front.flatMap(index(of:)) ?? selected
        table.reloadData()
        syncTableSelection()
        scheduleSave()
        return true
    }

    /// The tab list's right-click menu.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === table.menu else { return }
        menu.removeAllItems()
        let row = table.clickedRow
        guard tabs.indices.contains(row) else { return }
        func item(_ title: String, _ action: Selector) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
            i.target = self
            i.tag = row
            return i
        }
        menu.addItem(item("Reload", #selector(reloadRow(_:))))
        menu.addItem(item("Duplicate", #selector(duplicateRow(_:))))
        menu.addItem(item("Copy Address", #selector(copyRowAddress(_:))))
        let move = NSMenuItem(title: "Reopen in Container", action: nil, keyEquivalent: "")
        move.submenu = ContainerMenus.make(action: #selector(reopenRowInContainer(_:)), target: self, tag: row,
                                            current: tabs[row].containerID, shortcuts: false)
        menu.addItem(move)
        menu.addItem(.separator())
        menu.addItem(item("Close Tab", #selector(closeRow(_:))))
    }

    @objc private func reloadRow(_ sender: NSMenuItem) {
        guard tabs.indices.contains(sender.tag) else { return }
        tabs[sender.tag].webView?.reload()
    }

    @objc private func duplicateRow(_ sender: NSMenuItem) {
        guard tabs.indices.contains(sender.tag) else { return }
        let tab = tabs[sender.tag]
        openTab(url: tab.url, container: tab.containerID, at: sender.tag + 1, title: tab.title)
    }

    @objc private func copyRowAddress(_ sender: NSMenuItem) {
        guard tabs.indices.contains(sender.tag), let url = tabs[sender.tag].url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    @objc private func reopenRowInContainer(_ sender: NSMenuItem) {
        reopen(at: sender.tag, in: sender.representedObject as? UUID)
    }

    @objc private func closeRow(_ sender: NSMenuItem) {
        closeTab(at: sender.tag)
    }

    /// A tab can't change cookie jars while open; it is replaced by a new tab
    /// in the other container at the same address, as Firefox does.
    private func reopen(at row: Int, in container: UUID?) {
        guard tabs.indices.contains(row) else { return }
        let tab = tabs[row]
        guard tab.containerID != container else { return }
        let wasSelected = row == selected
        openTab(url: tab.url, container: container, at: row + 1, select: wasSelected, title: tab.title)
        closeTab(at: row)
        if wasSelected { select(row) }
    }

    // MARK: Address field

    @objc private func addressEntered(_ sender: NSTextField) {
        guard let url = Address.resolve(sender.stringValue, searchTemplate: AppState.shared.settings.searchURL) else { return }
        if let tab = current {
            tab.load(url)
            select(selected)
            window?.makeFirstResponder(tab.webView)
        } else {
            openTab(url: url, container: nil)
        }
        updateChrome()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            if control === addressField {
                addressField.stringValue = current?.url?.absoluteString ?? ""
                if let webView = current?.webView { window?.makeFirstResponder(webView) }
                return true
            }
            if control === findField {
                hideFind(nil)
                return true
            }
        }
        if control === findField, selector == #selector(NSResponder.insertNewline(_:)) {
            let backwards = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
            find(backwards: backwards)
            return true
        }
        return false
    }

    // MARK: Find

    @objc func showFind(_ sender: Any?) {
        findBar.isHidden = false
        findBarHeight.constant = 34
        window?.makeFirstResponder(findField)
        findField.currentEditor()?.selectAll(nil)
    }

    @objc func hideFind(_ sender: Any?) {
        findBar.isHidden = true
        findBarHeight.constant = 0
        findResult.stringValue = ""
        if let webView = current?.webView { window?.makeFirstResponder(webView) }
    }

    @objc private func findFieldEntered(_ sender: NSSearchField) {
        find(backwards: false)
    }

    @objc func findNext(_ sender: Any?) {
        if findBar.isHidden { showFind(nil) } else { find(backwards: false) }
    }

    @objc func findPrevious(_ sender: Any?) {
        if findBar.isHidden { showFind(nil) } else { find(backwards: true) }
    }

    private func find(backwards: Bool) {
        let text = findField.stringValue
        guard !text.isEmpty, let webView = current?.webView else { return }
        let config = WKFindConfiguration()
        config.backwards = backwards
        config.wraps = true
        config.caseSensitive = false
        webView.find(text, configuration: config) { [weak self] result in
            self?.findResult.stringValue = result.matchFound ? "" : "Not found"
        }
    }

    // MARK: Menu actions (reached through the responder chain)

    @objc func newTab(_ sender: Any?) {
        openTab(url: nil, container: current?.containerID, at: selected + 1)
    }

    @objc func newTabInContainer(_ sender: NSMenuItem) {
        openTab(url: nil, container: sender.representedObject as? UUID, at: selected + 1)
    }

    @objc func reopenInContainer(_ sender: NSMenuItem) {
        reopen(at: selected, in: sender.representedObject as? UUID)
    }

    @objc func closeCurrentTab(_ sender: Any?) {
        closeTab(at: selected)
    }

    @objc func reopenClosedTab(_ sender: Any?) {
        guard let saved = closedTabs.popLast(), let url = URL(string: saved.url) else { return }
        openTab(url: url, container: saved.container, at: selected + 1, title: saved.title)
    }

    @objc func focusAddress(_ sender: Any?) {
        window?.makeFirstResponder(addressField)
        addressField.currentEditor()?.selectAll(nil)
    }

    @objc func reloadPage(_ sender: Any?) {
        guard let tab = current else { return }
        if tab.webView == nil, let url = tab.url { tab.load(url) } else { tab.webView?.reload() }
    }

    @objc func reloadFromOrigin(_ sender: Any?) {
        current?.webView?.reloadFromOrigin()
    }

    @objc func stopLoading(_ sender: Any?) {
        current?.webView?.stopLoading()
    }

    @objc func goBack(_ sender: Any?) {
        current?.webView?.goBack()
    }

    @objc func goForward(_ sender: Any?) {
        current?.webView?.goForward()
    }

    @objc func zoomIn(_ sender: Any?) {
        guard let webView = current?.webView else { return }
        webView.pageZoom = min(webView.pageZoom + 0.1, 3)
    }

    @objc func zoomOut(_ sender: Any?) {
        guard let webView = current?.webView else { return }
        webView.pageZoom = max(webView.pageZoom - 0.1, 0.3)
    }

    @objc func actualSize(_ sender: Any?) {
        current?.webView?.pageZoom = 1
    }

    @objc func nextTab(_ sender: Any?) {
        guard !tabs.isEmpty else { return }
        select((selected + 1) % tabs.count)
    }

    @objc func previousTab(_ sender: Any?) {
        guard !tabs.isEmpty else { return }
        select((selected - 1 + tabs.count) % tabs.count)
    }

    /// ⌘1–⌘8 pick that tab; ⌘9 the last one.
    @objc func selectTabByNumber(_ sender: NSMenuItem) {
        guard !tabs.isEmpty else { return }
        select(sender.tag == 9 ? tabs.count - 1 : min(sender.tag - 1, tabs.count - 1))
    }

    @objc func copyAddress(_ sender: Any?) {
        guard let url = current?.url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        Status.show("Copied \(url.absoluteString)")
    }

    @objc func toggleBlockingForSite(_ sender: Any?) {
        guard let host = current?.url?.host()?.lowercased() else { return }
        let settings = AppState.shared.settings
        AppState.shared.updateSettings { s in
            if settings.blocks(on: host) {
                s.adBlockingOffFor.append(host)
            } else {
                s.adBlockingOffFor.removeAll { host == $0 || host.hasSuffix("." + $0) }
            }
        }
        if let webView = current?.webView {
            Blocker.shared.tune(webView.configuration.userContentController, host: host)
            webView.reload()
        }
    }

    @objc func newContainer(_ sender: Any?) {
        Dialogs.askForName(title: "New Container", placeholder: "Name, like Work or Banking", in: window) { [weak self] name in
            guard let self, let name else { return }
            let container = AppState.shared.addContainer(named: name)
            self.openTab(url: nil, container: container.id, at: self.selected + 1)
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let webView = current?.webView
        switch item.action {
        case #selector(goBack(_:)): return webView?.canGoBack ?? false
        case #selector(goForward(_:)): return webView?.canGoForward ?? false
        case #selector(stopLoading(_:)): return webView?.isLoading ?? false
        case #selector(zoomIn(_:)), #selector(zoomOut(_:)), #selector(actualSize(_:)),
             #selector(reloadFromOrigin(_:)), #selector(findNext(_:)), #selector(findPrevious(_:)), #selector(showFind(_:)):
            return webView != nil
        case #selector(copyAddress(_:)): return current?.url != nil
        case #selector(reopenClosedTab(_:)): return !closedTabs.isEmpty
        case #selector(reopenInContainer(_:)):
            item.state = (item.representedObject as? UUID) == current?.containerID ? .on : .off
            return current?.url != nil
        case #selector(toggleBlockingForSite(_:)):
            let host = current?.url?.host()
            let on = AppState.shared.settings.blocks(on: host)
            item.title = on ? "Turn Off Ad Blocking for This Site" : "Turn On Ad Blocking for This Site"
            return host != nil && AppState.shared.settings.adBlocking
        default: return true
        }
    }

    // MARK: Keys

    /// ⌃Tab and ⌃⇧Tab, which menus can't reliably claim from the web view.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window, event.keyCode == 48 else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags.contains(.control), !flags.contains(.command) else { return event }
            if flags.contains(.shift) { self.previousTab(nil) } else { self.nextTab(nil) }
            return nil
        }
    }

    // MARK: Status line

    private func showStatus(_ info: [AnyHashable: Any]) {
        let text = info["text"] as? String ?? ""
        statusButton.title = text
        statusButton.toolTip = text
        statusFile = info["file"] as? URL
        statusTimer?.invalidate()
        if !(info["sticky"] as? Bool ?? false) {
            statusTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.statusButton.title = ""
                    self?.statusFile = nil
                }
            }
        }
    }

    @objc private func revealStatusFile(_ sender: Any?) {
        if let file = statusFile {
            NSWorkspace.shared.activateFileViewerSelecting([file])
        }
        statusButton.title = ""
    }

    // MARK: Session

    func restoreSession() {
        let session = (try? AppState.shared.files.load(Session.self, from: AppState.sessionFile)) ?? nil
        for saved in session?.tabs ?? [] {
            guard let url = URL(string: saved.url) else { continue }
            tabs.append(Tab(url: url, title: saved.title, container: saved.container, host: self))
        }
        table.reloadData()
        if tabs.isEmpty {
            openTab(url: nil, container: nil)
        } else {
            select(min(max(session?.selected ?? 0, 0), tabs.count - 1))
        }
    }

    private func scheduleSave() {
        guard saveTimer == nil else { return }
        saveTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.saveTimer = nil
                self?.saveSession()
            }
        }
    }

    func saveSession() {
        var saved: [SavedTab] = []
        var selectedSaved = 0
        for (i, tab) in tabs.enumerated() {
            // The selected tab, or the first saved one after it if it isn't
            // saved itself (a blank tab); restore clamps it.
            if i == selected { selectedSaved = saved.count }
            if let s = tab.saved { saved.append(s) }
        }
        try? AppState.shared.files.save(Session(tabs: saved, selected: selectedSaved), to: AppState.sessionFile)
    }

    func windowWillClose(_ notification: Notification) {
        saveSession()
    }
}

/// A row in the tab list: the container's colour, the title, a spinner.
final class TabCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("TabCell")

    private let stripe = NSView()
    private let title = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        stripe.wantsLayer = true
        stripe.layer?.cornerRadius = 1.5
        title.lineBreakMode = .byTruncatingTail
        title.font = .systemFont(ofSize: 13)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        textField = title
        for v in [stripe, title, spinner] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            stripe.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            stripe.widthAnchor.constraint(equalToConstant: 3),
            stripe.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            stripe.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            title.leadingAnchor.constraint(equalTo: stripe.trailingAnchor, constant: 8),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            spinner.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 4),
            spinner.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 14),
            spinner.heightAnchor.constraint(equalToConstant: 14),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ tab: Tab) {
        title.stringValue = tab.title
        toolTip = tab.url?.absoluteString
        if let container = AppState.shared.container(tab.containerID) {
            stripe.layer?.backgroundColor = NSColor(hex: container.color).cgColor
            stripe.isHidden = false
        } else {
            stripe.isHidden = true
        }
        if tab.isLoading { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }
}

/// "No Container" plus each container, as menu items carrying the
/// container's id in `representedObject`.
@MainActor
enum ContainerMenus {
    static func make(action: Selector, target: AnyObject?, tag: Int = 0, current: UUID? = nil,
                     shortcuts: Bool) -> NSMenu {
        let menu = NSMenu()
        fill(menu, action: action, target: target, tag: tag, shortcuts: shortcuts)
        return menu
    }

    static func fill(_ menu: NSMenu, action: Selector, target: AnyObject?, tag: Int = 0, shortcuts: Bool) {
        menu.removeAllItems()
        let none = NSMenuItem(title: "No Container", action: action, keyEquivalent: shortcuts ? "0" : "")
        none.keyEquivalentModifierMask = [.control, .command]
        none.target = target
        none.tag = tag
        menu.addItem(none)
        for (i, container) in AppState.shared.containers.enumerated() {
            let key = shortcuts && i < 9 ? String(i + 1) : ""
            let item = NSMenuItem(title: container.name, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = [.control, .command]
            item.representedObject = container.id
            item.image = .dot(NSColor(hex: container.color))
            item.target = target
            item.tag = tag
            menu.addItem(item)
        }
    }
}
