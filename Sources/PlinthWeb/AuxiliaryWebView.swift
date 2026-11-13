import AppKit
import Observation
import WebKit
import PlinthModel

/// What an auxiliary view (peek card, mini window) is showing. Updated from KVO on the view.
@MainActor
@Observable
public final class AuxiliaryPageState {
    public internal(set) var title: String?
    public internal(set) var url: URL?
    public internal(set) var isLoading = false
    /// 0...1
    public internal(set) var progress: Double = 0
    public internal(set) var canGoBack = false
    public internal(set) var canGoForward = false
    /// The page called `window.close()`.
    public internal(set) var closeRequested = false

    public init() {}
}

/// Navigation and UI delegate for a view that is not a pooled page: navigates freely, loads
/// target=_blank in place, and hands downloads and panels to the pool.
@MainActor
final class AuxiliaryController: NSObject, WKNavigationDelegate, WKUIDelegate {
    weak var pool: WebViewPool?
    let state = AuxiliaryPageState()
    var observations: [NSKeyValueObservation] = []
    private var reloadedAfterCrash = false
    /// Called when the page asks to close itself (`window.close()`).
    var onClose: (() -> Void)?

    init(pool: WebViewPool) {
        self.pool = pool
    }

    func attach(to webView: WKWebView) {
        webView.navigationDelegate = self
        webView.uiDelegate = self
        observations = [
            webView.observe(\.title) { [weak self] view, _ in MainActor.assumeIsolated { self?.refresh(view) } },
            webView.observe(\.url) { [weak self] view, _ in MainActor.assumeIsolated { self?.refresh(view) } },
            webView.observe(\.isLoading) { [weak self] view, _ in MainActor.assumeIsolated { self?.refresh(view) } },
            webView.observe(\.estimatedProgress) { [weak self] view, _ in MainActor.assumeIsolated { self?.refresh(view) } },
            webView.observe(\.canGoBack) { [weak self] view, _ in MainActor.assumeIsolated { self?.refresh(view) } },
            webView.observe(\.canGoForward) { [weak self] view, _ in MainActor.assumeIsolated { self?.refresh(view) } },
        ]
        refresh(webView)
    }

    func detach() {
        observations.forEach { $0.invalidate() }
        observations = []
    }

    private func refresh(_ webView: WKWebView) {
        let title = webView.title.flatMap { $0.isEmpty ? nil : $0 }
        if state.title != title { state.title = title }
        if state.url != webView.url { state.url = webView.url }
        if state.isLoading != webView.isLoading { state.isLoading = webView.isLoading }
        if state.progress != webView.estimatedProgress { state.progress = webView.estimatedProgress }
        if state.canGoBack != webView.canGoBack { state.canGoBack = webView.canGoBack }
        if state.canGoForward != webView.canGoForward { state.canGoForward = webView.canGoForward }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        guard let url = navigationAction.request.url else { return (.allow, preferences) }
        let scheme = url.scheme?.lowercased() ?? ""
        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? false
        if !WebViewPool.webSchemes.contains(scheme) {
            if isMainFrame || navigationAction.targetFrame == nil { NSWorkspace.shared.open(url) }
            return (.cancel, preferences)
        }
        if navigationAction.shouldPerformDownload { return (.download, preferences) }
        return (.allow, preferences)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        guard let pool else { return .allow }
        return await pool.webView(webView, decidePolicyFor: navigationResponse)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        pool?.track(download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        pool?.track(download)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        reloadedAfterCrash = false
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let failure = error as NSError
        if failure.domain == NSURLErrorDomain, failure.code == NSURLErrorCancelled { return }
        if failure.domain == "WebKitErrorDomain", [102, 204].contains(failure.code) { return }
        guard let url = failure.userInfo[NSURLErrorFailingURLErrorKey] as? URL else { return }
        webView.loadSimulatedRequest(URLRequest(url: url), responseHTML: WebViewPool.errorPage(for: url, message: failure.localizedDescription))
    }

    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        (.performDefaultHandling, nil)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard !reloadedAfterCrash else { return }
        reloadedAfterCrash = true
        webView.reload()
    }

    // MARK: WKUIDelegate

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // target=_blank and window.open load in place.
        if let url = navigationAction.request.url, !url.absoluteString.isEmpty, url.scheme?.lowercased() != "about" {
            webView.load(navigationAction.request)
        }
        return nil
    }

    func webViewDidClose(_ webView: WKWebView) {
        state.closeRequested = true
        onClose?()
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async {
        await pool?.webView(webView, runJavaScriptAlertPanelWithMessage: message, initiatedByFrame: frame)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async -> Bool {
        await pool?.webView(webView, runJavaScriptConfirmPanelWithMessage: message, initiatedByFrame: frame) ?? false
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo) async -> String? {
        await pool?.webView(webView, runJavaScriptTextInputPanelWithPrompt: prompt, defaultText: defaultText, initiatedByFrame: frame)
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        await pool?.webView(webView, runOpenPanelWith: parameters, initiatedByFrame: frame)
    }

    func webView(_ webView: WKWebView, decideMediaCapturePermissionsFor origin: WKSecurityOrigin,
                 initiatedBy frame: WKFrameInfo, type: WKMediaCaptureType) async -> WKPermissionDecision {
        await pool?.webView(webView, decideMediaCapturePermissionsFor: origin, initiatedBy: frame, type: type) ?? .deny
    }
}

extension WebViewPool {
    /// A view for the peek card or the mini window: same cookies, content blocker, user agent and
    /// preferences as pooled pages, but not a page. Loads `url` when given. Read what it shows
    /// through `auxiliaryState(of:)`; make it a real page with `adopt(_:as:)`, or just drop it.
    public func makeAuxiliaryWebView(url: URL?) -> WKWebView {
        let webView = makeWebView()
        let controller = AuxiliaryController(pool: self)
        webView.auxiliary = controller
        controller.attach(to: webView)
        if let url {
            if url.isFileURL {
                webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            } else {
                webView.load(URLRequest(url: url))
            }
        }
        return webView
    }

    /// A popup the page opened with `window.open`. It must be built from the `configuration` WebKit
    /// handed over (that is what keeps `window.opener` and the opener's session working), and it
    /// loads whatever the page tells it to. `onClose` runs when the page calls `window.close()`.
    func makePopupWebView(configuration: WKWebViewConfiguration, onClose: @escaping () -> Void) -> WKWebView {
        let webView = makeWebView(configuration: configuration)
        let controller = AuxiliaryController(pool: self)
        controller.onClose = onClose
        webView.auxiliary = controller
        controller.attach(to: webView)
        return webView
    }

    /// The observable state of a view from `makeAuxiliaryWebView(url:)`; nil for any other view
    /// (including one that has been adopted).
    public func auxiliaryState(of webView: WKWebView) -> AuxiliaryPageState? {
        (webView as? PlinthWebView)?.auxiliary?.state
    }

    /// Makes `webView` (normally an auxiliary view) the live view of `page`, keeping its document,
    /// history and scroll position: nothing is reloaded. A different view the page had is closed.
    /// The pool reports the view's current URL, title and loading state right away.
    public func adopt(_ webView: WKWebView, as page: Page) {
        if let existing = entries[page.id] {
            if existing.webView === webView { return }
            destroy(page.id)
        }
        // Already the view of another page: move it.
        if let other = entry(for: webView) {
            other.observations.forEach { $0.invalidate() }
            other.observations = []
            entries[other.id] = nil
            forgetView(webView)
        }
        if let plinthView = webView as? PlinthWebView, let controller = plinthView.auxiliary {
            controller.detach()
            plinthView.auxiliary = nil
        }
        register(webView, as: page.id)
        reportUpdate(page.id)
        reportLoading(page.id)
    }
}
