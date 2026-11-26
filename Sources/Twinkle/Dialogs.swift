import AppKit

/// The page's alert/confirm/prompt and HTTP sign-in, over its own tab only,
/// and the sheet for naming things.
@MainActor
enum Dialogs {
    static func alert(_ message: String, from host: String?, done: @escaping () -> Void) -> PageDialog {
        PageDialog(title: host.map { "\($0) says" } ?? "The page says", message: message, cancel: nil) { _ in done() }
    }

    static func confirm(_ message: String, from host: String?, done: @escaping (Bool) -> Void) -> PageDialog {
        PageDialog(title: host.map { "\($0) says" } ?? "The page says", message: message, done: done)
    }

    static func prompt(_ message: String, defaultText: String?, from host: String?,
                       done: @escaping (String?) -> Void) -> PageDialog {
        let field = NSTextField(string: defaultText ?? "")
        return PageDialog(title: host.map { "\($0) asks" } ?? "The page asks", message: message,
                          fields: [field]) { done($0 ? field.stringValue : nil) }
    }

    /// HTTP Basic/Digest sign-in. Plain fields, so password managers'
    /// auto-type works on them.
    static func credentials(host: String, realm: String?,
                            done: @escaping ((user: String, password: String)?) -> Void) -> PageDialog {
        let user = NSTextField()
        user.placeholderString = "User name"
        let password = NSSecureTextField()
        password.placeholderString = "Password"
        return PageDialog(title: "Sign in to \(host)", message: realm?.isEmpty == false ? realm : nil,
                          fields: [user, password], ok: "Sign In") { ok in
            done(ok ? (user.stringValue, password.stringValue) : nil)
        }
    }

    static func askForName(title: String, placeholder: String, in window: NSWindow?, done: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        let field = NSTextField()
        field.placeholderString = placeholder
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        present(alert, in: window) { response in
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            done(response == .alertFirstButtonReturn && !name.isEmpty ? name : nil)
        }
    }

    private static func present(_ alert: NSAlert, in window: NSWindow?, done: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window {
            alert.beginSheetModal(for: window, completionHandler: done)
        } else {
            done(alert.runModal())
        }
    }
}

/// A page's alert, confirm, prompt or sign-in, laid over that tab's page:
/// the page waits for an answer, but the other tabs and the rest of the
/// window carry on, and it's still there when you come back to the tab.
@MainActor
final class PageDialog: NSView, NSTextFieldDelegate {
    private var done: ((Bool) -> Void)?
    /// Called once it's answered, before the page hears the answer.
    var onFinish: (() -> Void)?
    /// What takes the keyboard while it's up: the first field, else itself.
    let focus: NSView?
    let title: String
    /// Asking to open an app, so a page can't stack up more of them.
    var isAppPrompt = false

    init(title: String, message: String?, fields: [NSTextField] = [], ok: String = "OK", cancel: String? = "Cancel",
         done: @escaping (Bool) -> Void) {
        self.done = done
        self.title = title
        self.focus = fields.first
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.15).cgColor

        let panel = NSVisualEffectView()
        panel.material = .popover
        panel.blendingMode = .withinWindow
        panel.state = .active
        panel.wantsLayer = true
        panel.layer?.cornerRadius = 12
        panel.layer?.borderWidth = 1
        panel.layer?.borderColor = NSColor.separatorColor.cgColor

        let heading = NSTextField(labelWithString: title)
        heading.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        heading.lineBreakMode = .byTruncatingMiddle
        var rows: [NSView] = [heading]
        if let message, !message.isEmpty {
            let text = NSTextField(wrappingLabelWithString: message)
            text.isSelectable = true
            text.maximumNumberOfLines = 20
            text.lineBreakMode = .byTruncatingTail
            text.cell?.truncatesLastVisibleLine = true
            rows.append(text)
        }
        for (i, field) in fields.enumerated() {
            // Return answers through the delegate, not the field's action,
            // which also fires when the field loses focus to another tab.
            field.delegate = self
            if i + 1 < fields.count { field.nextKeyView = fields[i + 1] }
            rows.append(field)
        }

        let okButton = NSButton(title: ok, target: self, action: #selector(okPressed))
        okButton.keyEquivalent = "\r"
        var buttons: [NSView] = [NSView()]
        if let cancel {
            let cancelButton = NSButton(title: cancel, target: self, action: #selector(cancelPressed))
            cancelButton.keyEquivalent = "\u{1b}"
            buttons.append(cancelButton)
        }
        buttons.append(okButton)
        let buttonRow = NSStackView(views: buttons)
        buttonRow.orientation = .horizontal
        rows.append(buttonRow)

        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(16, after: rows[rows.count - 2])
        for row in rows.dropFirst() where row !== buttonRow {
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        heading.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor).isActive = true

        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(stack)
        addSubview(panel)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: panel.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -16),
            stack.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -20),
            panel.widthAnchor.constraint(equalToConstant: 380),
            panel.centerXAnchor.constraint(equalTo: centerXAnchor),
            panel.topAnchor.constraint(equalTo: topAnchor, constant: 48),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Answers it as Cancel (OK for a plain alert): for a tab that closes
    /// or unloads with it still up.
    func dismiss() { finish(false) }

    @objc private func okPressed() { finish(true) }
    @objc private func cancelPressed() { finish(false) }

    private func finish(_ ok: Bool) {
        guard let done else { return }
        self.done = nil
        onFinish?()
        done(ok)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)): finish(true)
        case #selector(NSResponder.cancelOperation(_:)): finish(false)
        default: return false
        }
        return true
    }

    // It covers the page: clicks, scrolls and keys stop here.
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(focus ?? self) }
    override func rightMouseDown(with event: NSEvent) {}
    override func otherMouseDown(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}
    override func cancelOperation(_ sender: Any?) { finish(false) }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: finish(true)  // Return, Enter
        case 53: finish(false)     // Escape
        default: super.keyDown(with: event)
        }
    }
}
