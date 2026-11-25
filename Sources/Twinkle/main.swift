import AppKit

MainActor.assumeIsolated {
    let app = NSApplication.shared
    Integrity.enforce()
    _ = Relaunch.handoff
    if AppState.profileArgument() == nil { Migration.run() }
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
