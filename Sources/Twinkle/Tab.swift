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
    /// The tab tried to go to a site that always opens in another container.
    func tab(_ tab: Tab, open url: URL, inAssigned container: UUID)
}

/// One tab: a web view in one container. The web view is made on first
/// display, so tabs restored from the last session cost nothing until clicked.
@MainActor
final class Tab: NSObject, WKNavigationDelegate, WKUIDelegate {
    /// Saved with the session.
    let id: UUID
    let containerID: UUID?
    weak var host: TabHost?
    /// The page on screen is Twinkle's error page, not the address's.
    private var showingErrorPage = false
    /// The next commit is the error page being shown.
    private var errorPageLoading = false
    /// Whether the current page failed with a TLS or certificate error.
    private(set) var hasTLSError = false
    private(set) var tlsErrorMessage: String?
    /// The HTTP status of the page on screen; nil for error pages, files,
    /// and pages restored without a response yet.
    private(set) var statusCode: Int?
    /// The main-frame response of the navigation in progress.
    private var responseStatus: Int?
    /// Each back/forward entry's status, for pages that come back from
    /// WebKit's page cache without a new response.
    private var statusByItem: [WKBackForwardListItem: Int] = [:]

    private(set) var webView: WKWebView?
    /// Where the tab will go once its web view exists.
    private var pendingURL: URL?
    private var savedTitle: String
    private var observations: [NSKeyValueObservation] = []
    private var audioObservation: KeyObserver?
    /// Whether the page is making sound right now (WebKit's own media
    /// state, so it covers <video>, Web Audio and DRM video alike).
    private(set) var isPlayingAudio = false
    /// When the tab last came to the front, in the window's own count:
    /// the order ⌃Tab goes back through.
    var selectedAt = 0

    /// Opened by a page (window.open). Stays in its opener's container even
    /// on assigned sites, since sign-in pop-ups talk back to their opener.
    let isPopup: Bool
    /// The `sites` entry this tab may stay on in its current container even
    /// though the site is assigned elsewhere: set when you put it here
    /// yourself (Reopen in Container, Duplicate, a restored session).
    var exemptSite: String?
    /// When the tab was last in front; idle tabs are unloaded.
    private(set) var lastActive = Date()
    /// Back/forward list and scroll position kept while unloaded.
    private var unloadedState: Any?
    private(set) var icon: NSImage?
    /// Why the last unload check kept the tab, for debug.sh.
    private(set) var unloadCheck = ""

    init(url: URL?, title: String = "", container: UUID?, host: TabHost, id: UUID = UUID()) {
        self.id = id
        self.pendingURL = url
        self.savedTitle = title
        self.containerID = container
        self.host = host
        self.isPopup = false
        super.init()
        icon = url.flatMap { Favicons.shared.cached(for: $0, container: container) }
        observeAppearance()
    }

    /// The icon for the new appearance, from the cache or the page, after
    /// giving the page's scripts a moment to swap their icon links.
    private func observeAppearance() {
        NotificationCenter.default.addObserver(self, selector: #selector(appearanceChanged), name: Favicons.appearanceChanged, object: nil)
    }

    @objc private func appearanceChanged() {
        guard let url = webView?.url ?? pendingURL else { return }
        if let icon = Favicons.shared.cached(for: url, container: containerID) {
            self.icon = icon
            host?.tabDidChange(self)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.fetchIcon() }
        }
    }

    /// A tab for a page opened by another (window.open, target=_blank).
    /// WebKit requires the new view to use the configuration it hands over,
    /// which also keeps the pop-up in its opener's container.
    init(popupConfiguration: WKWebViewConfiguration, container: UUID?, host: TabHost) {
        self.id = UUID()
        self.pendingURL = nil
        self.savedTitle = ""
        self.containerID = container
        self.host = host
        self.isPopup = true
        super.init()
        webView = makeWebView(configuration: popupConfiguration)
        observeAppearance()
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
    var isUnloaded: Bool { webView == nil && !isBlank }
    var isHTTPS: Bool { url?.scheme?.lowercased() == "https" }
    var hasMixedContent: Bool {
        isHTTPS && !hasTLSError && !showingErrorPage
            && (webView.map { !$0.hasOnlySecureContent && !$0.isLoading } ?? false)
    }

    /// For the session and the closed-tabs list.
    var saved: SavedTab? {
        guard let url, let scheme = url.scheme?.lowercased(), ["http", "https", "file"].contains(scheme) else { return nil }
        return SavedTab(id: id, url: url.absoluteString, title: title, container: containerID)
    }

    // MARK: Loading

    /// The web view to show, made and loaded now if it wasn't yet.
    func viewForDisplay() -> WKWebView? {
        lastActive = Date()
        if webView == nil, let state = unloadedState {
            unloadedState = nil
            let webView = makeWebView(configuration: nil)
            self.webView = webView
            webView.interactionState = state
            if webView.url == nil { loadPending() } else { pendingURL = nil }
        } else if webView == nil, pendingURL != nil {
            webView = makeWebView(configuration: nil)
            loadPending()
        }
        return webView
    }

    func markActive() { lastActive = Date() }

    /// Whether the tab may be unloaded: not loading, not playing or
    /// recording anything, and no half-filled form on the page.
    func canUnload(_ done: @escaping (Bool) -> Void) {
        guard let webView, !isPopup, !webView.isLoading, webView.url != nil,
              webView.cameraCaptureState == .none, webView.microphoneCaptureState == .none else {
            unloadCheck = "busy"
            done(false)
            return
        }
        webView.requestMediaPlaybackState { state in
            webView.evaluateJavaScript(Self.keepLoadedScript, in: nil, in: .defaultClient) { result in
                let answer = (try? result.get()) as? [Any] ?? []
                let media = answer.first as? String ?? "?"
                let edited = answer.count > 1 ? answer[1] as? Bool ?? true : true
                // The page's own media is checked directly, so a muted
                // autoplaying background video doesn't pin the tab. Playback
                // with no playing element in the page is sound from a frame
                // or Web Audio, which is kept.
                let sound = media == "audible" || (state == .playing && media != "muted")
                self.unloadCheck = "playback \(state.rawValue), media \(media), edited \(edited)"
                done(!sound && !edited)
            }
        }
    }

    /// `[media, edited]`: media is "audible", "muted" (only muted media
    /// playing) or "none"; edited is whether a field has unsent text or a
    /// box was ticked. Runs in Twinkle's own script world, out of the page's
    /// sight.
    private static let keepLoadedScript = """
    (() => {
      // Media in open shadow roots and same-origin frames counts too.
      const media = (root, out = []) => {
        out.push(...root.querySelectorAll('video, audio'));
        for (const el of root.querySelectorAll('*')) {
          if (el.shadowRoot) media(el.shadowRoot, out);
          if (el.tagName === 'IFRAME') { try { if (el.contentDocument) media(el.contentDocument, out); } catch (e) {} }
        }
        return out;
      };
      const playing = media(document).filter(m => !m.paused && !m.ended);
      const state = playing.some(m => !m.muted && m.volume > 0) ? 'audible' : playing.length ? 'muted' : 'none';
      let edited = false;
      for (const e of document.querySelectorAll('input, textarea, select')) {
        if (['hidden', 'submit', 'button', 'reset', 'image'].includes(e.type)) continue;
        if (e.type === 'checkbox' || e.type === 'radio') edited ||= e.checked !== e.defaultChecked;
        else if (e.tagName === 'SELECT') edited ||= [...e.options].some(o => o.selected !== o.defaultSelected);
        else edited ||= e.value !== e.defaultValue;
      }
      const a = document.activeElement;
      edited ||= !!(a && a.isContentEditable);
      return [state, edited];
    })()
    """

    /// Frees the web view (and its process), keeping the address, title and
    /// back/forward list; it loads again when shown.
    func unload() {
        guard let webView else { return }
        unloadedState = webView.interactionState
        pendingURL = webView.url
        if let t = webView.title, !t.isEmpty { savedTitle = t }
        close()
        host?.tabDidChange(self)
    }

    func load(_ url: URL) {
        clearTLSError()
        unloadedState = nil
        if webView == nil {
            pendingURL = url
            webView = makeWebView(configuration: nil)
            loadPending()
        } else {
            webView?.load(URLRequest(url: url))
        }
    }

    private func clearTLSError() {
        hasTLSError = false
        tlsErrorMessage = nil
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
        statusByItem = [:]
        audioObservation = nil
        if isPlayingAudio {
            isPlayingAudio = false
            host?.tabDidChange(self)
        }
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
            let settings = AppState.shared.settings
            config.preferences.setMonospaceFont(settings.monospaceFont, size: settings.monospaceFontSize)
        }
        Blocker.shared.register(config.userContentController)
        JSONViewer.install(config.userContentController)
        PageStyle.install(config.userContentController)

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
            webView.observe(\.title) { [weak self] v, _ in
                changed(v)
                MainActor.assumeIsolated {
                    guard let self, !self.showingErrorPage, let url = v.url, let title = v.title else { return }
                    AppState.shared.recordTitle(title, for: url, container: self.containerID)
                }
            },
            webView.observe(\.url) { v, _ in changed(v) },
            webView.observe(\.isLoading) { v, _ in changed(v) },
            webView.observe(\.estimatedProgress) { v, _ in changed(v) },
            webView.observe(\.hasOnlySecureContent) { v, _ in changed(v) },
        ]
        // `_isPlayingAudio` is WebKit SPI (Safari's speaker icon), observable
        // with KVO; there's no public equivalent that reports changes.
        audioObservation = KeyObserver(webView, "_isPlayingAudio") { [weak self] value in
            guard let self else { return }
            let playing = (value as? Bool) ?? false
            guard playing != self.isPlayingAudio else { return }
            self.isPlayingAudio = playing
            self.host?.tabDidChange(self)
        }
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
            if let assigned = assignedElsewhere(url, action: action) {
                host?.tab(self, open: url, inAssigned: assigned)
                decisionHandler(.cancel)
                return
            }
            if !errorPageLoading {
                clearTLSError()
            }
            Blocker.shared.tune(webView.configuration.userContentController, host: url.host())
        }
        decisionHandler(.allow)
    }

    /// The container `url` should open in instead of this tab's, if any.
    /// Only plain page loads move: not form posts, reloads or back/forward,
    /// and not pop-ups or sites you put in this container yourself.
    private func assignedElsewhere(_ url: URL, action: WKNavigationAction) -> UUID? {
        guard !isPopup, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              (action.request.httpMethod ?? "GET").uppercased() == "GET",
              ![.backForward, .reload, .formResubmitted, .formSubmitted].contains(action.navigationType),
              let assignment = AppState.shared.assignment(forHost: url.host()),
              assignment.container.id != containerID,
              assignment.site != exemptSite else { return nil }
        return assignment.container.id
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if response.isForMainFrame {
            responseStatus = (response.response as? HTTPURLResponse)?.statusCode
        }
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

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        fetchIcon()
    }

    private func fetchIcon() {
        guard let webView, !webView.isLoading, let page = webView.url,
              ["http", "https"].contains(page.scheme ?? "") else { return }
        webView.evaluateJavaScript(Favicons.linksScript) { [weak self] value, _ in
            let links = (value as? [[String]]) ?? []
            Favicons.shared.load(for: page, links: links, container: self?.containerID) { image in
                guard let self, let image, self.webView?.url?.host() == page.host() else { return }
                self.icon = image
                self.host?.tabDidChange(self)
            }
        }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        // The error page commits at the failed address: not a visit.
        showingErrorPage = errorPageLoading
        errorPageLoading = false
        if showingErrorPage {
            statusCode = nil
        } else if let item = webView.backForwardList.currentItem {
            if let status = responseStatus { statusByItem[item] = status }
            statusCode = statusByItem[item]
        } else {
            statusCode = responseStatus
        }
        responseStatus = nil
        // The title saved for an unloaded or restored tab was the old page's:
        // a page without a <title> shows its host, not that.
        savedTitle = ""
        if !showingErrorPage {
            clearTLSError()
            if let url = webView.url {
                AppState.shared.recordVisit(url, title: webView.title ?? "", container: containerID)
            }
        }
        // Each site's remembered zoom, applied as its page arrives.
        let zoom = AppState.shared.zoom(forHost: webView.url?.host())
        if abs(webView.pageZoom - zoom) > 0.001 { webView.pageZoom = zoom }
        // A new site: the old site's icon no longer applies.
        if let icon = webView.url.flatMap({ Favicons.shared.cached(for: $0, container: containerID) }) {
            self.icon = icon
        } else if webView.url?.host() != nil {
            icon = nil
        }
        host?.tabDidChange(self)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        responseStatus = nil
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

    private static let tlsErrorCodes: Set<Int> = [
        NSURLErrorSecureConnectionFailed,
        NSURLErrorServerCertificateHasBadDate,
        NSURLErrorServerCertificateUntrusted,
        NSURLErrorServerCertificateHasUnknownRoot,
        NSURLErrorServerCertificateNotYetValid,
        NSURLErrorClientCertificateRejected,
        NSURLErrorClientCertificateRequired,
    ]

    private static func isTLSError(_ error: NSError) -> Bool {
        var current: NSError? = error
        var depth = 0
        while let e = current, depth < 5 {
            if e.domain == NSURLErrorDomain && tlsErrorCodes.contains(e.code) {
                return true
            }
            if e.userInfo[NSURLErrorFailingURLPeerTrustErrorKey] != nil {
                return true
            }
            current = e.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return false
    }

    private func showError(_ error: Error, in webView: WKWebView) {
        let e = error as NSError
        // Cancelled, interrupted by a download, or handled elsewhere.
        if e.domain == NSURLErrorDomain && e.code == NSURLErrorCancelled { return }
        if e.domain == "WebKitErrorDomain" && [102, 204].contains(e.code) { return }
        if Self.isTLSError(e) {
            hasTLSError = true
            tlsErrorMessage = e.localizedDescription
            host?.tabDidChange(self)
        }
        let failing = (e.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? webView.url
        errorPageLoading = true
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

extension WKPreferences {
    /// The font for `monospace`, which plain text and the JSON viewer use.
    /// WebKit only has this as a private setting (Safari's own preferences
    /// use it); if it's ever gone, pages keep WebKit's default.
    func setMonospaceFont(_ family: String, size: Double) {
        let familySetter = NSSelectorFromString("_setFixedPitchFontFamily:")
        if responds(to: familySetter) { perform(familySetter, with: family) }
        let sizeSetter = NSSelectorFromString("_setDefaultFixedPitchFontSize:")
        guard let method = class_getInstanceMethod(WKPreferences.self, sizeSetter),
              let encoding = method_getTypeEncoding(method) else { return }
        // The argument's type, from an encoding like "v24@0:8d16".
        let argument = String(cString: encoding).filter { !$0.isNumber }.dropFirst(3).first
        let imp = method_getImplementation(method)
        switch argument {
        case "d":
            typealias Setter = @convention(c) (AnyObject, Selector, Double) -> Void
            unsafeBitCast(imp, to: Setter.self)(self, sizeSetter, size)
        case "Q", "q", "L", "l", "I", "i":
            typealias Setter = @convention(c) (AnyObject, Selector, Int) -> Void
            unsafeBitCast(imp, to: Setter.self)(self, sizeSetter, Int(size))
        default:
            return
        }
    }
}

/// KVO on a key that has no Swift key path (WebKit SPI); stops observing
/// when released.
final class KeyObserver: NSObject {
    private weak var object: NSObject?
    private let key: String
    private let changed: @MainActor (Any?) -> Void

    init?(_ object: NSObject, _ key: String, changed: @escaping @MainActor (Any?) -> Void) {
        guard object.responds(to: NSSelectorFromString(key)) else { return nil }
        self.object = object
        self.key = key
        self.changed = changed
        super.init()
        object.addObserver(self, forKeyPath: key, options: [.initial, .new], context: nil)
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                                           change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        let value = change?[.newKey] as? Bool
        MainActor.assumeIsolated { changed(value) }
    }

    deinit {
        object?.removeObserver(self, forKeyPath: key)
    }
}
