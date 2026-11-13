import Foundation
import WebKit
import PlinthSettings

/// The privacy pieces both apps apply to their web views: third-party cookie rules, the Global
/// Privacy Control script, and clearing website data. The Mac's `WebViewPool` and the iOS
/// `WebPages` decide when to apply them; the definitions live here once.
public enum WebPrivacy {
    // MARK: Third-party cookies

    public static let cookieRulesIdentifier = "plinth-block-third-party-cookies-v1"
    public static let cookieRulesJSON = """
    [{"trigger":{"url-filter":".*","load-type":["third-party"]},"action":{"type":"block-cookies"}}]
    """

    @MainActor private static var cookieTask: Task<WKContentRuleList, Error>?

    /// The compiled third-party cookie rules, compiled once and cached by `WKContentRuleListStore`.
    @MainActor
    public static func cookieRuleList() async throws -> WKContentRuleList {
        if let cookieTask { return try await cookieTask.value }
        let fresh = Task { @MainActor () throws -> WKContentRuleList in
            guard let store = WKContentRuleListStore.default() else { throw ContentBlocker.BlockerError.compiledToNothing }
            if let cached = try? await store.contentRuleList(forIdentifier: cookieRulesIdentifier) { return cached }
            guard let list = try await store.compileContentRuleList(forIdentifier: cookieRulesIdentifier,
                                                                    encodedContentRuleList: cookieRulesJSON) else {
                throw ContentBlocker.BlockerError.compiledToNothing
            }
            return list
        }
        cookieTask = fresh
        do {
            return try await fresh.value
        } catch {
            cookieTask = nil
            throw error
        }
    }

    // MARK: Global Privacy Control

    /// Sets `navigator.globalPrivacyControl` to true; injected at document start in every frame.
    public static let gpcSource = """
    (function () {
      try {
        Object.defineProperty(Navigator.prototype, 'globalPrivacyControl', { get: function () { return true; }, configurable: true });
      } catch (e) {}
    })();
    """

    /// For pages already loaded when the setting changes.
    public static func gpcLiveScript(_ on: Bool) -> String {
        on ? gpcSource : """
        (function () { try { delete Navigator.prototype.globalPrivacyControl; } catch (e) {} })();
        """
    }

    /// The `Sec-GPC: 1` request header, for main-frame loads.
    public static let gpcHeader = (name: "Sec-GPC", value: "1")

    // MARK: Website data

    /// The `WKWebsiteDataStore` types that "Clear Browsing Data" removes for `kinds` (history is not
    /// website data: it lives in the store).
    public static func websiteDataTypes(for kinds: BrowsingDataKinds) -> Set<String> {
        var types = Set<String>()
        if kinds.contains(.cookiesAndSiteData) {
            types.formUnion([WKWebsiteDataTypeCookies, WKWebsiteDataTypeLocalStorage, WKWebsiteDataTypeSessionStorage,
                             WKWebsiteDataTypeIndexedDBDatabases, WKWebsiteDataTypeWebSQLDatabases,
                             WKWebsiteDataTypeServiceWorkerRegistrations, WKWebsiteDataTypeFileSystem,
                             WKWebsiteDataTypeOfflineWebApplicationCache])
        }
        if kinds.contains(.cache) {
            types.formUnion([WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeFetchCache])
        }
        return types
    }

    /// Removes cookies/site data and/or the web cache from `WKWebsiteDataStore.default()` since `date`
    /// (everything when nil).
    @MainActor
    public static func clearWebsiteData(_ kinds: BrowsingDataKinds, since date: Date?) async {
        let types = websiteDataTypes(for: kinds)
        guard !types.isEmpty else { return }
        await WKWebsiteDataStore.default().removeData(ofTypes: types, modifiedSince: date ?? .distantPast)
    }
}
