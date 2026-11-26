import AppKit

MainActor.assumeIsolated {
    let app = NSApplication.shared
    // Typing ' or " in a page's text field shouldn't turn it into a curly
    // quote. WebKit falls back to the system's "Use smart quotes and dashes"
    // setting only when this is unset; spelling, text replacements and
    // suggestions keep following the system.
    UserDefaults.standard.register(defaults: ["WebAutomaticQuoteSubstitutionEnabled": false])
    Integrity.enforce()
    _ = Relaunch.handoff
    if AppState.profileArgument() == nil { Migration.run() }
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
