import AppKit
import WebKit
import PlinthSettings

/// Web-facing settings.
///
/// Live (existing pages follow at once): third-party cookie blocking (affects requests made
/// from now on), minimum font size, default zoom (pages the user has not zoomed by hand),
/// default font size and the Global Privacy Control JS property (injected into the current
/// document too), downloads, HTTPS-only and the `Sec-GPC` header (next navigation).
/// Next page load: the content blocker (the rule list applies to loads started after the
/// change, so a page needs a reload to be fully blocked or unblocked).
extension WebViewPool {
    /// Applies every web-facing setting: called once at launch and after every change.
    public func apply(_ settings: AppSettings) {
        let old = self.settings
        self.settings = settings

        if settings.contentBlockerEnabled != old.contentBlockerEnabled || (settings.contentBlockerEnabled && ruleList == nil) {
            syncContentBlocker()
        }
        if settings.blockThirdPartyCookies != old.blockThirdPartyCookies || (settings.blockThirdPartyCookies && cookieRuleList == nil) {
            syncCookieBlocker()
        }
        if settings.globalPrivacyControl != old.globalPrivacyControl || settings.defaultFontSize != old.defaultFontSize {
            rebuildUserScripts()
            for entry in entries.values {
                if settings.defaultFontSize != old.defaultFontSize {
                    entry.webView.evaluateJavaScript(Self.fontSizeLiveScript(settings.defaultFontSize), completionHandler: nil)
                }
                if settings.globalPrivacyControl != old.globalPrivacyControl {
                    entry.webView.evaluateJavaScript(Self.gpcLiveScript(settings.globalPrivacyControl), completionHandler: nil)
                }
            }
        }
        if settings.minimumFontSize != old.minimumFontSize {
            for entry in entries.values {
                entry.webView.configuration.preferences.minimumFontSize = CGFloat(settings.minimumFontSize)
            }
        }
        if settings.defaultZoom != old.defaultZoom {
            let zoom = CGFloat(Self.clampedZoom(settings.defaultZoom))
            for entry in entries.values where !entry.manualZoom { entry.webView.pageZoom = zoom }
        }
    }

    // MARK: Content blocker and cookie rules

    func syncContentBlocker() {
        blockerGeneration += 1
        let generation = blockerGeneration
        guard settings.contentBlockerEnabled else {
            if let list = ruleList { userContent.remove(list) }
            ruleList = nil
            return
        }
        guard ruleList == nil else { return }
        Task { [weak self] in
            do {
                let list = try await ContentBlocker.ruleList()
                guard let self, self.blockerGeneration == generation, self.settings.contentBlockerEnabled,
                      self.ruleList == nil else { return }
                self.ruleList = list
                self.userContent.add(list)
            } catch {
                self?.log.error("Content blocker unavailable, browsing unblocked: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private static let cookieRulesIdentifier = "plinth-block-third-party-cookies-v1"
    private static let cookieRulesJSON = """
    [{"trigger":{"url-filter":".*","load-type":["third-party"]},"action":{"type":"block-cookies"}}]
    """

    func syncCookieBlocker() {
        cookieGeneration += 1
        let generation = cookieGeneration
        guard settings.blockThirdPartyCookies else {
            if let list = cookieRuleList { userContent.remove(list) }
            cookieRuleList = nil
            return
        }
        guard cookieRuleList == nil else { return }
        Task { [weak self] in
            guard let store = WKContentRuleListStore.default() else { return }
            var list = try? await store.contentRuleList(forIdentifier: Self.cookieRulesIdentifier)
            if list == nil {
                list = try? await store.compileContentRuleList(forIdentifier: Self.cookieRulesIdentifier,
                                                               encodedContentRuleList: Self.cookieRulesJSON)
            }
            guard let self, let list, self.cookieGeneration == generation, self.settings.blockThirdPartyCookies,
                  self.cookieRuleList == nil else {
                if list == nil { self?.log.error("Third-party cookie rules failed to compile") }
                return
            }
            self.cookieRuleList = list
            self.userContent.add(list)
        }
    }

    // MARK: User scripts

    /// Replaces the controller's user scripts: the page script always, plus Global Privacy Control
    /// and the default font size when set. Loaded pages keep the scripts they already ran.
    func rebuildUserScripts() {
        userContent.removeAllUserScripts()
        userContent.addUserScript(WKUserScript(source: PageScript.source, injectionTime: .atDocumentEnd,
                                               forMainFrameOnly: true, in: .defaultClient))
        if settings.globalPrivacyControl {
            userContent.addUserScript(WKUserScript(source: Self.gpcSource, injectionTime: .atDocumentStart,
                                                   forMainFrameOnly: false, in: .page))
        }
        if settings.defaultFontSize != 16 {
            userContent.addUserScript(WKUserScript(source: Self.fontSizeSource(settings.defaultFontSize),
                                                   injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .defaultClient))
        }
    }

    static let gpcSource = """
    (function () {
      try {
        Object.defineProperty(Navigator.prototype, 'globalPrivacyControl', { get: function () { return true; }, configurable: true });
      } catch (e) {}
    })();
    """

    static func gpcLiveScript(_ on: Bool) -> String {
        on ? gpcSource : """
        (function () { try { delete Navigator.prototype.globalPrivacyControl; } catch (e) {} })();
        """
    }

    /// WebKit has no public "default font size" API, so the root font size is set from a style
    /// element. Limits: only text sized relative to the root (rem, em, percentages, keywords)
    /// follows it; pages that set pixel sizes, or their own `html { font-size }`, are unaffected.
    static func fontSizeSource(_ size: Int) -> String {
        """
        (function () {
          var css = 'html{font-size:\(size)px}';
          function install() {
            var root = document.documentElement;
            if (!root) { return false; }
            var el = document.getElementById('plinth-default-font-size');
            if (!el) { el = document.createElement('style'); el.id = 'plinth-default-font-size'; root.appendChild(el); }
            el.textContent = css;
            return true;
          }
          if (!install()) { document.addEventListener('readystatechange', install); }
        })();
        """
    }

    static func fontSizeLiveScript(_ size: Int) -> String {
        if size == 16 {
            return "(function () { var el = document.getElementById('plinth-default-font-size'); if (el) { el.remove(); } })();"
        }
        return fontSizeSource(size)
    }
}
