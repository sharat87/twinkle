import AppKit

/// Alfred as the address bar: ⌘L runs the Twinkle Address workflow's
/// external trigger with the current address, and the workflow sends the
/// choice back as a twinkle:// link. See alfred/ and the README.
@MainActor
enum Alfred {
    static let app = "com.runningwithcrayons.Alfred"
    static let workflow = "dev.twinkle.address"

    /// false if Alfred isn't installed or wouldn't take the request; the
    /// first time, macOS asks whether Twinkle may control Alfred.
    static func showAddress(_ text: String) -> Bool {
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: app) != nil else {
            Status.show("Alfred isn't installed; using Twinkle's address field.")
            return false
        }
        let quoted = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        tell application id "\(app)" to run trigger "address" in workflow "\(workflow)" with argument "\(quoted)"
        """
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            let message = error[NSAppleScript.errorMessage] as? String ?? "\(error)"
            Status.show("Alfred: \(message)", sticky: true)
            return false
        }
        return true
    }
}
