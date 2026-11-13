import WebKit
import PlinthSettings

extension WebViewPool {
    /// Removes cookies/site data and/or the web cache from `WKWebsiteDataStore.default()` since `date`
    /// (everything when nil). History lives in the store: call `BrowserStore.clearHistory(since:)` for that.
    public func clearWebsiteData(_ kinds: BrowsingDataKinds, since date: Date?) async {
        await WebPrivacy.clearWebsiteData(kinds, since: date)
    }
}
