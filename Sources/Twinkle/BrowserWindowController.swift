import AppKit
import TwinkleCore
import WebKit

extension NSPasteboard.PasteboardType {
    static let twinkleTab = NSPasteboard.PasteboardType("dev.twinkle.tab-row")
}

/// Twinkle's one text size, used for every piece of its own UI.
enum UI {
    static let textSize: CGFloat = 16
    static let font = NSFont.systemFont(ofSize: textSize)
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
    private var closedTabs: [(tab: SavedTab, temporary: Bool)] = []
    private var unloadTimer: Timer?

    private let split = NSSplitViewController()
    private var tabListItem: NSSplitViewItem!
    private let table = TabTableView()
    private let statusButton = NSButton(title: "", target: nil, action: nil)
    private let addressField = NSTextField()
    private let badge = NSTextField(labelWithString: "")
    private let badgeBox = NSView()
    private let addressBox = NSBox()
    private let progressBar = NSView()
    private var progressWidth: NSLayoutConstraint!
    private var findBarHeight: NSLayoutConstraint!
    private let findBar = NSStackView()
    private let findField = NSSearchField()
    private let findResult = NSTextField(labelWithString: "")
    private let pageArea = NSView()
    private lazy var suggestions = makeSuggestions()

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
        window.titlebarSeparatorStyle = .none
        window.minSize = NSSize(width: 520, height: 320)
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self

        // The page on the left, the tab list on the right.
        let content = NSViewController()
        content.view = makeContent()
        let tabList = NSViewController()
        tabList.view = makeSidebar()
        tabListItem = NSSplitViewItem(viewController: tabList)
        tabListItem.minimumThickness = 170
        tabListItem.maximumThickness = 420
        tabListItem.canCollapse = true
        // Resizing the window resizes the page, not the tab list.
        tabListItem.holdingPriority = NSLayoutConstraint.Priority(260)
        split.addSplitViewItem(NSSplitViewItem(viewController: content))
        split.addSplitViewItem(tabListItem)
        split.splitView.dividerStyle = .thin
        split.splitView.autosaveName = "TwinkleTabList"
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
        unloadTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.unloadIdleTabs() }
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Building the window

    private func makeSidebar() -> NSView {
        let root = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 240, height: 800))
        root.material = .sidebar
        root.blendingMode = .behindWindow
        root.state = .followsWindowActiveState

        let column = NSTableColumn(identifier: .init("tab"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .sourceList
        table.backgroundColor = .clear
        table.rowHeight = 40
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.registerForDraggedTypes([.twinkleTab])
        table.onMiddleClick = { [weak self] row in self?.closeTab(at: row) }
        table.onMouseDown = { [weak self] row in
            guard let self, row != self.selected else { return }
            self.select(row)
        }
        table.draggingDestinationFeedbackStyle = .gap
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        statusButton.isBordered = false
        statusButton.alignment = .left
        statusButton.lineBreakMode = .byTruncatingMiddle
        statusButton.font = UI.font
        statusButton.contentTintColor = .secondaryLabelColor
        statusButton.target = self
        statusButton.action = #selector(revealStatusFile(_:))
        statusButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        for v in [scroll, statusButton] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: statusButton.topAnchor, constant: -6),
            statusButton.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            statusButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            statusButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
        ])
        return root
    }

    private func makeContent() -> NSView {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1050, height: 800))

        // The address field lives in the toolbar (see toolbar(_:itemForItemIdentifier:)).
        addressField.placeholderString = "Search or enter address"
        // No bezel or focus ring: the rounded box around it is the field.
        addressField.isBordered = false
        addressField.drawsBackground = false
        addressField.focusRingType = .none
        addressField.font = UI.font
        addressField.lineBreakMode = .byTruncatingTail
        addressField.usesSingleLineMode = true
        addressField.cell?.isScrollable = true
        addressField.target = self
        addressField.action = #selector(addressEntered(_:))
        addressField.delegate = self

        badge.font = .systemFont(ofSize: UI.textSize, weight: .medium)
        badge.textColor = .white
        badge.translatesAutoresizingMaskIntoConstraints = false
        badgeBox.wantsLayer = true
        badgeBox.layer?.cornerRadius = 7
        badgeBox.addSubview(badge)
        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(equalTo: badgeBox.leadingAnchor, constant: 7),
            badge.trailingAnchor.constraint(equalTo: badgeBox.trailingAnchor, constant: -7),
            badge.centerYAnchor.constraint(equalTo: badgeBox.centerYAnchor),
            badgeBox.heightAnchor.constraint(equalToConstant: 26),
            badgeBox.widthAnchor.constraint(greaterThanOrEqualToConstant: 4),
        ])
        badgeBox.isHidden = true

        let row = NSStackView(views: [badgeBox, addressField])
        row.orientation = .horizontal
        row.spacing = 6
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        addressBox.boxType = .custom
        addressBox.borderWidth = 0
        addressBox.cornerRadius = 8
        addressBox.fillColor = .quaternarySystemFill
        addressBox.contentViewMargins = .zero
        addressBox.titlePosition = .noTitle
        addressBox.contentView?.addSubview(row)
        let inner = addressBox.contentView!
        // A range, not a size: the toolbar gives the item whatever room is
        // left. A large preferred width makes it overflow into the » menu.
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: inner.leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: inner.trailingAnchor, constant: -10),
            row.centerYAnchor.constraint(equalTo: inner.centerYAnchor),
            addressBox.heightAnchor.constraint(equalToConstant: 34),
            addressBox.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
            addressBox.widthAnchor.constraint(lessThanOrEqualToConstant: 4000),
        ])

        findField.placeholderString = "Find on page"
        findField.font = UI.font
        findField.delegate = self
        findField.target = self
        findField.action = #selector(findFieldEntered(_:))
        findField.sendsSearchStringImmediately = false
        findField.sendsWholeSearchString = true
        findField.widthAnchor.constraint(equalToConstant: 320).isActive = true
        findResult.textColor = .secondaryLabelColor
        findResult.font = UI.font
        let done = NSButton(title: "Done", target: self, action: #selector(hideFind(_:)))
        done.bezelStyle = .rounded
        done.font = UI.font
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
        [.address]
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

    /// Opens a tab. A site assigned to a container opens in that container,
    /// unless `exempt` (the tab is going where you put it yourself).
    @discardableResult
    func openTab(url: URL?, container: UUID?, at index: Int? = nil, select: Bool = true, title: String = "",
                 exempt: Bool = false) -> Tab {
        var container = container
        var exemptSite: String?
        if let assignment = AppState.shared.assignment(forHost: url?.host()), assignment.container.id != container {
            if exempt { exemptSite = assignment.site } else { container = assignment.container.id }
        }
        let tab = Tab(url: url, title: title, container: container, host: self)
        tab.exemptSite = exemptSite
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
        if changed { current?.markActive() }
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
        let temporary = AppState.shared.isTemporary(tab.containerID)
        if let saved = tab.saved {
            closedTabs.append((saved, temporary))
            if closedTabs.count > 50 { closedTabs.removeFirst() }
        }
        tab.close()
        tabs.remove(at: index)
        if temporary, let id = tab.containerID, !tabs.contains(where: { $0.containerID == id }) {
            AppState.shared.releaseTemporary(id)
        }

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

    /// A fresh tab is replaced by one in the right container; a tab with a
    /// page keeps it, and the site opens in a new tab beside it.
    func tab(_ tab: Tab, open url: URL, inAssigned container: UUID) {
        guard let i = index(of: tab) else { return }
        let fresh = tab.webView?.backForwardList.currentItem == nil
        let front = i == selected
        openTab(url: url, container: container, at: i + 1, select: front)
        if fresh {
            closeTab(at: i)
            if front { select(i) }
        }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { tabs.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        TabRowView()
    }

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
                                            current: tabs[row].containerID, shortcuts: false, temporary: true)
        menu.addItem(move)
        if !tabs[row].isUnloaded, !tabs[row].isBlank, row != selected {
            menu.addItem(item("Unload Tab", #selector(unloadRow(_:))))
        }
        menu.addItem(.separator())
        menu.addItem(item("Close Tab", #selector(closeRow(_:))))
    }

    @objc private func reloadRow(_ sender: NSMenuItem) {
        guard tabs.indices.contains(sender.tag) else { return }
        tabs[sender.tag].webView?.reload()
    }

    @objc private func duplicateRow(_ sender: NSMenuItem) {
        duplicateTab(at: sender.tag)
    }

    private func duplicateTab(at row: Int) {
        guard tabs.indices.contains(row) else { return }
        let tab = tabs[row]
        openTab(url: tab.url, container: tab.containerID, at: row + 1, title: tab.title, exempt: true)
    }

    @objc private func copyRowAddress(_ sender: NSMenuItem) {
        guard tabs.indices.contains(sender.tag), let url = tabs[sender.tag].url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    @objc private func reopenRowInContainer(_ sender: NSMenuItem) {
        reopen(at: sender.tag, in: ContainerMenus.choice(sender))
    }

    @objc private func unloadRow(_ sender: NSMenuItem) {
        guard tabs.indices.contains(sender.tag), sender.tag != selected else { return }
        tabs[sender.tag].unload()
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
        openTab(url: tab.url, container: container, at: row + 1, select: wasSelected, title: tab.title, exempt: true)
        closeTab(at: row)
        if wasSelected { select(row) }
    }

    // MARK: Address field

    private func makeSuggestions() -> AddressSuggestions {
        let s = AddressSuggestions(field: addressField, anchor: addressBox)
        s.tabs = { [unowned self] in tabs }
        s.current = { [unowned self] in current }
        s.open = { [unowned self] url, newTab in
            if newTab || current == nil {
                openTab(url: url, container: current?.containerID, at: selected + 1)
            } else if let tab = current {
                tab.load(url)
                select(selected)
                window?.makeFirstResponder(tab.webView)
            }
            updateChrome()
        }
        s.switchTo = { [unowned self] tab in
            addressField.stringValue = current?.url?.absoluteString ?? ""
            if let i = index(of: tab) { select(i) }
            window?.makeFirstResponder(current?.webView)
            updateChrome()
        }
        return s
    }

    func debugType(_ text: String) {
        focusAddress(nil)
        guard let editor = addressField.currentEditor() as? NSTextView else { return }
        let start = Date()
        for ch in text { editor.insertText(String(ch), replacementRange: editor.selectedRange()) }
        debugTypeMs = Date().timeIntervalSince(start) * 1000 / Double(max(1, text.count))
    }
    private static var typeMs = 0.0
    var debugTypeMs: Double { get { Self.typeMs } set { Self.typeMs = newValue } }

    func debugKey(_ key: String) {
        guard let editor = addressField.currentEditor() as? NSTextView else { return }
        let selectors: [String: Selector] = [
            "down": #selector(NSResponder.moveDown(_:)), "up": #selector(NSResponder.moveUp(_:)),
            "enter": #selector(NSResponder.insertNewline(_:)), "tab": #selector(NSResponder.insertTab(_:)),
            "escape": #selector(NSResponder.cancelOperation(_:)), "delete": #selector(NSResponder.deleteBackward(_:)),
        ]
        if key == "cmd-enter" {
            _ = suggestions.handle(#selector(NSResponder.insertNewline(_:)), newTab: true)
        } else if let selector = selectors[key] {
            editor.doCommand(by: selector)
        }
    }

    func debugAddress() -> [String: Any] {
        let range = addressField.currentEditor()?.selectedRange ?? NSRange()
        return ["text": addressField.stringValue, "editing": addressField.currentEditor() != nil,
                "selection": [range.location, range.length], "msPerKey": debugTypeMs, "suggestions": suggestions.debugRows]
    }

    func debugSuggestionsView() -> NSView? { suggestions.isVisible ? suggestions.contentView : nil }

    func controlTextDidBeginEditing(_ obj: Notification) {
        if (obj.object as? NSTextField) === addressField { suggestions.began() }
    }

    func controlTextDidChange(_ obj: Notification) {
        if (obj.object as? NSTextField) === addressField { suggestions.textChanged() }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        if (obj.object as? NSTextField) === addressField { suggestions.hide() }
    }

    func windowDidResize(_ notification: Notification) {
        suggestions.reposition()
    }

    func windowDidResignKey(_ notification: Notification) {
        suggestions.hide()
    }

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
        if control === addressField, suggestions.handle(selector) { return true }
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
        findBarHeight.constant = 44
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

    /// ⌃⌘S: shows or hides the tab list.
    @objc func toggleTabList(_ sender: Any?) {
        tabListItem.animator().isCollapsed.toggle()
    }

    @objc func newTab(_ sender: Any?) {
        openTab(url: nil, container: current?.containerID, at: selected + 1)
    }

    @objc func newTabInContainer(_ sender: NSMenuItem) {
        openTab(url: nil, container: ContainerMenus.choice(sender), at: selected + 1)
    }

    @objc func newTemporaryTab(_ sender: Any?) {
        openTab(url: nil, container: AppState.shared.newTemporaryContainer().id, at: selected + 1)
    }

    @objc func reopenInContainer(_ sender: NSMenuItem) {
        reopen(at: selected, in: ContainerMenus.choice(sender))
    }

    /// Tools › Always Open This Site In: assigns the current site and moves
    /// the tab there.
    @objc func assignSite(_ sender: NSMenuItem) {
        guard let host = current?.url?.host() else { return }
        let container = sender.representedObject as? UUID
        AppState.shared.assign(host: host, to: container)
        let name = AppState.shared.container(container)?.name
        let site = Hosts.siteKey(host)
        Status.show(name.map { "\(site) will always open in \($0)." } ?? "\(site) opens in any container.")
        if let container, container != current?.containerID {
            reopen(at: selected, in: container)
        } else {
            current?.exemptSite = nil
        }
    }

    @objc func duplicateCurrentTab(_ sender: Any?) {
        duplicateTab(at: selected)
    }

    @objc func closeCurrentTab(_ sender: Any?) {
        closeTab(at: selected)
    }

    @objc func reopenClosedTab(_ sender: Any?) {
        guard let (saved, temporary) = closedTabs.popLast(), let url = URL(string: saved.url) else { return }
        // A closed temporary container's data is gone; a new one stands in.
        var container = saved.container
        if temporary, AppState.shared.container(container) == nil {
            container = AppState.shared.newTemporaryContainer().id
        }
        openTab(url: url, container: container, at: selected + 1, title: saved.title, exempt: true)
    }

    /// A link from another app switches to a tab already showing it, like
    /// Safari, the current tab first; otherwise it opens in a new tab.
    func open(_ url: URL) {
        let match = { (tab: Tab) in tab.url.map { Address.samePage($0, url) } ?? false }
        if let tab = current, match(tab) {
            select(selected)
        } else if let i = tabs.firstIndex(where: match) {
            select(i)
        } else {
            openTab(url: url, container: nil)
        }
    }

    @objc func focusAddress(_ sender: Any?) {
        suggestions.prepare()
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
        setZoom(ZoomLevels.step(from: webView.pageZoom, in: true))
    }

    @objc func zoomOut(_ sender: Any?) {
        guard let webView = current?.webView else { return }
        setZoom(ZoomLevels.step(from: webView.pageZoom, in: false))
    }

    @objc func actualSize(_ sender: Any?) {
        setZoom(1)
    }

    /// Zooms the page and remembers the level for its site, so the site's
    /// other open tabs follow and it opens at this zoom next time.
    /// Temporary containers zoom without leaving a trace in zoom.json.
    private func setZoom(_ level: Double) {
        guard let tab = current, let webView = tab.webView else { return }
        webView.pageZoom = level
        Status.show("Zoom \(Int((level * 100).rounded()))%")
        guard let host = webView.url?.host(), !AppState.shared.isTemporary(tab.containerID) else { return }
        AppState.shared.setZoom(level, forHost: host)
        for other in tabs where other !== tab {
            guard let view = other.webView, let h = view.url?.host() else { continue }
            view.pageZoom = AppState.shared.zoom(forHost: h)
        }
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

    @objc func bookmarkPage(_ sender: Any?) {
        guard let tab = current, let url = tab.url, !tab.isBlank else { return }
        let title = tab.title.isEmpty ? (url.host() ?? url.absoluteString) : tab.title
        do {
            let added = try AppState.shared.addBookmarks([Bookmark(title: title, url: url.absoluteString)])
            Status.show(added > 0 ? "Bookmarked \(title)" : "Already bookmarked")
        } catch {
            Status.show("Couldn't save bookmark: \(error.localizedDescription)")
        }
    }

    @objc func toggleBlockingForSite(_ sender: Any?) {
        guard let host = current?.url?.host()?.lowercased() else { return }
        let settings = AppState.shared.settings
        AppState.shared.updateSettings { s in
            if settings.blocks(on: host) {
                s.adBlockingOffFor.append(host)
            } else {
                s.adBlockingOffFor.removeAll { Hosts.covers($0, host) }
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

    /// Tools › Clear Cookies and Data for This Site: everything the current
    /// tab's container holds for the site (cookies, storage, caches), then a
    /// reload. For sites like AWS whose sign-in gets stuck. WebKit keeps
    /// data per registrable domain, so signin.aws.amazon.com clears all of
    /// amazon.com in that container; other containers are untouched.
    @objc func clearSiteData(_ sender: Any?) {
        guard let tab = current, let host = tab.url?.host()?.lowercased() else { return }
        let store = AppState.shared.dataStore(for: tab.containerID)
        let container = AppState.shared.container(tab.containerID)?.name
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        store.fetchDataRecords(ofTypes: types) { records in
            let matching = records.filter {
                let domain = $0.displayName.lowercased()
                return host == domain || host.hasSuffix("." + domain)
            }
            let names = matching.map(\.displayName).sorted().joined(separator: ", ")
            store.removeData(ofTypes: types, for: matching) { [weak tab] in
                MainActor.assumeIsolated {
                    let place = container.map { " in \($0)" } ?? ""
                    Status.show(matching.isEmpty ? "Nothing stored for \(host)\(place)."
                                                 : "Cleared cookies and data for \(names)\(place).")
                    tab?.webView?.reload()
                }
            }
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
        case #selector(clearSiteData(_:)):
            let host = current?.url?.host().map(Hosts.siteKey)
            item.title = host.map { "Clear Cookies and Data for \($0)" } ?? "Clear Cookies and Data for This Site"
            return host != nil
        case #selector(reopenClosedTab(_:)): return !closedTabs.isEmpty
        case #selector(reopenInContainer(_:)):
            item.state = ContainerMenus.isCurrent(item, current?.containerID) ? .on : .off
            return current?.url != nil
        case #selector(assignSite(_:)):
            let host = current?.url?.host()
            let assigned = AppState.shared.assignment(forHost: host)?.container.id
            item.state = (item.representedObject as? UUID) == assigned ? .on : .off
            return host != nil
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

    // MARK: Unloading

    /// Every minute: background tabs idle longer than the setting give up
    /// their web view. Not tabs playing sound, recording, loading, or with
    /// a half-filled form.
    private func unloadIdleTabs() {
        let minutes = AppState.shared.settings.unloadTabsAfterMinutes
        guard minutes > 0 else { return }
        let cutoff = Date().addingTimeInterval(-minutes * 60)
        for (i, tab) in tabs.enumerated() where i != selected && tab.webView != nil && tab.lastActive < cutoff {
            tab.canUnload { [weak self, weak tab] ok in
                guard ok, let self, let tab, tab !== self.current else { return }
                tab.unload()
            }
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
            let tab = Tab(url: url, title: saved.title, container: saved.container, host: self, id: saved.id)
            // Restored where you left it, even if the site is assigned elsewhere.
            if let assignment = AppState.shared.assignment(forHost: url.host()), assignment.container.id != saved.container {
                tab.exemptSite = assignment.site
            }
            tabs.append(tab)
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
            // Temporary containers don't outlive the app, nor do their tabs.
            if !AppState.shared.isTemporary(tab.containerID), let s = tab.saved { saved.append(s) }
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
    private let favicon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        stripe.wantsLayer = true
        stripe.layer?.cornerRadius = 1.5
        title.lineBreakMode = .byTruncatingTail
        title.font = UI.font
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        textField = title
        favicon.imageScaling = .scaleProportionallyUpOrDown
        for v in [stripe, favicon, title, spinner] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            stripe.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            stripe.widthAnchor.constraint(equalToConstant: 3),
            stripe.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            stripe.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            favicon.leadingAnchor.constraint(equalTo: stripe.trailingAnchor, constant: 7),
            favicon.centerYAnchor.constraint(equalTo: centerYAnchor),
            favicon.widthAnchor.constraint(equalToConstant: 18),
            favicon.heightAnchor.constraint(equalToConstant: 18),
            title.leadingAnchor.constraint(equalTo: favicon.trailingAnchor, constant: 7),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            spinner.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 4),
            spinner.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 14),
            spinner.heightAnchor.constraint(equalToConstant: 14),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private static let placeholder: NSImage? = {
        let image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        return image?.withSymbolConfiguration(.init(paletteColors: [.tertiaryLabelColor]))
    }()

    func show(_ tab: Tab) {
        title.stringValue = tab.title
        // Unloaded tabs are dimmed; they load again when clicked.
        title.textColor = tab.isUnloaded ? .secondaryLabelColor : .labelColor
        favicon.image = tab.icon ?? Self.placeholder
        favicon.alphaValue = tab.isUnloaded ? 0.5 : 1
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
    /// `representedObject` of the "New Temporary Container" item.
    static let temporaryChoice = "temporary"

    static func make(action: Selector, target: AnyObject?, tag: Int = 0, current: UUID? = nil,
                     shortcuts: Bool, temporary: Bool = false) -> NSMenu {
        let menu = NSMenu()
        fill(menu, action: action, target: target, tag: tag, shortcuts: shortcuts, temporary: temporary)
        for item in menu.items where isCurrent(item, current) { item.state = .on }
        return menu
    }

    /// The container a menu item picks, making a temporary one if asked.
    static func choice(_ item: NSMenuItem) -> UUID? {
        if item.representedObject as? String == temporaryChoice {
            return AppState.shared.newTemporaryContainer().id
        }
        return item.representedObject as? UUID
    }

    static func isCurrent(_ item: NSMenuItem, _ container: UUID?) -> Bool {
        if item.representedObject as? String == temporaryChoice { return false }
        if let id = item.representedObject as? UUID { return id == container }
        return container == nil
    }

    static func fill(_ menu: NSMenu, action: Selector, target: AnyObject?, tag: Int = 0, shortcuts: Bool,
                     temporary: Bool = false, noneTitle: String = "No Container") {
        menu.removeAllItems()
        let none = NSMenuItem(title: noneTitle, action: action, keyEquivalent: shortcuts ? "0" : "")
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
        if temporary {
            menu.addItem(.separator())
            let item = NSMenuItem(title: "New Temporary Container", action: action, keyEquivalent: "")
            item.representedObject = temporaryChoice
            item.image = .dot(NSColor(hex: "#8E8E93"))
            item.target = target
            item.tag = tag
            menu.addItem(item)
        }
    }
}

/// A tab row whose selection stays in the accent colour when the focus
/// moves to the page, instead of fading to the unemphasized grey.
final class TabRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { true }
        set {}
    }
}

/// The tab list: a middle click on a tab closes it.
final class TabTableView: NSTableView {
    var onMiddleClick: ((Int) -> Void)?
    var onMouseDown: ((Int) -> Void)?

    /// Tabs switch the moment the button goes down, not when it comes up
    /// (a table that allows dragging normally waits for mouse-up).
    override func mouseDown(with event: NSEvent) {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        if row >= 0, !event.modifierFlags.contains(.control) { onMouseDown?(row) }
        super.mouseDown(with: event)
    }

    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return super.otherMouseUp(with: event) }
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        if row >= 0 { onMiddleClick?(row) }
    }
}
