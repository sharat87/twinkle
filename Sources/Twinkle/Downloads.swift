import AppKit
import WebKit

/// Downloads go through WebKit, so they carry the tab's cookies and
/// container: a file behind a sign-in downloads like any other.
@MainActor
final class Downloads: NSObject, WKDownloadDelegate {
    static let shared = Downloads()

    private var destinations: [ObjectIdentifier: URL] = [:]
    private var observations: [ObjectIdentifier: NSKeyValueObservation] = [:]
    private var lastPercent: [ObjectIdentifier: Int] = [:]

    func track(_ download: WKDownload) {
        download.delegate = self
        let id = ObjectIdentifier(download)
        observations[id] = download.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            let fraction = progress.fractionCompleted
            DispatchQueue.main.async { self?.progressed(id, fraction) }
        }
    }

    private func progressed(_ id: ObjectIdentifier, _ fraction: Double) {
        guard let file = destinations[id] else { return }
        let percent = Int(fraction * 100)
        guard percent != lastPercent[id], percent < 100 else { return }
        lastPercent[id] = percent
        Status.show("Downloading \(file.lastPathComponent)… \(percent)%", file: file, sticky: true)
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let directory = AppState.shared.downloadsDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = Self.unique(directory.appendingPathComponent(Self.clean(suggestedFilename)))
        destinations[ObjectIdentifier(download)] = file
        Status.show("Downloading \(file.lastPathComponent)…", file: file, sticky: true)
        completionHandler(file)
    }

    func downloadDidFinish(_ download: WKDownload) {
        let id = ObjectIdentifier(download)
        if let file = destinations[id] {
            Status.show("Downloaded \(file.lastPathComponent)", file: file)
            NSApp.requestUserAttention(.informationalRequest)
            // Bounces the Downloads stack in the Dock, as Safari does.
            DistributedNotificationCenter.default().post(
                name: .init("com.apple.DownloadFileFinished"), object: file.path)
        }
        forget(id)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let id = ObjectIdentifier(download)
        let name = destinations[id]?.lastPathComponent ?? "download"
        Status.show("\(name) failed: \(error.localizedDescription)", sticky: true)
        if let file = destinations[id] { try? FileManager.default.removeItem(at: file) }
        forget(id)
    }

    private func forget(_ id: ObjectIdentifier) {
        destinations[id] = nil
        observations[id] = nil
        lastPercent[id] = nil
    }

    static func clean(_ name: String) -> String {
        let cleaned = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: " .").union(.whitespacesAndNewlines))
        return cleaned.isEmpty ? "download" : cleaned
    }

    /// `file.zip`, then `file 2.zip`, `file 3.zip`…
    static func unique(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let directory = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        var n = 2
        while true {
            let name = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            let candidate = directory.appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }
}
