import AppKit
import TwinkleCore
import WebKit

extension NSPasteboard.PasteboardType {
    static let twinkleTab = NSPasteboard.PasteboardType("dev.twinkle.tab-row")
}

/// Twinkle's one text size, used for every piece of its own UI.
enum UI {
    static let textSize: CGFloat = 18
    static let font = NSFont.systemFont(ofSize: textSize)
}

/// The window: the address row and the page on the left, the tab list down
/// the right, full height. No toolbar: the address row is an ordinary view
/// level with the traffic lights, so AppKit's toolbar styling never touches it.
@MainActor
final class BrowserWindowController: NSWindowController, NSWindowDelegate, TabHost,
    NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSSearchFieldDelegate,
    NSMenuDelegate, NSMenuItemValidation {

    static let tabRowHeight: CGFloat = 42

    private(set) var tabs: [Tab] = []
    private var selected = -1
    private var closedTabs: [(tab: SavedTab, temporary: Bool)] = []
    private var unloadTimer: Timer?

    private let split = NSSplitViewController()
    private var tabListItem: NSSplitViewItem!
    private let table = TabTableView()
    private let statusButton = NSButton(title: "", target: nil, action: nil)
    private let statusIcon = NSImageView()
    private let statusCancel = NSButton()
    let addressField = NSTextField()
    private let securityIcon = NSImageView()
    private let badge = NSTextField(labelWithString: "")
    private let badgeBox = NSView()
    private let statusBadge = NSTextField(labelWithString: "")
    private let statusBadgeBox = NSView()
    private let addressRow = NSStackView()
    /// Set by alignAddressRow(): the row level with the traffic lights, and
    /// the page below it.
    private var addressRowCenter: NSLayoutConstraint!
    private var addressRowLeading: NSLayoutConstraint!
    private var pageTop: NSLayoutConstraint!
    private let progressBar = NSView()
    private var progressWidth: NSLayoutConstraint!
    private var findBarHeight: NSLayoutConstraint!
    private let findBar = NSStackView()
    private let findField = NSSearchField()
    private let findResult = NSTextField(labelWithString: "")
    private let pageArea = NSView()
    private lazy var suggestions = makeSuggestions()

    private var statusFile: URL?
    private var statusCancelAction: (() -> Void)?
    private var statusTimer: Timer?
    private var saveTimer: Timer?
    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    private var syncingSelection = false
    /// Counts tabs coming to the front, for `Tab.selectedAt`.
    private var selectionCount = 0
    /// While ⌃ is held after ⌃Tab: the tabs, most recently used first, and
    /// which one ⌃Tab has got to.
    private var switcher: (order: [Tab], position: Int)?
    private let switcherPanel = TabSwitcherPanel()

    var current: Tab? { tabs.indices.contains(selected) ? tabs[selected] : nil }

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // An empty toolbar, only so the title bar is tall enough for the
        // address row, with the traffic lights centred in it.
        window.toolbar = NSToolbar(identifier: "TwinkleToolbar")
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
        split.splitView.autosaveName = AppState.shared.defaultsName("TwinkleTabList")
        window.contentViewController = split

        let frameName = AppState.shared.defaultsName("TwinkleWindow")
        if !window.setFrameUsingName(frameName) {
            window.setContentSize(NSSize(width: 1280, height: 820))
            window.center()
        }
        window.setFrameAutosaveName(frameName)
        alignAddressRow()

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
        let root = SidebarView(frame: NSRect(x: 0, y: 0, width: 240, height: 800))
        root.material = .sidebar
        root.blendingMode = .behindWindow
        root.state = .followsWindowActiveState

        let column = NSTableColumn(identifier: .init("tab"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .sourceList
        table.backgroundColor = .clear
        table.rowHeight = Self.tabRowHeight
        table.intercellSpacing = .zero
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
        scroll.automaticallyAdjustsContentInsets = false
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

        statusIcon.imageScaling = .scaleProportionallyDown
        statusIcon.isHidden = true
        statusIcon.contentTintColor = .secondaryLabelColor
        statusCancel.bezelStyle = .accessoryBar
        statusCancel.isBordered = false
        statusCancel.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Cancel download")
        statusCancel.contentTintColor = .secondaryLabelColor
        statusCancel.target = self
        statusCancel.action = #selector(cancelStatusAction(_:))
        statusCancel.toolTip = "Cancel download"
        statusCancel.isHidden = true

        for v in [scroll, statusIcon, statusButton, statusCancel] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: statusButton.topAnchor, constant: -6),
            statusIcon.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            statusIcon.centerYAnchor.constraint(equalTo: statusButton.centerYAnchor),
            statusIcon.widthAnchor.constraint(equalToConstant: 18),
            statusIcon.heightAnchor.constraint(equalToConstant: 18),
            statusButton.leadingAnchor.constraint(equalTo: statusIcon.trailingAnchor, constant: 6),
            statusButton.trailingAnchor.constraint(equalTo: statusCancel.leadingAnchor, constant: -6),
            statusButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
            statusCancel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            statusCancel.centerYAnchor.constraint(equalTo: statusButton.centerYAnchor),
            statusCancel.widthAnchor.constraint(equalToConstant: 22),
            statusCancel.heightAnchor.constraint(equalToConstant: 22),
        ])
        return root
    }

    private func makeContent() -> NSView {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1050, height: 800))

        // A standard bezeled field: AppKit draws its text in the same place
        // whether or not it's being edited.
        addressField.placeholderString = "Search or enter address"
        addressField.isBezeled = true
        addressField.bezelStyle = .roundedBezel
        addressField.font = NSFont(name: "Monaco", size: UI.textSize - 2) ?? .monospacedSystemFont(ofSize: UI.textSize - 2, weight: .regular)
        addressField.lineBreakMode = .byTruncatingTail
        // Scrolls rather than wraps, so it's one line. Not usesSingleLineMode:
        // that draws the text 3 points higher when not being edited.
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

        securityIcon.imageScaling = .scaleProportionallyDown
        securityIcon.translatesAutoresizingMaskIntoConstraints = false
        securityIcon.setContentHuggingPriority(.required, for: .horizontal)
        securityIcon.setContentCompressionResistancePriority(.required, for: .horizontal)
        securityIcon.isHidden = true
        NSLayoutConstraint.activate([
            securityIcon.widthAnchor.constraint(equalToConstant: 16),
            securityIcon.heightAnchor.constraint(equalToConstant: 16),
        ])

        // The response status, like `200 OK`, at the row's right end.
        statusBadge.font = NSFont(name: "Monaco", size: UI.textSize - 4) ?? .monospacedSystemFont(ofSize: UI.textSize - 4, weight: .regular)
        statusBadge.translatesAutoresizingMaskIntoConstraints = false
        statusBadgeBox.wantsLayer = true
        statusBadgeBox.layer?.cornerRadius = 6
        statusBadgeBox.layer?.borderWidth = 1
        statusBadgeBox.addSubview(statusBadge)
        NSLayoutConstraint.activate([
            statusBadge.leadingAnchor.constraint(equalTo: statusBadgeBox.leadingAnchor, constant: 6),
            statusBadge.trailingAnchor.constraint(equalTo: statusBadgeBox.trailingAnchor, constant: -6),
            statusBadge.centerYAnchor.constraint(equalTo: statusBadgeBox.centerYAnchor),
        ])
        statusBadgeBox.isHidden = true

        for v in [badgeBox, securityIcon, addressField, statusBadgeBox] { addressRow.addArrangedSubview(v) }
        statusBadgeBox.heightAnchor.constraint(equalTo: addressField.heightAnchor).isActive = true
        addressRow.orientation = .horizontal
        addressRow.spacing = 8
        addressRow.alignment = .centerY
        addressRow.detachesHiddenViews = true
        for v in [badgeBox, securityIcon, statusBadgeBox] {
            v.setContentHuggingPriority(.required, for: .horizontal)
            v.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        addressField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        addressField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

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

        for v in [addressRow, findBar, pageArea] {
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

        addressRowCenter = addressRow.centerYAnchor.constraint(equalTo: root.topAnchor, constant: 20)
        addressRowLeading = addressRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 80)
        pageTop = findBar.topAnchor.constraint(equalTo: root.topAnchor, constant: 40)
        NSLayoutConstraint.activate([
            addressRowCenter,
            addressRowLeading,
            addressRow.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            pageTop,
            findBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            findBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            findBarHeight,
            pageArea.topAnchor.constraint(equalTo: findBar.bottomAnchor),
            pageArea.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            pageArea.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            pageArea.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            progressBar.topAnchor.constraint(equalTo: findBar.topAnchor),
            progressBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            progressBar.heightAnchor.constraint(equalToConstant: 2),
            progressWidth,
        ])
        return root
    }

    /// Puts the address row level with the traffic lights and just after
    /// them, and the page below it. Reads where macOS put the
    /// buttons, so it follows any title bar height or text size. In full
    /// screen the buttons live elsewhere; the row then sits at the top.
    private func alignAddressRow() {
        guard let window, addressRowCenter != nil else { return }
        addressRow.layoutSubtreeIfNeeded()
        let rowHeight = max(addressRow.fittingSize.height, addressField.fittingSize.height)
        var center = rowHeight / 2 + 6
        var leading: CGFloat = 10
        if let close = window.standardWindowButton(.closeButton),
           let zoom = window.standardWindowButton(.zoomButton),
           close.window === window, !close.isHiddenOrHasHiddenAncestor {
            let c = close.convert(close.bounds, to: nil)
            center = max(center, window.frame.height - c.midY)
            leading = zoom.convert(zoom.bounds, to: nil).maxX + 12
        }
        let top = (center + rowHeight / 2 + 6).rounded()
        if addressRowCenter.constant != center.rounded() { addressRowCenter.constant = center.rounded() }
        if addressRowLeading.constant != leading.rounded() { addressRowLeading.constant = leading.rounded() }
        if pageTop.constant != top { pageTop.constant = top }
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
        if switcher == nil {
            selectionCount += 1
            tab.selectedAt = selectionCount
        }
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
        } else if changed, let responder = tab.pageResponder {
            window?.makeFirstResponder(responder)
        }
    }

    func closeTab(at index: Int) {
        closeTabs(at: IndexSet(integer: index))
    }

    /// Closes several tabs at once; each can come back with Reopen Closed
    /// Tab. If the front tab goes, the first tab after the closed ones
    /// takes its place.
    func closeTabs(at indices: IndexSet) {
        let indices = indices.filteredIndexSet { tabs.indices.contains($0) }
        guard let last = indices.last else { return }
        let closing = indices.map { tabs[$0] }
        for tab in closing {
            let temporary = AppState.shared.isTemporary(tab.containerID)
            if let saved = tab.saved {
                closedTabs.append((saved, temporary))
                if closedTabs.count > 50 { closedTabs.removeFirst() }
            }
            tab.close()
        }
        for index in indices.reversed() { tabs.remove(at: index) }
        for id in Set(closing.compactMap(\.containerID))
        where AppState.shared.isTemporary(id) && !tabs.contains(where: { $0.containerID == id }) {
            AppState.shared.releaseTemporary(id)
        }

        if tabs.isEmpty {
            selected = -1
            openTab(url: nil, container: closing.last?.containerID)
            return
        }
        let next: Int
        if indices.contains(selected) {
            next = min(last + 1 - indices.count, tabs.count - 1)
        } else {
            next = selected - indices.count(in: 0..<max(selected, 0))
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

    private func updateSecurityIndicator(for tab: Tab) {
        if tab.hasTLSError {
            securityIcon.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                                         accessibilityDescription: "TLS certificate error")
            securityIcon.contentTintColor = .systemRed
            securityIcon.toolTip = tab.tlsErrorMessage ?? "TLS certificate error"
            securityIcon.isHidden = false
        } else if tab.hasMixedContent {
            securityIcon.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                                         accessibilityDescription: "Mixed content")
            securityIcon.contentTintColor = .systemOrange
            securityIcon.toolTip = "Page includes insecure content"
            securityIcon.isHidden = false
        } else if tab.isHTTPS {
            securityIcon.image = NSImage(systemSymbolName: "lock.fill",
                                         accessibilityDescription: "HTTPS")
            securityIcon.contentTintColor = .systemGreen
            securityIcon.toolTip = "HTTPS"
            securityIcon.isHidden = false
        } else {
            securityIcon.isHidden = true
            securityIcon.toolTip = nil
        }
    }

    /// The address field, security indicator, container badge, status,
    /// progress bar and window title.
    private func updateChrome(editing: Bool? = nil) {
        guard let tab = current else { return }
        let editing = editing ?? (addressField.currentEditor() != nil)
        if !editing {
            addressField.stringValue = tab.url?.absoluteString ?? ""
        }
        updateSecurityIndicator(for: tab)
        updateStatusBadge(for: tab)
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

    private func updateStatusBadge(for tab: Tab) {
        guard let code = tab.statusCode else {
            statusBadgeBox.isHidden = true
            return
        }
        let color: NSColor = code >= 500 ? .systemRed : code >= 400 ? .systemOrange : .secondaryLabelColor
        statusBadge.stringValue = HTTPStatus.text(code)
        statusBadge.textColor = color
        statusBadgeBox.effectiveAppearance.performAsCurrentDrawingAppearance {
            statusBadgeBox.layer?.borderColor = color.withAlphaComponent(0.5).cgColor
        }
        statusBadgeBox.toolTip = "Response status of the page"
        statusBadgeBox.isHidden = false
    }

    // MARK: TabHost

    func tabDidChange(_ tab: Tab) {
        guard let row = index(of: tab) else { return }
        table.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
        refreshContainerIndicators()
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
        let rowView = TabRowView()
        configureRowView(rowView, at: row)
        return rowView
    }

    private func configureRowView(_ rowView: TabRowView, at row: Int) {
        guard tabs.indices.contains(row) else {
            rowView.containerColor = nil
            rowView.continuesAbove = false
            rowView.continuesBelow = false
            return
        }
        let containerID = tabs[row].containerID
        let color = AppState.shared.container(containerID).map { NSColor(hex: $0.color) }
        rowView.containerColor = color
        rowView.continuesAbove = color != nil && row > 0 && tabs[row - 1].containerID == containerID
        rowView.continuesBelow = color != nil && row + 1 < tabs.count && tabs[row + 1].containerID == containerID
    }

    private func refreshContainerIndicators() {
        table.enumerateAvailableRowViews { rowView, row in
            if let tabRow = rowView as? TabRowView {
                configureRowView(tabRow, at: row)
            }
        }
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
        return moveTab(from: from, to: from < row ? row - 1 : row)
    }

    /// Moves a tab in the list, keeping the same tab in front.
    @discardableResult
    func moveTab(from: Int, to: Int) -> Bool {
        guard tabs.indices.contains(from), tabs.indices.contains(to), to != from else { return false }
        let front = current
        let tab = tabs.remove(at: from)
        tabs.insert(tab, at: to)
        selected = front.flatMap(index(of:)) ?? selected
        table.reloadData()
        syncTableSelection()
        table.scrollRowToVisible(to)
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
        if tabs.count > 1 { menu.addItem(item("Close Other Tabs", #selector(closeOtherRows(_:)))) }
        if row < tabs.count - 1 { menu.addItem(item("Close Tabs Below", #selector(closeRowsBelow(_:)))) }
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

    @objc private func closeOtherRows(_ sender: NSMenuItem) {
        closeTabs(otherThan: sender.tag)
    }

    @objc private func closeRowsBelow(_ sender: NSMenuItem) {
        closeTabs(below: sender.tag)
    }

    private func closeTabs(otherThan row: Int) {
        guard tabs.indices.contains(row) else { return }
        var others = IndexSet(integersIn: tabs.indices)
        others.remove(row)
        // The kept tab comes to the front, so nothing else loads first.
        if row != selected { select(row) }
        closeTabs(at: others)
    }

    private func closeTabs(below row: Int) {
        guard tabs.indices.contains(row), row < tabs.count - 1 else { return }
        if selected > row { select(row) }
        closeTabs(at: IndexSet(integersIn: row + 1..<tabs.count))
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
        let s = AddressSuggestions(field: addressField, anchor: addressField)
        s.tabs = { [unowned self] in tabs }
        s.current = { [unowned self] in current }
        s.open = { [unowned self] url, newTab in
            if newTab || current == nil {
                openTab(url: url, container: current?.containerID, at: selected + 1)
            } else if let tab = current {
                tab.load(url)
                select(selected)
                window?.makeFirstResponder(tab.pageResponder)
            }
            updateChrome()
        }
        s.switchTo = { [unowned self] tab in
            addressField.stringValue = tab.url?.absoluteString ?? ""
            if let i = index(of: tab) { select(i) }
            window?.makeFirstResponder(current?.pageResponder)
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
        switch key {
        case "ctrl-tab": return stepSwitcher(backwards: false)
        case "ctrl-shift-tab": return stepSwitcher(backwards: true)
        case "ctrl-up": return finishSwitcher(commit: true)
        default: break
        }
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
        guard (obj.object as? NSTextField) === addressField else { return }
        suggestions.began()
    }

    func controlTextDidChange(_ obj: Notification) {
        if (obj.object as? NSTextField) === addressField { suggestions.textChanged() }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        if (obj.object as? NSTextField) === addressField {
            suggestions.hide()
            updateChrome(editing: false)
        }
    }

    func windowDidResize(_ notification: Notification) {
        alignAddressRow()
        suggestions.reposition()
    }

    func windowDidEnterFullScreen(_ notification: Notification) { alignAddressRow() }
    func windowDidExitFullScreen(_ notification: Notification) { alignAddressRow() }

    func windowDidResignKey(_ notification: Notification) {
        finishSwitcher(commit: true)
        suggestions.hide()
    }

    @objc private func addressEntered(_ sender: NSTextField) {
        guard let url = Address.resolve(sender.stringValue, searchTemplate: AppState.shared.settings.searchURL) else { return }
        if let tab = current {
            tab.load(url)
            select(selected)
            window?.makeFirstResponder(tab.pageResponder)
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
                if let responder = current?.pageResponder { window?.makeFirstResponder(responder) }
                updateChrome()
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
        if let responder = current?.pageResponder { window?.makeFirstResponder(responder) }
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

    @objc func closeOtherTabs(_ sender: Any?) {
        closeTabs(otherThan: selected)
    }

    @objc func closeTabsBelow(_ sender: Any?) {
        closeTabs(below: selected)
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
        if addressField.currentEditor() == nil {
            addressField.stringValue = current?.url?.absoluteString ?? ""
        }
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

    /// The menu item for ⌃Tab: straight to the tab used before this one.
    /// The key itself is handled by the key monitor, which cycles.
    @objc func showRecentTab(_ sender: Any?) {
        let order = recentTabs()
        guard order.count > 1, let i = index(of: order[1]) else { return }
        select(i)
    }

    /// Every tab, the front one first, then the most recently used.
    private func recentTabs() -> [Tab] {
        let front = current
        return tabs.enumerated()
            .sorted { a, b in
                if (a.element === front) != (b.element === front) { return a.element === front }
                if a.element.selectedAt != b.element.selectedAt { return a.element.selectedAt > b.element.selectedAt }
                return a.offset < b.offset
            }
            .map(\.element)
    }

    /// ⌃Tab (⌃⇧Tab backwards) while ⌃ is held steps through the tabs in the
    /// order they were used, marking the candidate in a list beside the tab
    /// list (and in the tab list); letting go of ⌃ shows it.
    private func stepSwitcher(backwards: Bool) {
        var state = switcher ?? (recentTabs(), 0)
        guard state.order.count > 1 else { return }
        let n = state.order.count
        state.position = (state.position + (backwards ? n - 1 : 1)) % n
        switcher = state
        if let i = index(of: state.order[state.position]) {
            syncingSelection = true
            table.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false)
            table.scrollRowToVisible(i)
            syncingSelection = false
        }
        showSwitcherPanel()
    }

    private func showSwitcherPanel() {
        guard let state = switcher, let window else { return }
        // Beside the tab list, lined up with it; where it would be when it's hidden.
        guard let list = table.enclosingScrollView else { return }
        var frame = window.convertToScreen(list.convert(list.bounds, to: nil))
        var gap: CGFloat = 8
        if tabListItem.isCollapsed {
            let page = window.convertToScreen(pageArea.convert(pageArea.bounds, to: nil))
            frame = NSRect(x: page.maxX, y: page.minY, width: frame.width > 0 ? frame.width : 240, height: page.height - 4)
            gap = 12
        }
        switcherPanel.show(state.order, position: state.position, beside: frame, gap: gap, parent: window)
    }

    private func finishSwitcher(commit: Bool) {
        switcherPanel.hide()
        guard let state = switcher else { return }
        switcher = nil
        let start = state.order.first.flatMap(index(of:))
        let chosen = commit ? index(of: state.order[state.position]) : start
        if let chosen { select(chosen) } else { syncTableSelection() }
    }

    func debugSwitcherView() -> NSView? { switcherPanel.isVisible ? switcherPanel.contentView : nil }

    /// The switcher's frame and first row, and the tab list's, in the
    /// window, while it's up.
    func debugSwitcherFrame() -> [String: String] {
        guard let panel = switcherPanel.contentView?.window, panel.parent != nil, let window,
              let row = switcherPanel.firstRowOnScreen, let list = table.enclosingScrollView else { return [:] }
        return ["panel": NSStringFromRect(window.convertFromScreen(panel.frame)),
                "panelFirstRow": NSStringFromRect(window.convertFromScreen(row)),
                "tabList": NSStringFromRect(list.convert(list.bounds, to: nil)),
                "tabListFirstRow": NSStringFromRect(table.convert(table.rect(ofRow: 0), to: nil))]
    }

    @objc func moveTabUp(_ sender: Any?) {
        moveTab(from: selected, to: selected - 1)
    }

    @objc func moveTabDown(_ sender: Any?) {
        moveTab(from: selected, to: selected + 1)
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

    @objc func followLink(_ sender: Any?) {
        current?.showHints()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let webView = current?.webView
        switch item.action {
        case #selector(goBack(_:)): return webView?.canGoBack ?? false
        case #selector(goForward(_:)): return webView?.canGoForward ?? false
        case #selector(stopLoading(_:)): return webView?.isLoading ?? false
        case #selector(zoomIn(_:)), #selector(zoomOut(_:)), #selector(actualSize(_:)),
             #selector(reloadFromOrigin(_:)), #selector(findNext(_:)), #selector(findPrevious(_:)), #selector(showFind(_:)),
             #selector(followLink(_:)):
            return webView != nil
        case #selector(copyAddress(_:)): return current?.url != nil
        case #selector(clearSiteData(_:)):
            let host = current?.url?.host().map(Hosts.siteKey)
            item.title = host.map { "Clear Cookies and Data for \($0)" } ?? "Clear Cookies and Data for This Site"
            return host != nil
        case #selector(reopenClosedTab(_:)): return !closedTabs.isEmpty
        case #selector(closeOtherTabs(_:)): return tabs.count > 1
        case #selector(closeTabsBelow(_:)), #selector(moveTabDown(_:)): return selected < tabs.count - 1
        case #selector(moveTabUp(_:)): return selected > 0
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

    /// ⌃Tab and ⌃⇧Tab, which menus can't reliably claim from the web view,
    /// and letting go of ⌃ (or Escape) to end them.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if event.type == .flagsChanged {
                if self.switcher != nil, !flags.contains(.control) { self.finishSwitcher(commit: true) }
                return event
            }
            if self.switcher != nil, event.keyCode == 53 {
                self.finishSwitcher(commit: false)
                return nil
            }
            guard event.keyCode == 48, flags.contains(.control), !flags.contains(.command) else { return event }
            self.stepSwitcher(backwards: flags.contains(.shift))
            return nil
        }
        // The side buttons on a mouse (3 and 4, counting from 0) go back and
        // forward, on release like Safari. Both halves of the click are kept
        // from the page so it doesn't act on them too.
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.otherMouseDown, .otherMouseUp]) { [weak self] event in
            guard let self, event.window === self.window, [3, 4].contains(event.buttonNumber) else { return event }
            if event.type == .otherMouseUp {
                if event.buttonNumber == 3 { self.goBack(nil) } else { self.goForward(nil) }
            }
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
        if let symbol = info["symbol"] as? String {
            statusIcon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        } else {
            statusIcon.image = nil
        }
        statusIcon.isHidden = statusIcon.image == nil
        statusCancelAction = info["cancel"] as? () -> Void
        statusCancel.isHidden = statusCancelAction == nil
        statusTimer?.invalidate()
        if !(info["sticky"] as? Bool ?? false) {
            statusTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.clearStatus()
                }
            }
        }
    }

    private func clearStatus() {
        statusButton.title = ""
        statusButton.toolTip = nil
        statusFile = nil
        statusIcon.image = nil
        statusIcon.isHidden = true
        statusCancelAction = nil
        statusCancel.isHidden = true
    }

    @objc private func revealStatusFile(_ sender: Any?) {
        if let file = statusFile {
            NSWorkspace.shared.activateFileViewerSelecting([file])
        }
        clearStatus()
    }

    @objc private func cancelStatusAction(_ sender: Any?) {
        statusCancelAction?()
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

/// A row in the tab list: the favicon, the title, a spinner.
final class TabCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("TabCell")

    private let favicon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let speaker = NSImageView()

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        title.lineBreakMode = .byTruncatingTail
        title.font = UI.font
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        favicon.imageScaling = .scaleProportionallyUpOrDown
        speaker.image = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: "Playing audio")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
        speaker.contentTintColor = .secondaryLabelColor
        for v in [favicon, title, spinner, speaker] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            // `.sourceList` insets the cell by 16pt from the row view's left edge,
            // placing the favicon 8pt inside the selection pill (x = 17 in row coords).
            favicon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
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
            speaker.centerXAnchor.constraint(equalTo: spinner.centerXAnchor),
            speaker.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private var isUnloaded = false

    // The title isn't the cell's `textField`: a source list would pass it the
    // selected row's style, which draws it bold. The accent pill is enough.
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateTitleColor() }
    }

    private func updateTitleColor() {
        let selected = backgroundStyle == .emphasized
        title.textColor = selected ? .alternateSelectedControlTextColor
            : isUnloaded ? .secondaryLabelColor : .labelColor
    }

    static let placeholder: NSImage? = {
        let image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        return image?.withSymbolConfiguration(.init(paletteColors: [.tertiaryLabelColor]))
    }()

    func show(_ tab: Tab) {
        title.stringValue = tab.title
        // Unloaded tabs are dimmed; they load again when clicked.
        isUnloaded = tab.isUnloaded
        updateTitleColor()
        favicon.image = tab.icon ?? Self.placeholder
        favicon.alphaValue = tab.isUnloaded ? 0.5 : 1
        toolTip = tab.url?.absoluteString
        // Sound wins: a media file can play long before it has all loaded.
        speaker.isHidden = !tab.isPlayingAudio
        if tab.isLoading && !tab.isPlayingAudio { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
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
/// moves to the page, instead of fading to the unemphasized grey, and
/// draws the container indicator strip in the gutter outside the pill.
final class TabRowView: NSTableRowView {
    var containerColor: NSColor? {
        didSet {
            if containerColor != oldValue { needsDisplay = true }
        }
    }
    var continuesAbove = false {
        didSet {
            if continuesAbove != oldValue { needsDisplay = true }
        }
    }
    var continuesBelow = false {
        didSet {
            if continuesBelow != oldValue { needsDisplay = true }
        }
    }

    override var isEmphasized: Bool {
        get { true }
        set {}
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard let containerColor else { return }

        let topInset: CGFloat = continuesAbove ? 0 : 6
        let bottomInset: CGFloat = continuesBelow ? 0 : 6
        let minYInset = isFlipped ? topInset : bottomInset
        let maxYInset = isFlipped ? bottomInset : topInset
        let rect = NSRect(x: 3, y: minYInset, width: 4, height: bounds.height - minYInset - maxYInset)
        guard rect.height > 0 else { return }

        let roundMinY = isFlipped ? !continuesAbove : !continuesBelow
        let roundMaxY = isFlipped ? !continuesBelow : !continuesAbove
        let radius = min(2.5, rect.width / 2, rect.height / 2)
        let minYRadius = roundMinY ? radius : 0
        let maxYRadius = roundMaxY ? radius : 0

        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.minX + minYRadius, y: rect.minY))
        path.line(to: NSPoint(x: rect.maxX - minYRadius, y: rect.minY))
        if minYRadius > 0 {
            path.appendArc(from: NSPoint(x: rect.maxX, y: rect.minY),
                           to: NSPoint(x: rect.maxX, y: rect.minY + minYRadius),
                           radius: minYRadius)
        }
        path.line(to: NSPoint(x: rect.maxX, y: rect.maxY - maxYRadius))
        if maxYRadius > 0 {
            path.appendArc(from: NSPoint(x: rect.maxX, y: rect.maxY),
                           to: NSPoint(x: rect.maxX - maxYRadius, y: rect.maxY),
                           radius: maxYRadius)
        }
        path.line(to: NSPoint(x: rect.minX + maxYRadius, y: rect.maxY))
        if maxYRadius > 0 {
            path.appendArc(from: NSPoint(x: rect.minX, y: rect.maxY),
                           to: NSPoint(x: rect.minX, y: rect.maxY - maxYRadius),
                           radius: maxYRadius)
        }
        path.line(to: NSPoint(x: rect.minX, y: rect.minY + minYRadius))
        if minYRadius > 0 {
            path.appendArc(from: NSPoint(x: rect.minX, y: rect.minY),
                           to: NSPoint(x: rect.minX + minYRadius, y: rect.minY),
                           radius: minYRadius)
        }
        path.close()

        containerColor.setFill()
        path.fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let rect = NSRect(x: 17, y: 1, width: bounds.width - 27, height: bounds.height - 2)
        guard rect.width > 0, rect.height > 0 else { return }
        NSColor.selectedContentBackgroundColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
    }
}

/// The tab list: a middle click on a tab closes it.
/// The sidebar's background: dragging it moves the window.
final class SidebarView: NSVisualEffectView {
    override func mouseDown(with event: NSEvent) {
        if let window { window.performDrag(with: event) } else { super.mouseDown(with: event) }
    }
}

final class TabTableView: NSTableView {
    var onMiddleClick: ((Int) -> Void)?
    var onMouseDown: ((Int) -> Void)?

    /// Tabs switch the moment the button goes down, not when it comes up
    /// (a table that allows dragging normally waits for mouse-up).
    override func mouseDown(with event: NSEvent) {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        // The blank space around and below the tabs moves the window, as
        // the title bar would.
        if row < 0, !event.modifierFlags.contains(.control), let window {
            return window.performDrag(with: event)
        }
        if row >= 0, !event.modifierFlags.contains(.control) { onMouseDown?(row) }
        super.mouseDown(with: event)
    }

    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return super.otherMouseUp(with: event) }
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        if row >= 0 { onMiddleClick?(row) }
    }
}
