import Foundation

/// The user's real home folder. In the App Sandbox, NSHomeDirectory() and
/// "~" are the app's container, but settings like "~/Downloads" and Safari's
/// files mean the real one.
public enum Home {
    public static let url: URL = {
        if let dir = getpwuid(getuid())?.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }()

    /// "~" and "~/…" against the real home; other paths as they are.
    public static func expand(_ path: String) -> String {
        if path == "~" { return url.path }
        if path.hasPrefix("~/") { return url.appendingPathComponent(String(path.dropFirst(2))).path }
        return path
    }
}
