import AppKit

/// The list ⌃Tab steps through, most recently used first, floating beside
/// the tab list while ⌃ is held. It never takes the keyboard or the mouse.
@MainActor
final class TabSwitcherPanel {
    private static let rowHeight: CGFloat = 30
    private static let width: CGFloat = 320
    private static let inset: CGFloat = 6
    private static let maxRows = 15

    private let panel: NSPanel
    private let list = NSView()

    var isVisible: Bool { panel.parent != nil }
    /// For debug.sh.
    var contentView: NSView? { panel.contentView }

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none

        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.maskImage = Self.roundedMask(radius: 10)
        list.autoresizingMask = [.width, .height]
        background.addSubview(list)
        panel.contentView = background
    }

    /// Shows `order` with `position` marked, its right edge at `right` and
    /// centred on `midY` (screen coordinates), over `parent`.
    func show(_ order: [Tab], position: Int, right: CGFloat, midY: CGFloat, parent: NSWindow) {
        let count = min(order.count, Self.maxRows)
        // With more tabs than fit, the window of rows follows the mark.
        let first = max(0, min(position - count / 2, order.count - count))

        let height = CGFloat(count) * Self.rowHeight + 2 * Self.inset
        var frame = NSRect(x: right - Self.width, y: midY - height / 2, width: Self.width, height: height)
        let bounds = parent.frame
        frame.origin.x = max(bounds.minX + 8, frame.origin.x)
        frame.origin.y = max(bounds.minY + 8, min(frame.origin.y, bounds.maxY - height - 8))
        panel.setFrame(frame, display: false)

        list.frame = NSRect(origin: .zero, size: frame.size)
        list.subviews.forEach { $0.removeFromSuperview() }
        for (row, i) in (first..<first + count).enumerated() {
            let y = height - Self.inset - CGFloat(row + 1) * Self.rowHeight
            let view = SwitcherRow(frame: NSRect(x: Self.inset, y: y, width: Self.width - 2 * Self.inset, height: Self.rowHeight))
            view.show(order[i], marked: i == position)
            list.addSubview(view)
        }

        if panel.parent == nil { parent.addChildWindow(panel, ordered: .above) }
        panel.display()
    }

    func hide() {
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
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

/// A tab in the switcher: its container's colour, favicon and title, drawn
/// like a tab list row.
private final class SwitcherRow: NSView {
    private let favicon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private var marked = false
    private var containerColor: NSColor?

    override init(frame: NSRect) {
        super.init(frame: frame)
        favicon.imageScaling = .scaleProportionallyUpOrDown
        favicon.frame = NSRect(x: 22, y: (frame.height - 18) / 2, width: 18, height: 18)
        title.font = UI.font
        title.lineBreakMode = .byTruncatingTail
        title.sizeToFit()
        let h = title.frame.height
        title.frame = NSRect(x: 48, y: (frame.height - h) / 2, width: frame.width - 56, height: h)
        addSubview(favicon)
        addSubview(title)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ tab: Tab, marked: Bool) {
        self.marked = marked
        containerColor = AppState.shared.container(tab.containerID).map { NSColor(hex: $0.color) }
        title.stringValue = tab.title
        title.textColor = marked ? .alternateSelectedControlTextColor
            : tab.isUnloaded ? .secondaryLabelColor : .labelColor
        favicon.image = tab.icon ?? TabCell.placeholder
        favicon.alphaValue = tab.isUnloaded && !marked ? 0.5 : 1
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if marked {
            NSColor.selectedContentBackgroundColor.setFill()
            // Clear of the container bar, as in the tab list.
            NSBezierPath(roundedRect: NSRect(x: 14, y: 1, width: bounds.width - 14, height: bounds.height - 2),
                         xRadius: 6, yRadius: 6).fill()
        }
        if let containerColor {
            containerColor.setFill()
            NSBezierPath(roundedRect: NSRect(x: 3, y: 5, width: 4, height: bounds.height - 10), xRadius: 2, yRadius: 2).fill()
        }
    }
}
