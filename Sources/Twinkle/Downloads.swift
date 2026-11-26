import AppKit
import WebKit

/// Downloads go through WebKit, so they carry the tab's cookies and
/// container: a file behind a sign-in downloads like any other.
@MainActor
final class Downloads: NSObject, WKDownloadDelegate {
    static let shared = Downloads()

    private var downloads: [ObjectIdentifier: WKDownload] = [:]
    private var destinations: [ObjectIdentifier: URL] = [:]
    private var expectedBytes: [ObjectIdentifier: Int64] = [:]
    private var observations: [ObjectIdentifier: NSKeyValueObservation] = [:]
    private var lastPercent: [ObjectIdentifier: Int] = [:]

    func track(_ download: WKDownload) {
        download.delegate = self
        let id = ObjectIdentifier(download)
        downloads[id] = download
        observations[id] = download.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            let fraction = progress.fractionCompleted
            let completed = progress.completedUnitCount
            let total = progress.totalUnitCount
            DispatchQueue.main.async { self?.progressed(id, fraction, completed: completed, total: total) }
        }
    }

    private func progressed(_ id: ObjectIdentifier, _ fraction: Double, completed: Int64, total: Int64) {
        guard let file = destinations[id] else { return }
        let percent = Int(fraction * 100)
        guard percent != lastPercent[id], percent < 100 else { return }
        lastPercent[id] = percent
        let knownTotal = total > 0 ? total : expectedBytes[id] ?? 0
        showProgress(id: id, file: file, completed: completed, total: knownTotal, percent: percent)
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let directory = AppState.shared.downloadsDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = Self.unique(directory.appendingPathComponent(Self.clean(suggestedFilename)))
        let id = ObjectIdentifier(download)
        destinations[id] = file
        if response.expectedContentLength > 0 { expectedBytes[id] = response.expectedContentLength }
        showProgress(id: id, file: file, completed: 0, total: expectedBytes[id] ?? 0, percent: 0)
        completionHandler(file)
    }

    func downloadDidFinish(_ download: WKDownload) {
        let id = ObjectIdentifier(download)
        if let file = destinations[id] {
            Self.recordWhereFrom(file, source: download.originalRequest?.url, page: download.webView?.url)
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
        guard let file = destinations[id] else { return }
        let name = file.lastPathComponent
        Status.show("\(name) failed: \(error.localizedDescription)", sticky: true)
        try? FileManager.default.removeItem(at: file)
        forget(id)
    }

    /// A file the page already has, like the PDF on screen.
    func save(_ data: Data, suggestedFilename: String, source: URL?, page: URL?) {
        let directory = AppState.shared.downloadsDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = Self.unique(directory.appendingPathComponent(Self.clean(suggestedFilename)))
        do {
            try data.write(to: file, options: .withoutOverwriting)
        } catch {
            Status.show("Couldn't save \(file.lastPathComponent): \(error.localizedDescription)", sticky: true)
            return
        }
        Self.recordWhereFrom(file, source: source, page: page)
        Status.show("Downloaded \(file.lastPathComponent)", file: file)
        DistributedNotificationCenter.default().post(
            name: .init("com.apple.DownloadFileFinished"), object: file.path)
    }

    private func forget(_ id: ObjectIdentifier) {
        downloads[id] = nil
        destinations[id] = nil
        expectedBytes[id] = nil
        observations[id] = nil
        lastPercent[id] = nil
    }

    private func showProgress(id: ObjectIdentifier, file: URL, completed: Int64, total: Int64, percent: Int) {
        let bytes: String
        if total > 0 {
            let received = ByteCountFormatter.string(fromByteCount: max(0, completed), countStyle: .file)
            let size = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
            bytes = "\(received) of \(size) · \(percent)%"
        } else if completed > 0 {
            bytes = "\(ByteCountFormatter.string(fromByteCount: completed, countStyle: .file)) · \(percent)%"
        } else {
            bytes = "0 bytes"
        }
        Status.show("\(file.lastPathComponent)… \(bytes)", file: file, symbol: "arrow.down.circle",
                    cancel: { [weak self] in self?.cancel(id) }, sticky: true)
    }

    private func cancel(_ id: ObjectIdentifier) {
        guard let download = downloads[id], let file = destinations[id] else { return }
        Status.show("Canceled \(file.lastPathComponent)", file: file)
        download.cancel { _ in
            try? FileManager.default.removeItem(at: file)
        }
        forget(id)
    }

    /// Finder's Get Info › Where from, as Safari sets it: the file's address,
    /// then the page it was downloaded from. data: addresses are left out
    /// (they're the file itself).
    static func recordWhereFrom(_ file: URL, source: URL?, page: URL?) {
        let froms = [source, page].compactMap { $0 }
            .filter { $0.scheme?.lowercased() != "data" }
            .map(\.absoluteString)
        guard !froms.isEmpty,
              let plist = try? PropertyListSerialization.data(fromPropertyList: froms, format: .binary, options: 0)
        else { return }
        _ = plist.withUnsafeBytes { bytes in
            setxattr(file.path, "com.apple.metadata:kMDItemWhereFroms", bytes.baseAddress, bytes.count, 0, 0)
        }
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
