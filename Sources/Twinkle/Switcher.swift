import AppKit

/// The list ⌃Tab steps through, most recently used first, while ⌃ is held:
/// a copy of the tab list (the same rows) floating beside it. It never
/// takes the keyboard or the mouse.
@MainActor
final class TabSwitcherPanel: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let panel: NSPanel
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private var order: [Tab] = []

    var isVisible: Bool { panel.parent != nil }
    /// For debug.sh.
    var contentView: NSView? { panel.contentView }

    override init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none

        let background = NSVisualEffectView()
        background.material = .sidebar
        background.blendingMode = .behindWindow
        background.state = .active
        background.maskImage = Self.roundedMask(radius: 10)

        // Set up as the tab list is (BrowserWindowController.makeSidebar).
        let column = NSTableColumn(identifier: .init("tab"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .sourceList
        table.backgroundColor = .clear
        table.rowHeight = BrowserWindowController.tabRowHeight
        table.intercellSpacing = .zero
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsetsZero
        scroll.autoresizingMask = [.width, .height]
        background.addSubview(scroll)
        panel.contentView = background
    }

    /// Shows `order` with `position` marked. `list` is the tab list's
    /// scroll view in screen coordinates: the copy takes its width and top
    /// edge, ends `gap` to its left, and grows down no further than it.
    func show(_ order: [Tab], position: Int, beside list: NSRect, gap: CGFloat, parent: NSWindow) {
        self.order = order
        table.reloadData()
        // The source-list style pads above the first row, as in the tab list.
        let content = table.rect(ofRow: order.count - 1).maxY + 6
        let height = min(content, list.height)
        let frame = NSRect(x: list.minX - gap - list.width, y: list.maxY - height, width: list.width, height: height)
        panel.setFrame(frame, display: false)
        scroll.frame = NSRect(origin: .zero, size: frame.size)
        table.selectRowIndexes(IndexSet(integer: position), byExtendingSelection: false)
        table.scrollRowToVisible(position)

        if panel.parent == nil { parent.addChildWindow(panel, ordered: .above) }
        panel.display()
    }

    func hide() {
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        order = []
    }

    /// Row 0's frame on screen, for debug.sh to check it lines up.
    var firstRowOnScreen: NSRect? {
        guard isVisible, !order.isEmpty else { return nil }
        return panel.convertToScreen(table.convert(table.rect(ofRow: 0), to: nil))
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { order.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = TabRowView()
        let id = order[row].containerID
        let color = AppState.shared.container(id).map { NSColor(hex: $0.color) }
        rowView.containerColor = color
        rowView.continuesAbove = color != nil && row > 0 && order[row - 1].containerID == id
        rowView.continuesBelow = color != nil && row + 1 < order.count && order[row + 1].containerID == id
        return rowView
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: TabCell.identifier, owner: nil) as? TabCell ?? TabCell()
        cell.show(order[row])
        return cell
    }

    private static func roundedMask(radius r: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: 2 * r + 1, height: 2 * r + 1), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        image.resizingMode = .stretch
        return image
    }
}
