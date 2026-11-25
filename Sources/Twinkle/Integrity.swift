import AppKit
import Security

/// Twinkle refuses to run unless it's sandboxed and signed with a real
/// identity: without both, macOS doesn't keep its container (cookies, site
/// data, history) from other apps. Checked before anything is read or written.
enum Integrity {
    static func problem() -> String? {
        if ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] == nil {
            return "This copy of Twinkle isn't sandboxed."
        }
        var code: SecCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCheckValidity(code, [], nil) == errSecSuccess else {
            return "This copy of Twinkle has no valid signature."
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else {
            return "Twinkle can't read its own signature."
        }
        let flags = (dict[kSecCodeInfoFlags as String] as? UInt32) ?? 0
        if flags & SecCodeSignatureFlags.adhoc.rawValue != 0 || (dict[kSecCodeInfoCertificates as String] as? [Any] ?? []).isEmpty {
            return "This copy of Twinkle has an ad-hoc signature."
        }
        return nil
    }

    /// Shows why and exits, if there's a problem.
    @MainActor static func enforce() {
        guard let problem = problem() else { return }
        let alert = NSAlert()
        alert.messageText = "Twinkle won't start"
        alert.informativeText = problem + " Build it with ./build.sh, which signs it with your own identity (scripts/make-signing-identity.sh makes one) and sandboxes it, so other apps can't read your cookies."
        alert.runModal()
        exit(1)
    }
}
