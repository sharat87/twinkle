import AppKit
import TwinkleCore
import WebKit

/// What a tab needs from its window.
@MainActor
protocol TabHost: AnyObject {
    var window: NSWindow? { get }
    func tabDidChange(_ tab: Tab)
    func tab(_ tab: Tab, open url: URL, inBackground: Bool)
    func tab(_ tab: Tab, popupWith configuration: WKWebViewConfiguration) -> WKWebView?
    func tabWantsClose(_ tab: Tab)
    func reveal(_ tab: Tab)
}

/// One tab: a web view in one container. The web view is made on first
/// display, so tabs restored from the last session cost nothing until clicked.
@MainActor
final class Tab: NSObject, WKNavigationDelegate, WKUIDelegate {
    let containerID: UUID?
    weak var host: TabHost?

    private(set) var webView: WKWebView?
    /// Where the tab will go once its web view exists.
    private var pendingURL: URL?
    private var savedTitle: String
    private var observations: [NSKeyValueObservation] = []

    init(url: URL?, title: String = "", container: UUID?, host: TabHost) {
        self.pendingURL = url
        self.savedTitle = title
        self.containerID = container
        self.host = host
        super.init()
    }

    /// A tab for a page opened by another (window.open, target=_blank).
    /// WebKit requires the new view to use the configuration it hands over,
    /// which also keeps the pop-up in its opener's container.
    init(popupConfiguration: WKWebViewConfiguration, container: UUID?, host: TabHost) {
        self.pendingURL = nil
        self.savedTitle = ""
        self.containerID = container
        self.host = host
        super.init()
        webView = makeWebView(configuration: popupConfiguration)
    }

    // MARK: State

    var url: URL? { webView?.url ?? pendingURL }

    var title: String {
        if let t = webView?.title, !t.isEmpty { return t }
        if !savedTitle.isEmpty { return savedTitle }
        return url?.host(percentEncoded: false) ?? "New Tab"
    }

    /// The page's own title, without fallbacks.
    var pageTitle: String { webView?.title ?? savedTitle }

    var isLoading: Bool { webView?.isLoading ?? false }
    var progress: Double { webView?.estimatedProgress ?? 0 }
    var isBlank: Bool { url == nil }

    var saved: SavedTab? {
        guard let url, let scheme = url.scheme?.lowercased(), ["http", "https", "file"].contains(scheme) else { return nil }
        return SavedTab(url: url.absoluteString, title: title, container: containerID)
    }

    // MARK: Loading

    /// The web view to show, made and loaded now if it wasn't yet.
    func viewForDisplay() -> WKWebView? {
        if webView == nil, pendingURL != nil {
            webView = makeWebView(configuration: nil)
            loadPending()
        }
        return webView
    }

    func load(_ url: URL) {
        if webView == nil {
            pendingURL = url
            webView = makeWebView(configuration: nil)
            loadPending()
        } else {
            webView?.load(URLRequest(url: url))
        }
    }

    private func loadPending() {
        guard let url = pendingURL else { return }
        Blocker.shared.whenReady { [weak self] in
            guard let self, let webView = self.webView else { return }
            self.pendingURL = nil
            if url.isFileURL {
                webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            } else {
                webView.load(URLRequest(url: url))
            }
        }
    }

    func close() {
        observations = []
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView?.removeFromSuperview()
        webView = nil
    }

    private func makeWebView(configuration given: WKWebViewConfiguration?) -> WKWebView {
        let config: WKWebViewConfiguration
        if let given {
            config = given
        } else {
            config = WKWebViewConfiguration()
            config.websiteDataStore = AppState.shared.dataStore(for: containerID)
            config.applicationNameForUserAgent = UserAgent.suffix
            config.preferences.isElementFullscreenEnabled = true
            config.preferences.javaScriptCanOpenWindowsAutomatically = false
        }
        Blocker.shared.register(config.userContentController)

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        // Right-click › Inspect Element opens Safari's Web Inspector.
        webView.isInspectable = true

        let changed: (WKWebView) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.host?.tabDidChange(self)
            }
        }
        observations = [
            webView.observe(\.title) { v, _ in changed(v) },
            webView.observe(\.url) { v, _ in changed(v) },
            webView.observe(\.isLoading) { v, _ in changed(v) },
            webView.observe(\.estimatedProgress) { v, _ in changed(v) },
        ]
        return webView
    }

    // MARK: Navigation

    private static let webSchemes: Set<String> = ["http", "https", "about", "data", "blob", "file", "javascript"]

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if action.shouldPerformDownload {
            decisionHandler(.download)
            return
        }
        guard let url = action.request.url else {
            decisionHandler(.allow)
            return
        }

        // mailto:, zoommtg:, etc. go to the app that handles them.
        let scheme = url.scheme?.lowercased() ?? ""
        if !Self.webSchemes.contains(scheme) {
            if action.navigationType == .linkActivated || action.targetFrame?.isMainFrame != false {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)
            return
        }

        // ⌘-click and middle-click open a tab in the same container.
        let middleClick = action.buttonNumber == 2 || action.buttonNumber == 4
        if action.navigationType == .linkActivated, action.modifierFlags.contains(.command) || middleClick {
            host?.tab(self, open: url, inBackground: !action.modifierFlags.contains(.shift))
            decisionHandler(.cancel)
            return
        }

        if action.targetFrame?.isMainFrame == true {
            Blocker.shared.tune(webView.configuration.userContentController, host: url.host())
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if !response.canShowMIMEType {
            decisionHandler(.download)
            return
        }
        if response.isForMainFrame,
           let http = response.response as? HTTPURLResponse,
           let disposition = http.value(forHTTPHeaderField: "Content-Disposition"),
           disposition.lowercased().hasPrefix("attachment") {
            decisionHandler(.download)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        Downloads.shared.track(download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        Downloads.shared.track(download)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showError(error, in: webView)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showError(error, in: webView)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }

    private func showError(_ error: Error, in webView: WKWebView) {
        let e = error as NSError
        // Cancelled, interrupted by a download, or handled elsewhere.
        if e.domain == NSURLErrorDomain && e.code == NSURLErrorCancelled { return }
        if e.domain == "WebKitErrorDomain" && [102, 204].contains(e.code) { return }
        let failing = (e.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? webView.url
        webView.loadHTMLString(ErrorPage.html(error: e, url: failing), baseURL: failing)
    }

    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let method = challenge.protectionSpace.authenticationMethod
        guard [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest, NSURLAuthenticationMethodNTLM].contains(method) else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        host?.reveal(self)
        Dialogs.credentials(host: challenge.protectionSpace.host, realm: challenge.protectionSpace.realm, in: host?.window) { creds in
            if let creds {
                completionHandler(.useCredential, URLCredential(user: creds.user, password: creds.password, persistence: .forSession))
            } else {
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        }
    }

    // MARK: UI

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        host?.tab(self, popupWith: configuration)
    }

    func webViewDidClose(_ webView: WKWebView) {
        host?.tabWantsClose(self)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        host?.reveal(self)
        Dialogs.alert(message, from: frame.securityOrigin.host, in: host?.window, done: completionHandler)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        host?.reveal(self)
        Dialogs.confirm(message, from: frame.securityOrigin.host, in: host?.window, done: completionHandler)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        host?.reveal(self)
        Dialogs.prompt(prompt, defaultText: defaultText, from: frame.securityOrigin.host, in: host?.window, done: completionHandler)
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        if let window = host?.window {
            panel.beginSheetModal(for: window) { completionHandler($0 == .OK ? panel.urls : nil) }
        } else {
            completionHandler(panel.runModal() == .OK ? panel.urls : nil)
        }
    }

    /// Camera, microphone and screen capture: always no. Location and
    /// notifications don't exist here either — the app has no location
    /// entitlement and WKWebView offers no web notifications by default.
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(.deny)
    }
}

enum UserAgent {
    /// WKWebView's default user agent lacks the `Version/… Safari/…` part,
    /// and some sites treat it as an unknown browser without it. Taken from
    /// the installed Safari so it stays current.
    static let suffix: String = {
        let plist = URL(fileURLWithPath: "/Applications/Safari.app/Contents/Info.plist")
        let info = NSDictionary(contentsOf: plist)
        let version = info?["CFBundleShortVersionString"] as? String ?? "18.0"
        return "Version/\(version) Safari/605.1.15"
    }()
}

enum ErrorPage {
    static func html(error: NSError, url: URL?) -> String {
        let blocked = error.domain == "WebKitErrorDomain" && error.code == 104
        let heading = blocked ? "Blocked by the ad blocker" : "Can't open this page"
        let detail = blocked
            ? "This address is on one of your filter lists. Tools › Turn Off Ad Blocking for This Site lets it through."
            : error.localizedDescription
        return """
        <!doctype html><meta charset="utf-8"><title>\(escape(heading))</title>
        <style>
        :root { color-scheme: light dark; }
        body { font: 14px -apple-system, system-ui; margin: 0; height: 100vh; display: grid; place-items: center; }
        main { max-width: 34em; padding: 2em; }
        h1 { font-size: 20px; font-weight: 600; margin: 0 0 .5em; }
        p { color: GrayText; line-height: 1.5; margin: .3em 0; overflow-wrap: anywhere; }
        </style>
        <main><h1>\(escape(heading))</h1><p>\(escape(detail))</p><p>\(escape(url?.absoluteString ?? ""))</p></main>
        """
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
