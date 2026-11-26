import AppKit
import WebKit

/// Follow Link (⌘I): type the text of a link, button or field on screen to
/// click or focus it. Ones with no text of their own get a two-letter label
/// instead, picked so it isn't in any text on screen: typing it can only
/// mean that one.
///
/// The page is read by a script in Twinkle's own script world, out of the
/// page's sight; the labels are native views over the web view.
@MainActor
enum Hints {
    struct Target {
        let index: Int
        /// In the web view's points, from its top left.
        let rect: NSRect
        /// Lowercased, for matching; empty if the target has a label.
        let text: String
        let label: String
    }

    static func show(in webView: WKWebView, newTab: Bool, open: @escaping (URL) -> Void) {
        webView.evaluateJavaScript(collectScript, in: nil, in: .defaultClient) { result in
            guard let rows = (try? result.get()) as? [[Any]], !rows.isEmpty else { return NSSound.beep() }
            let zoom = webView.pageZoom
            var targets: [(Int, NSRect, String)] = []
            for (i, row) in rows.enumerated() {
                guard row.count == 5, let x = row[0] as? Double, let y = row[1] as? Double,
                      let w = row[2] as? Double, let h = row[3] as? Double else { continue }
                let text = (row[4] as? String ?? "").lowercased()
                targets.append((i, NSRect(x: x * zoom, y: y * zoom, width: w * zoom, height: h * zoom), text))
            }
            var labels = labelsAvoiding(targets.map(\.2)).makeIterator()
            let all = targets.map { i, rect, text in
                Target(index: i, rect: rect, text: text, label: text.isEmpty ? labels.next() ?? "" : "")
            }
            let overlay = HintsOverlay(targets: all) { [weak webView] target in
                guard let webView else { return }
                webView.window?.makeFirstResponder(webView)
                let script = "window.__twinkleHint?.(\(target.index), \(newTab))"
                webView.evaluateJavaScript(script, in: nil, in: .defaultClient) { result in
                    if let href = (try? result.get()) as? String, let url = URL(string: href) { open(url) }
                }
            }
            overlay.frame = webView.bounds
            overlay.autoresizingMask = [.width, .height]
            webView.addSubview(overlay)
            webView.window?.makeFirstResponder(overlay)
        }
    }

    /// Two-letter labels, home row first, leaving out any that appear in
    /// the text on screen.
    static func labelsAvoiding(_ texts: [String]) -> [String] {
        let letters = Array("fjdkslaghrueiwoqptyvmcnxbz")
        let all = texts.joined(separator: "\n")
        var out: [String] = []
        for a in letters {
            for b in letters where a != b {
                let label = String([a, b])
                if !all.contains(label) { out.append(label) }
            }
        }
        return out
    }

    /// `[[x, y, width, height, text]]` for what's on screen, in CSS pixels
    /// from the viewport's top left; same-origin frames and open shadow
    /// roots included. Leaves `__twinkleHint(i, newTab)` behind to act on
    /// one: a link's address for a new tab, else it clicks or focuses it.
    private static let collectScript = """
    (() => {
      const selector = 'a, button, input, select, textarea, [contenteditable], [onclick], [role=button], [role=link]';
      const clean = s => (s || '').replace(/\\s+/g, ' ').trim();
      const buttonTypes = ['submit', 'button', 'reset'];
      const textOf = el => {
        if (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA' || el.tagName === 'SELECT') {
          const type = (el.type || '').toLowerCase();
          if (buttonTypes.includes(type)) return clean(el.value);
          const parts = [...(el.labels || [])].map(l => clean(l.innerText));
          parts.push(clean(el.placeholder));
          if (el.tagName === 'SELECT') parts.push(clean(el.selectedOptions[0]?.text));
          return parts.filter(Boolean).join(' ');
        }
        return clean(el.innerText).slice(0, 300);
      };
      const found = [], rows = [], seen = new Map();
      const walk = (root, ox, oy, vw, vh) => {
        for (const el of root.querySelectorAll(selector)) {
          if (el.getAttribute('contenteditable') === 'false' || el.disabled) continue;
          if (el.tagName === 'INPUT' && el.type === 'hidden') continue;
          if (el.checkVisibility && !el.checkVisibility({ checkOpacity: true, checkVisibilityCSS: true })) continue;
          const r = el.getBoundingClientRect();
          if (r.width < 2 || r.height < 2 || r.bottom <= 0 || r.right <= 0 || r.top >= vh || r.left >= vw) continue;
          // Something else on top of it (a dialog, a banner) hides it.
          const cx = (Math.max(r.left, 0) + Math.min(r.right, vw)) / 2;
          const cy = (Math.max(r.top, 0) + Math.min(r.bottom, vh)) / 2;
          const hit = root.elementFromPoint(cx, cy);
          if (hit && hit !== el && !el.contains(hit) && !hit.contains(el)) continue;
          const text = textOf(el);
          // A clickable thing inside another with the same text is the same target.
          let p = el.parentElement, same = false;
          while (p && !same) { same = seen.get(p) === text; p = p.parentElement; }
          if (same) continue;
          seen.set(el, text);
          found.push(el);
          rows.push([r.left + ox, r.top + oy, r.width, r.height, text]);
        }
        for (const el of root.querySelectorAll('*')) {
          if (el.shadowRoot) walk(el.shadowRoot, ox, oy, vw, vh);
          if (el.tagName === 'IFRAME' || el.tagName === 'FRAME') {
            let doc = null;
            try { doc = el.contentDocument; } catch (e) {}
            if (!doc) continue;
            const r = el.getBoundingClientRect();
            const fx = ox + r.left + el.clientLeft, fy = oy + r.top + el.clientTop;
            walk(doc, fx, fy, el.clientWidth, el.clientHeight);
          }
        }
      };
      walk(document, 0, 0, window.innerWidth, window.innerHeight);
      const keep = ['submit', 'button', 'reset', 'checkbox', 'radio', 'file', 'image', 'color', 'range'];
      window.__twinkleHint = (i, newTab) => {
        const el = found[i];
        if (!el || !el.isConnected) return null;
        const link = el.closest('a[href]');
        if (newTab && link) return link.href;
        const type = (el.type || '').toLowerCase();
        const field = el.isContentEditable || el.tagName === 'TEXTAREA' || el.tagName === 'SELECT'
          || (el.tagName === 'INPUT' && !keep.includes(type));
        el.focus({ preventScroll: true });
        if (!field) el.click();
        else if (el.tagName === 'SELECT') { try { el.showPicker(); } catch (e) {} }
        return null;
      };
      return rows;
    })()
    """
}

/// The labels and outlines over the page while you type; any click,
/// scroll, resize or tab switch puts it away.
@MainActor
final class HintsOverlay: NSView {
    private let targets: [Hints.Target]
    private var choose: ((Hints.Target) -> Void)?
    private var query = ""
    private let pill = NSTextField(labelWithString: "")
    private let pillBox = NSView()

    init(targets: [Hints.Target], choose: @escaping (Hints.Target) -> Void) {
        self.targets = targets
        self.choose = choose
        super.init(frame: .zero)
        pillBox.wantsLayer = true
        pillBox.layer?.cornerRadius = 6
        pillBox.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.75).cgColor
        pill.textColor = .white
        pill.font = .systemFont(ofSize: 12, weight: .medium)
        pill.lineBreakMode = .byTruncatingHead
        pill.translatesAutoresizingMaskIntoConstraints = false
        pillBox.translatesAutoresizingMaskIntoConstraints = false
        pillBox.addSubview(pill)
        addSubview(pillBox)
        NSLayoutConstraint.activate([
            pill.leadingAnchor.constraint(equalTo: pillBox.leadingAnchor, constant: 8),
            pill.trailingAnchor.constraint(equalTo: pillBox.trailingAnchor, constant: -8),
            pill.topAnchor.constraint(equalTo: pillBox.topAnchor, constant: 4),
            pill.bottomAnchor.constraint(equalTo: pillBox.bottomAnchor, constant: -4),
            pillBox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            pillBox.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            pillBox.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -16),
        ])
        update()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private var matches: [Hints.Target] {
        guard !query.isEmpty else { return targets }
        return targets.filter { $0.label.isEmpty ? $0.text.contains(query) : $0.label.hasPrefix(query) }
    }

    /// Return's pick among several: the text that is exactly what you typed,
    /// else the shortest (the most specific), else the first.
    private var best: Hints.Target? {
        guard !query.isEmpty else { return nil }
        let m = matches
        return m.first { $0.text == query } ?? m.filter { !$0.text.isEmpty }.min { $0.text.count < $1.text.count } ?? m.first
    }

    private func update() {
        let count = matches.count
        if query.isEmpty {
            pill.stringValue = "Type a link's or field's text, or its label"
        } else {
            pill.stringValue = count == 0 ? "\(query) — nothing matches" : "\(query) — \(count) match\(count == 1 ? "" : "es"), Return for the highlighted one"
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let accent = NSColor.controlAccentColor
        let best = self.best
        for t in matches {
            let rect = t.rect.insetBy(dx: -2, dy: -2)
            let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
            let strong = best?.index == t.index
            accent.withAlphaComponent(strong ? 0.3 : query.isEmpty ? 0 : 0.12).setFill()
            path.fill()
            accent.withAlphaComponent(strong ? 1 : 0.6).setStroke()
            path.lineWidth = strong ? 2 : 1
            path.stroke()
            if !t.label.isEmpty { drawLabel(t.label, at: rect.origin) }
        }
    }

    private func drawLabel(_ label: String, at point: NSPoint) {
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)
        let text = NSMutableAttributedString(string: label.uppercased(), attributes: [.font: font, .foregroundColor: NSColor.black])
        text.addAttribute(.foregroundColor, value: NSColor.black.withAlphaComponent(0.35),
                          range: NSRange(location: 0, length: min(query.count, label.count)))
        let size = text.size()
        let box = NSRect(x: point.x, y: point.y, width: size.width + 6, height: size.height + 2)
        NSColor(calibratedRed: 1, green: 0.85, blue: 0.3, alpha: 1).setFill()
        NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3).fill()
        NSColor.black.withAlphaComponent(0.4).setStroke()
        NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3).stroke()
        text.draw(at: NSPoint(x: box.minX + 3, y: box.minY + 1))
    }

    private func finish(_ target: Hints.Target?) {
        guard let choose else { return }
        self.choose = nil
        let window = self.window
        removeFromSuperview()
        if let target { choose(target) } else if let webView = superviewWebView { window?.makeFirstResponder(webView) }
    }

    private weak var superviewWebView: NSView?
    override func viewDidMoveToSuperview() {
        if superview != nil { superviewWebView = superview }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: return finish(nil)                       // Escape
        case 36, 76: return finish(best ?? (matches.count == 1 ? matches.first : nil))  // Return, Enter
        case 51:                                          // Delete
            if !query.isEmpty { query.removeLast() }
            return update()
        default: break
        }
        guard event.modifierFlags.intersection([.command, .control]).isEmpty,
              let chars = event.characters?.lowercased(), !chars.isEmpty,
              chars.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 })
        else { return super.keyDown(with: event) }
        if query.isEmpty && chars == " " { return }
        query += chars
        let m = matches
        if m.count == 1 {
            Self.swallowRest(of: m[0], typed: query)
            return finish(m[0])
        }
        update()
    }

    /// A target is picked as soon as it's the only match, often mid-word:
    /// the rest of the word, typed straight after, is eaten rather than
    /// landing in the page (or the field just focused).
    private static func swallowRest(of target: Hints.Target, typed: String) {
        let whole = target.text.isEmpty ? target.label : target.text
        var typed = typed
        var last = Date()
        var monitor: Any?
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let chars = event.characters?.lowercased() ?? ""
            if event.modifierFlags.intersection([.command, .control, .option]).isEmpty, !chars.isEmpty,
               Date().timeIntervalSince(last) < 0.6, whole.contains(typed + chars) {
                typed += chars
                last = Date()
                return nil
            }
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            return event
        }
        // Gone after a pause even if no other key comes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }

    override func cancelOperation(_ sender: Any?) { finish(nil) }
    override func mouseDown(with event: NSEvent) { finish(nil) }
    override func rightMouseDown(with event: NSEvent) { finish(nil) }
    override func scrollWheel(with event: NSEvent) {
        finish(nil)
        superviewWebView?.scrollWheel(with: event)
    }
    override func resignFirstResponder() -> Bool {
        if choose != nil { DispatchQueue.main.async { [weak self] in self?.finish(nil) } }
        return true
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil, choose != nil { DispatchQueue.main.async { [weak self] in self?.finish(nil) } }
    }
    override func setFrameSize(_ newSize: NSSize) {
        let resized = frame.size != .zero && frame.size != newSize
        super.setFrameSize(newSize)
        if resized { DispatchQueue.main.async { [weak self] in self?.finish(nil) } }
    }
}
