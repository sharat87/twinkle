import AppKit
import TwinkleCore

/// The address bar's dropdown: history and open tabs, fuzzy-matched as you
/// type (see HistoryIndex), with the address completed inline when what you
/// typed is the start of one you've visited (`git` → `git|hub.com`).
///
/// It's a borderless child window under the field that never takes focus,
/// so the field keeps the keyboard: ↑/↓ choose, ↩ opens, ⌘↩ opens in a new
/// tab, ⇥ puts the chosen address in the field to edit, ⎋ closes.
@MainActor
final class AddressSuggestions: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    struct Row {
        enum Kind { case typed, page, tab(Tab) }
        var kind: Kind
        var title: String
        var detail: String
        /// What opens; nil for "Search for …", which is the field's text.
        var url: URL?
    }

    var open: (URL, _ newTab: Bool) -> Void = { _, _ in }
    var switchTo: (Tab) -> Void = { _ in }
    var tabs: () -> [Tab] = { [] }
    var current: () -> Tab? = { nil }

    private let field: NSTextField
    private let anchor: NSView
    private let panel: NSPanel
    private let table = SuggestionTable()
    private let scroll = NSScrollView()
    private let background = NSVisualEffectView()
    private var rows: [Row] = []
    private var highlighted = 0
    /// What was typed, without the inline completion.
    private var typed = ""
    /// The field's text for row 0 (typed plus any completion).
    private var fieldText = ""

    static let rowHeight: CGFloat = 38
    static let maxRows = 9
    static let maxWidth: CGFloat = 960

    init(field: NSTextField, anchor: NSView) {
        self.field = field
        self.anchor = anchor
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true

        let background = self.background
        background.material = .menu
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true

        let column = NSTableColumn(identifier: .init("row"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.style = .plain
        table.selectionHighlightStyle = .none
        table.dataSource = self
        table.delegate = self
        table.onHover = { [weak self] row in self?.highlight(row, updateField: false) }
        table.onClick = { [weak self] row in
            guard let self else { return }
            self.highlighted = row
            self.perform(newTab: NSEvent.modifierFlags.contains(.command))
        }

        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.contentInsets = NSEdgeInsets(top: 5, left: 0, bottom: 5, right: 0)
        scroll.automaticallyAdjustsContentInsets = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 5),
            scroll.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -5),
            scroll.topAnchor.constraint(equalTo: background.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        // The window stays its full height; only this box changes size.
        let holder = NSView()
        holder.addSubview(background)
        panel.contentView = holder
    }

    var isVisible: Bool { showing }
    var contentView: NSView? { panel.contentView }
    var debugRows: [String] {
        guard showing else { return [] }
        return rows.enumerated().map { i, r in "\(i == highlighted ? "> " : "  ")\(r.title) | \(r.detail)" }
    }

    /// Before the first key: history loaded, the list laid out once, so
    /// the first letter is as quick as the rest.
    func prepare() {
        _ = AppState.shared.suggestionIndex
        guard !prepared else { return }
        prepared = true
        rows = [Row(kind: .typed, title: " ", detail: " ", url: nil)]
        table.reloadData()
        panel.contentView?.layoutSubtreeIfNeeded()
        rows = []
        table.reloadData()
        // On screen from now on, invisible until needed.
        if let window = anchor.window {
            panel.alphaValue = 0
            panel.ignoresMouseEvents = true
            window.addChildWindow(panel, ordered: .above)
            place(rows: 0)
            panel.orderFront(nil)
        }
    }
    private var prepared = false

    /// The field just got focus, its text all selected.
    func began() {
        typed = ""
        hide()
    }

    /// The field's text changed by typing.
    func textChanged() {
        let text = field.stringValue
        let editor = field.currentEditor()
        let atEnd = editor.map { $0.selectedRange.location == (text as NSString).length && $0.selectedRange.length == 0 } ?? true
        // Deleting (or nothing new): don't complete, or ⌫ would be undone.
        let grew = (text as NSString).length > (typed as NSString).length && text.lowercased().hasPrefix(typed.lowercased())
        typed = text
        update(complete: grew && atEnd)
    }

    private func update(complete: Bool) {
        let query = typed.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return hide() }
        let now = Date()
        let index = AppState.shared.suggestionIndex
        let history = index.search(query, limit: 12, now: now)
        // Bookmarks rank above plain history.
        let bookmarks = AppState.shared.bookmarkIndex.search(query, limit: 5, now: now).map { ($0.entry, $0.score + 25) }

        // Open tabs, apart from the one in front, scored like history.
        let front = current()
        let tabMatches: [(Tab, Int)] = tabs().compactMap { tab in
            guard tab !== front, let url = tab.url, ["http", "https"].contains(url.scheme ?? "") else { return nil }
            let entry = index.entry(for: url.absoluteString)
                ?? HistoryEntry(url: url.absoluteString, title: tab.pageTitle, visits: 1, lastVisit: now)
            return index.score(entry, text: query, now: now).map { (tab, $0 + 10) }
        }.sorted { $0.1 > $1.1 }

        // Inline completion: the best address that starts with what was typed.
        fieldText = typed
        if complete, !query.contains(" ") {
            let lower = typed.lowercased()
            let candidates = tabMatches.prefix(3).compactMap { $0.0.url?.absoluteString } + bookmarks.prefix(3).map(\.0.url)
                + history.prefix(6).map(\.entry.url)
            for url in candidates {
                let bare = HistoryIndex.bare(url)
                guard bare.hasPrefix(lower), bare.count > lower.count else { continue }
                // Just the site, unless a path is being typed.
                var completion = bare
                if !lower.contains("/"), let slash = bare.firstIndex(of: "/") { completion = String(bare[..<slash]) }
                guard completion.count > lower.count else { continue }
                fieldText = typed + completion.dropFirst(lower.count)
                break
            }
        }
        if fieldText != typed {
            field.stringValue = fieldText
            let start = (typed as NSString).length
            field.currentEditor()?.selectedRange = NSRange(location: start, length: (fieldText as NSString).length - start)
        }

        // Tabs and history together, best first; each page once.
        var rows: [Row] = [typedRow(fieldText, index: index)]
        var shown = Set([rows[0].url.map { HistoryIndex.bare($0.absoluteString) } ?? ""])
        enum Source { case tab(Tab), page(HistoryEntry), bookmark(HistoryEntry) }
        let ranked = (tabMatches.prefix(3).map { (Source.tab($0.0), $0.1) }
            + bookmarks.map { (Source.bookmark($0.0), $0.1) }
            + history.map { (Source.page($0.entry), $0.score) })
            .sorted { $0.1 > $1.1 }
        for (source, _) in ranked where rows.count < Self.maxRows {
            switch source {
            case .tab(let tab):
                guard let url = tab.url, shown.insert(HistoryIndex.bare(url.absoluteString)).inserted else { continue }
                rows.append(Row(kind: .tab(tab), title: tab.pageTitle.isEmpty ? Self.display(url.absoluteString) : tab.pageTitle,
                                detail: "Switch to tab · " + Self.display(url.absoluteString), url: url))
            case .page(let entry):
                guard shown.insert(HistoryIndex.bare(entry.url)).inserted, let url = URL(string: entry.url) else { continue }
                rows.append(Row(kind: .page, title: entry.title.isEmpty ? Self.display(entry.url) : entry.title,
                                detail: Self.display(entry.url), url: url))
            case .bookmark(let entry):
                guard shown.insert(HistoryIndex.bare(entry.url)).inserted, let url = URL(string: entry.url) else { continue }
                rows.append(Row(kind: .page, title: entry.title.isEmpty ? Self.display(entry.url) : entry.title,
                                detail: "★ " + Self.display(entry.url), url: url))
            }
        }
        self.rows = rows
        highlighted = 0
        table.reloadData()
        show()
    }

    /// Row 0: what the field says, as an address or a search. Named after
    /// the page if it's one you've been to.
    private func typedRow(_ text: String, index: HistoryIndex) -> Row {
        let settings = AppState.shared.settings
        guard let url = Address.resolve(text, searchTemplate: settings.searchURL) else {
            return Row(kind: .typed, title: text, detail: "", url: nil)
        }
        if Address.asURL(text) == nil {
            let engine = URL(string: settings.searchURL)?.host() ?? "the web"
            return Row(kind: .typed, title: "Search for “\(text)”", detail: engine, url: nil)
        }
        let bookmarks = AppState.shared.bookmarkIndex
        let keys = [url.absoluteString, url.absoluteString + "/"]
        let bookmark = keys.lazy.compactMap { bookmarks.entry(for: $0) }.first
        let known = bookmark ?? keys.lazy.compactMap { index.entry(for: $0) }.first
        let title = known.map(\.title).flatMap { $0.isEmpty ? nil : $0 } ?? Self.display(url.absoluteString)
        var detail = Self.display(url.absoluteString)
        if bookmark != nil { detail = "★ " + detail }
        return Row(kind: .typed, title: title, detail: detail, url: url)
    }

    static func display(_ url: String) -> String {
        var s = Substring(url)
        if let r = s.range(of: "://") { s = s[r.upperBound...] }
        if s.hasPrefix("www.") { s = s.dropFirst(4) }
        if s.hasSuffix("/") { s = s.dropLast() }
        return String(s)
    }

    // MARK: Keys

    /// From the field's delegate; true if handled.
    func handle(_ selector: Selector, newTab: Bool? = nil) -> Bool {
        guard showing, !rows.isEmpty else { return false }
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            highlight(min(highlighted + 1, rows.count - 1), updateField: true)
        case #selector(NSResponder.moveUp(_:)):
            highlight(max(highlighted - 1, 0), updateField: true)
        case #selector(NSResponder.insertNewline(_:)):
            perform(newTab: newTab ?? NSApp.currentEvent?.modifierFlags.contains(.command) ?? false)
        case #selector(NSResponder.insertTab(_:)):
            // The chosen address into the field, cursor at the end.
            let text = rows[highlighted].url.map { Self.display($0.absoluteString) } ?? field.stringValue
            field.stringValue = text
            field.currentEditor()?.selectedRange = NSRange(location: (text as NSString).length, length: 0)
            typed = text
            update(complete: false)
        case #selector(NSResponder.cancelOperation(_:)):
            hide()
            return false   // the field puts the page's address back
        default:
            return false
        }
        return true
    }

    private func highlight(_ row: Int, updateField: Bool) {
        guard rows.indices.contains(row), row != highlighted else { return }
        let old = highlighted
        highlighted = row
        table.scrollRowToVisible(row)
        for r in [old, row] {
            let on = r == highlighted
            (table.rowView(atRow: r, makeIfNecessary: false) as? SuggestionRowView)?.isOn = on
            (table.view(atColumn: 0, row: r, makeIfNecessary: false) as? SuggestionCell)?.updateHighlight(on)
        }
        guard updateField else { return }
        let text = row == 0 ? fieldText : (rows[row].url.map { Self.display($0.absoluteString) } ?? fieldText)
        field.stringValue = text
        let end = (text as NSString).length
        if row == 0, fieldText != typed {
            let start = (typed as NSString).length
            field.currentEditor()?.selectedRange = NSRange(location: start, length: end - start)
        } else {
            field.currentEditor()?.selectedRange = NSRange(location: end, length: 0)
        }
    }

    private func perform(newTab: Bool) {
        guard rows.indices.contains(highlighted) else { return }
        let row = rows[highlighted]
        hide()
        switch row.kind {
        case .tab(let tab) where !newTab:
            switchTo(tab)
        case .typed where row.url == nil:
            if let url = Address.resolve(fieldText, searchTemplate: AppState.shared.settings.searchURL) { open(url, newTab) }
        default:
            if let url = row.url { open(url, newTab) }
        }
    }

    // MARK: Window

    /// Hidden by fading out rather than ordering out: putting a window on
    /// screen costs several milliseconds, a change of alpha almost nothing.
    func hide() {
        guard showing else { return }
        showing = false
        panel.alphaValue = 0
        panel.ignoresMouseEvents = true
    }
    private var showing = false

    private func show() {
        guard let window = anchor.window else { return }
        place(rows: rows.count)
        if panel.parent == nil {
            window.addChildWindow(panel, ordered: .above)
            panel.orderFront(nil)
        }
        if !showing {
            showing = true
            panel.alphaValue = 1
            panel.ignoresMouseEvents = false
        }
    }

    private func place(rows count: Int) {
        guard let window = anchor.window else { return }
        let box = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let full = CGFloat(Self.maxRows) * Self.rowHeight + 10
        let width = min(box.width, Self.maxWidth)
        let frame = NSRect(x: box.minX, y: box.minY - 6 - full, width: width, height: full)
        if panel.frame != frame { panel.setFrame(frame, display: false) }
        let height = CGFloat(min(count, Self.maxRows)) * Self.rowHeight + 10
        let inner = NSRect(x: 0, y: full - height, width: width, height: height)
        if background.frame != inner {
            background.frame = inner
            panel.invalidateShadow()
        }
    }

    /// Keeps it under the field when the window changes size.
    func reposition() {
        if panel.parent != nil { place(rows: showing ? rows.count : 0) }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = SuggestionRowView()
        view.isOn = row == highlighted
        return view
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: SuggestionCell.identifier, owner: nil) as? SuggestionCell ?? SuggestionCell()
        let item = rows[row]
        let icon: NSImage?
        switch item.kind {
        case .typed where item.url == nil:
            icon = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        case .tab(let tab):
            icon = tab.icon ?? NSImage(systemSymbolName: "square.on.square", accessibilityDescription: nil)
        default:
            icon = item.url.flatMap { Favicons.shared.cached(for: $0, container: nil) }
                ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        }
        cell.set(title: item.title, detail: item.detail, icon: icon, on: row == highlighted)
        return cell
    }
}

/// Never takes focus (the address field keeps it); reports hover and clicks.
final class SuggestionTable: NSTableView {
    var onHover: (Int) -> Void = { _ in }
    var onClick: (Int) -> Void = { _ in }

    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        if row >= 0 { onHover(row) }
    }

    override func mouseDown(with event: NSEvent) {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        if row >= 0 { onClick(row) }
    }
}

final class SuggestionRowView: NSTableRowView {
    var isOn = false {
        didSet { if isOn != oldValue { needsDisplay = true } }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        guard isOn else { return }
        NSColor.selectedContentBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }
}

final class SuggestionCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("SuggestionCell")

    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        title.font = UI.font
        title.lineBreakMode = .byTruncatingTail
        detail.font = .systemFont(ofSize: UI.textSize - 2)
        detail.lineBreakMode = .byTruncatingMiddle
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        title.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        icon.imageScaling = .scaleProportionallyUpOrDown
        let row = NSStackView(views: [icon, title, detail])
        row.orientation = .horizontal
        row.spacing = 10
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(title: String, detail: String, icon: NSImage?, on: Bool) {
        self.title.stringValue = title
        self.detail.stringValue = detail
        self.detail.isHidden = detail.isEmpty
        self.icon.image = icon
        updateHighlight(on)
    }

    func updateHighlight(_ on: Bool) {
        self.title.textColor = on ? .alternateSelectedControlTextColor : .labelColor
        self.detail.textColor = on ? .alternateSelectedControlTextColor.withAlphaComponent(0.8) : .secondaryLabelColor
        self.icon.contentTintColor = on ? .alternateSelectedControlTextColor : .secondaryLabelColor
    }
}
