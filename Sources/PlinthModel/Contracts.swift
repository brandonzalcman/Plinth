import Foundation

// The seams between modules. Each protocol has exactly one production implementation,
// in the module named beside it. `BrowserStore` only ever sees these protocols.

/// Implemented by `PlinthRules.SiteIdentity`.
public protocol SiteIdentifying: Sendable {
    /// Full host with the merge list applied (`www.`, `m.`, known sign-in hosts fold into their parent).
    func key(for url: URL) -> SiteKey
    /// A readable name for a site when the page gives no better hint, e.g. "example.com" -> "Example".
    func siteName(for key: SiteKey) -> String
}

/// Implemented by `PlinthRules.PageNamer`. Deterministic: no model, no network.
public protocol PageNaming: Sendable {
    /// "Seat map — Example Air · Book flights" with siteName "Example Air" -> "Seat map".
    /// Never returns an empty string.
    func name(title: String, url: URL, siteName: String) -> String
}

/// The outcome of one fading pass over a window.
public struct FadeVerdict: Sendable, Equatable {
    /// Stage for every page that stays on the bar. Pages not listed are unchanged.
    public var pageStages: [PageID: FadeStage]
    /// Stage for every site that stays on the bar. Sites not listed are unchanged.
    public var siteStages: [SiteID: FadeStage]
    /// Individual pages to move to the shelf while their site stays.
    public var pagesToShelve: [PageID]
    /// Whole sites to move to the shelf, with every page they still hold.
    public var sitesToShelve: [SiteID]
    /// When something would next change if nothing is used in the meantime.
    public var nextCheck: Date?

    public init(pageStages: [PageID: FadeStage] = [:], siteStages: [SiteID: FadeStage] = [:],
                pagesToShelve: [PageID] = [], sitesToShelve: [SiteID] = [], nextCheck: Date? = nil) {
        self.pageStages = pageStages; self.siteStages = siteStages
        self.pagesToShelve = pagesToShelve; self.sitesToShelve = sitesToShelve; self.nextCheck = nextCheck
    }
}

/// Implemented by `PlinthFade.FadeEngine`. Pure: same inputs, same verdict.
public protocol FadeEvaluating: Sendable {
    /// - Parameters:
    ///   - sites: one window's sites.
    ///   - stats: lifetime usage per site key, including sites no longer on any bar.
    ///   - visible: pages on screen right now; these and their sites never fade.
    func evaluate(sites: [Site], stats: [SiteKey: Usage], visible: Set<PageID>, now: Date) -> FadeVerdict
}

/// Things the store tells the app shell so it can manage web views.
public enum StoreEvent: Sendable, Equatable {
    case pageOpened(PageID, window: WindowID)
    /// Closed by hand: the web view should be destroyed.
    case pageClosed(PageID)
    /// Dropped onto the shelf: the web views should be suspended (kept alive, subject to the cap).
    case pagesShelved([PageID], key: SiteKey)
    case pagesRestored([PageID], window: WindowID)
    case selectionChanged(WindowID)
    /// The page should load this URL (reopened pages, pin reset, address typed for an existing page).
    case navigate(PageID, URL)
}
