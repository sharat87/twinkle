import AppKit

/// Sheets for the page's alert/confirm/prompt, HTTP sign-in and naming things.
@MainActor
enum Dialogs {
    static func alert(_ message: String, from host: String?, in window: NSWindow?, done: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = host.map { "\($0) says" } ?? "The page says"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        present(alert, in: window) { _ in done() }
    }

    static func confirm(_ message: String, from host: String?, in window: NSWindow?, done: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = host.map { "\($0) says" } ?? "The page says"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        present(alert, in: window) { done($0 == .alertFirstButtonReturn) }
    }

    static func prompt(_ message: String, defaultText: String?, from host: String?, in window: NSWindow?,
                       done: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = host.map { "\($0) asks" } ?? "The page asks"
        alert.informativeText = message
        let field = NSTextField(string: defaultText ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        present(alert, in: window) { done($0 == .alertFirstButtonReturn ? field.stringValue : nil) }
    }

    /// HTTP Basic/Digest sign-in. Plain fields, so password managers'
    /// auto-type works on them.
    static func credentials(host: String, realm: String?, in window: NSWindow?,
                            done: @escaping ((user: String, password: String)?) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Sign in to \(host)"
        if let realm, !realm.isEmpty { alert.informativeText = realm }
        let user = NSTextField()
        user.placeholderString = "User name"
        let password = NSSecureTextField()
        password.placeholderString = "Password"
        let stack = NSStackView(views: [user, password])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 260, height: 56)
        for field in [user, password] {
            field.widthAnchor.constraint(equalToConstant: 260).isActive = true
        }
        alert.accessoryView = stack
        alert.addButton(withTitle: "Sign In")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = user
        present(alert, in: window) { response in
            done(response == .alertFirstButtonReturn ? (user.stringValue, password.stringValue) : nil)
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
