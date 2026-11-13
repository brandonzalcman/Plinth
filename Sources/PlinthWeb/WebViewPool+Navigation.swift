import AppKit
import WebKit
import PlinthModel

// MARK: - WKNavigationDelegate

extension WebViewPool: WKNavigationDelegate {
    static let webSchemes: Set<String> = ["http", "https", "about", "blob", "data", "file", "javascript"]
    static let reportedSchemes: Set<String> = ["http", "https", "file"]

    static func navigationKind(_ type: WKNavigationType) -> NavigationKind {
        switch type {
        case .linkActivated: .linkClick
        case .formSubmitted, .formResubmitted: .formSubmit
        case .backForward: .backForward
        case .reload: .reload
        default: .other
        }
    }

    /// ⇧ alone (no ⌘, ⌥ or ⌃), left button.
    static func isPeekClick(_ action: WKNavigationAction) -> Bool {
        let flags = action.modifierFlags.intersection([.shift, .command, .option, .control])
        return action.navigationType == .linkActivated && flags == .shift && action.buttonNumber != 2
    }

    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                        preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        (decide(navigationAction, in: webView), preferences)
    }

    private func decide(_ action: WKNavigationAction, in webView: WKWebView) -> WKNavigationActionPolicy {
        guard let entry = entry(for: webView), let url = action.request.url else { return .allow }
        let scheme = url.scheme?.lowercased() ?? ""
        let isMainFrame = action.targetFrame?.isMainFrame ?? false
        let wantsNewPage = action.targetFrame == nil

        // mailto:, tel:, app links: hand to the system. Subframes cannot launch other apps.
        if !Self.webSchemes.contains(scheme) {
            if isMainFrame || wantsNewPage { NSWorkspace.shared.open(url) }
            return .cancel
        }

        // ⌘-click and middle-click open in the background; adding ⇧ selects the new page.
        if action.navigationType == .linkActivated, scheme != "javascript",
           action.modifierFlags.contains(.command) || action.buttonNumber == 2 {
            callbacks.openRequest(url, entry.id, !action.modifierFlags.contains(.shift))
            return .cancel
        }

        // ⇧-click peeks instead of navigating (target=_blank links included: they arrive here first).
        if (isMainFrame || wantsNewPage), Self.isPeekClick(action), Self.reportedSchemes.contains(scheme) {
            callbacks.peekRequest(url, entry.id)
            return .cancel
        }

        if action.shouldPerformDownload { return .download }

        if isMainFrame {
            let poolInitiated = entry.poolInitiatedLoad
            entry.poolInitiatedLoad = false
            if !poolInitiated, Self.reportedSchemes.contains(scheme) {
                let request = NavigationRequest(url: url, kind: Self.navigationKind(action.navigationType),
                                                sourceURL: webView.url, wantsNewPage: false)
                // `shouldNavigate` is only asked once `decideNavigation` allows, so a shell that diverts
                // in one is not asked to divert again in the other. History moves never reach it (as before).
                guard callbacks.decideNavigation(entry.id, request) else { return .cancel }
                let isHistoryMove = action.navigationType == .backForward || action.navigationType == .reload
                if !isHistoryMove, !callbacks.shouldNavigate(entry.id, url) { return .cancel }
            }
        }
        return .allow
    }

    public func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if let http = navigationResponse.response as? HTTPURLResponse,
           let disposition = http.value(forHTTPHeaderField: "Content-Disposition"),
           disposition.lowercased().hasPrefix("attachment") {
            return .download
        }
        return navigationResponse.canShowMIMEType ? .allow : .download
    }

    public func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        track(download)
    }

    public func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        track(download)
    }

    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard let entry = entry(for: webView) else { return }
        if entry.siteNameHint != nil {
            entry.siteNameHint = nil
        }
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let entry = entry(for: webView) else { return }
        entry.reloadedAfterCrash = false
        entry.poolInitiatedLoad = false
        guard let y = entry.pendingScrollY else { return }
        let script = "if (Math.abs(window.scrollY - \(y)) > 1) { window.scrollTo(0, \(y)); }"
        webView.evaluateJavaScript(script, completionHandler: nil)
        // Once more for pages whose height arrives after load, then start reporting scrolls again.
        Task { [weak self, weak webView] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard let self, let webView, let current = self.entry(for: webView), current.pendingScrollY == y else { return }
            current.pendingScrollY = nil
            _ = try? await webView.evaluateJavaScript(script)
        }
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        entry(for: webView)?.pendingScrollY = nil
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard let entry = entry(for: webView) else { return }
        entry.pendingScrollY = nil
        entry.poolInitiatedLoad = false
        let failure = error as NSError
        // Cancelled, interrupted by a policy decision (downloads, diverted links), or handed to a plug-in.
        if failure.domain == NSURLErrorDomain, failure.code == NSURLErrorCancelled { return }
        if failure.domain == "WebKitErrorDomain", [102, 204].contains(failure.code) { return }
        guard let url = failure.userInfo[NSURLErrorFailingURLErrorKey] as? URL else { return }
        log.info("Load failed: \(failure.localizedDescription, privacy: .public)")
        entry.poolInitiatedLoad = true
        webView.loadSimulatedRequest(URLRequest(url: url), responseHTML: Self.errorPage(for: url, message: failure.localizedDescription))
    }

    public func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        // Server trust, client certificates and HTTP basic/digest all take the system's default path
        // (keychain credentials are used when present; otherwise the request fails with its 401).
        (.performDefaultHandling, nil)
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard let entry = entry(for: webView) else { return }
        guard !entry.reloadedAfterCrash else {
            log.error("Web content process ended again right after a reload; leaving the page as it is.")
            return
        }
        entry.reloadedAfterCrash = true
        entry.poolInitiatedLoad = true
        webView.reload()
    }

    static func errorPage(for url: URL, message: String) -> String {
        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        return """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
        <meta name="color-scheme" content="light dark"><title>\(escape(url.host ?? "Can’t open page"))</title>
        <style>
        body { font: 15px -apple-system, system-ui; margin: 0; height: 100vh; display: flex; align-items: center; justify-content: center; }
        main { max-width: 440px; padding: 24px; text-align: center; }
        h1 { font-size: 20px; font-weight: 600; margin: 0 0 8px; }
        p { margin: 0 0 6px; opacity: 0.7; overflow-wrap: anywhere; }
        </style></head><body><main>
        <h1>This page didn’t load</h1><p>\(escape(message))</p><p>\(escape(url.absoluteString))</p>
        </main></body></html>
        """
    }
}

// MARK: - WKUIDelegate

extension WebViewPool: WKUIDelegate {
    public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // The shell opens the page from its URL; the new page gets no `window.opener`.
        guard let entry = entry(for: webView), let url = navigationAction.request.url,
              !url.absoluteString.isEmpty, url.scheme?.lowercased() != "about" else { return nil }
        if Self.reportedSchemes.contains(url.scheme?.lowercased() ?? "") {
            if Self.isPeekClick(navigationAction) {
                callbacks.peekRequest(url, entry.id)
                return nil
            }
            let request = NavigationRequest(url: url, kind: Self.navigationKind(navigationAction.navigationType),
                                            sourceURL: webView.url, wantsNewPage: true)
            guard callbacks.decideNavigation(entry.id, request) else { return nil }
        }
        let flags = navigationAction.modifierFlags
        callbacks.openRequest(url, entry.id, flags.contains(.command) && !flags.contains(.shift))
        return nil
    }

    public func webViewDidClose(_ webView: WKWebView) {
        guard let entry = entry(for: webView) else { return }
        callbacks.didClose(entry.id)
    }

    public func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                        initiatedByFrame frame: WKFrameInfo) async {
        guard let window = webView.window else { return }
        let alert = Self.alert(message, from: frame)
        alert.addButton(withTitle: "OK")
        _ = await alert.beginSheetModal(for: window)
    }

    public func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                        initiatedByFrame frame: WKFrameInfo) async -> Bool {
        guard let window = webView.window else { return false }
        let alert = Self.alert(message, from: frame)
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        return await alert.beginSheetModal(for: window) == .alertFirstButtonReturn
    }

    public func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                        defaultText: String?, initiatedByFrame frame: WKFrameInfo) async -> String? {
        guard let window = webView.window else { return nil }
        let alert = Self.alert(prompt, from: frame)
        let field = NSTextField(string: defaultText ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        return await alert.beginSheetModal(for: window) == .alertFirstButtonReturn ? field.stringValue : nil
    }

    public func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                        initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        guard let window = webView.window else { return nil }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        return await panel.beginSheetModal(for: window) == .OK ? panel.urls : nil
    }

    public func webView(_ webView: WKWebView, decideMediaCapturePermissionsFor origin: WKSecurityOrigin,
                        initiatedBy frame: WKFrameInfo, type: WKMediaCaptureType) async -> WKPermissionDecision {
        guard let window = webView.window else { return .deny }
        let device: String
        switch type {
        case .camera: device = "camera"
        case .microphone: device = "microphone"
        case .cameraAndMicrophone: device = "camera and microphone"
        @unknown default: device = "camera or microphone"
        }
        let alert = NSAlert()
        alert.messageText = "Allow “\(origin.host)” to use your \(device)?"
        alert.informativeText = "The page can use it until you close or leave it."
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don’t Allow")
        return await alert.beginSheetModal(for: window) == .alertFirstButtonReturn ? .grant : .deny
    }

    private static func alert(_ message: String, from frame: WKFrameInfo) -> NSAlert {
        let alert = NSAlert()
        let host = frame.securityOrigin.host
        alert.messageText = host.isEmpty ? "This page says" : "\(host) says"
        alert.informativeText = String(message.prefix(2000))
        return alert
    }
}
