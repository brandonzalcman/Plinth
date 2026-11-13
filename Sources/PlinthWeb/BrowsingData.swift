import WebKit
import PlinthSettings

extension WebViewPool {
    /// Removes cookies/site data and/or the web cache from `WKWebsiteDataStore.default()` since `date`
    /// (everything when nil). History lives in the store: call `BrowserStore.clearHistory(since:)` for that.
    public func clearWebsiteData(_ kinds: BrowsingDataKinds, since date: Date?) async {
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
        guard !types.isEmpty else { return }
        await WKWebsiteDataStore.default().removeData(ofTypes: types, modifiedSince: date ?? .distantPast)
    }
}
