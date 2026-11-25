import Foundation

/// Twinkle › Restart Twinkle. A sandboxed app can't pass arguments to the
/// copy it opens, so the old instance leaves its pid and profile in a file in
/// the container's temporary folder, and the new one waits there, before
/// touching any data, until the old one is gone.
enum Relaunch {
    private struct Handoff: Codable { var pid: Int32; var profile: String?; var written: Date }
    private static var file: URL { FileManager.default.temporaryDirectory.appendingPathComponent("relaunch.json") }

    static func prepare(profile: String?) {
        let handoff = Handoff(pid: ProcessInfo.processInfo.processIdentifier, profile: profile, written: Date())
        try? JSONEncoder().encode(handoff).write(to: file, options: .atomic)
    }

    /// If this launch is a restart: the profile the previous instance had
    /// (which may be nil, the usual Twinkle). Read once, first thing.
    static let handoff: String?? = takeOver()

    private static func takeOver() -> String?? {
        guard let data = try? Data(contentsOf: file),
              let handoff = try? JSONDecoder().decode(Handoff.self, from: data) else { return nil }
        try? FileManager.default.removeItem(at: file)
        guard Date().timeIntervalSince(handoff.written) < 15 else { return nil }
        for _ in 0..<100 where kill(handoff.pid, 0) == 0 { usleep(100_000) }
        return .some(handoff.profile)
    }
}
