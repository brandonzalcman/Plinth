import Foundation

// MARK: - Identifiers

public struct PageID: Hashable, Codable, Sendable {
    public let raw: UUID
    public init(_ raw: UUID = UUID()) { self.raw = raw }
}

public struct SiteID: Hashable, Codable, Sendable {
    public let raw: UUID
    public init(_ raw: UUID = UUID()) { self.raw = raw }
}

public struct WindowID: Hashable, Codable, Sendable {
    public let raw: UUID
    public init(_ raw: UUID = UUID()) { self.raw = raw }
}

/// What counts as one website: the full host after the merge list has been applied
/// (so `www.example.com` and `example.com` share a key, but `mail.google.com` and
/// `docs.google.com` do not). Always lowercased. Non-web URLs use their scheme, e.g. "file".
public struct SiteKey: Hashable, Codable, Sendable {
    public let host: String
    public init(_ host: String) { self.host = host.lowercased() }
}

// MARK: - Usage

/// Visit count and recency. Kept per page, and per site key in `BrowserStore.siteStats`
/// (the per-site record survives the site leaving the bar, which is what makes fading adaptive).
public struct Usage: Codable, Sendable, Equatable {
    public var visitCount: Int
    /// Number of distinct calendar days on which a visit was recorded.
    public var activeDays: Int
    public var firstUsed: Date
    public var lastUsed: Date

    public init(visitCount: Int = 1, activeDays: Int = 1, firstUsed: Date, lastUsed: Date) {
        self.visitCount = visitCount
        self.activeDays = activeDays
        self.firstUsed = firstUsed
        self.lastUsed = lastUsed
    }

    public init(at now: Date) { self.init(firstUsed: now, lastUsed: now) }

    /// A visit is the user selecting or opening the page (not a background load).
    public mutating func recordVisit(at now: Date, calendar: Calendar = .current) {
        visitCount += 1
        if !calendar.isDate(now, inSameDayAs: lastUsed) { activeDays += 1 }
        lastUsed = max(lastUsed, now)
    }
}

// MARK: - Pages and sites

/// How an item on the bar is drawn. An item that has gone past `fading` is no longer
/// on the bar at all: it is on the shelf.
public enum FadeStage: String, Codable, Sendable {
    case live
    /// Drawn with a dashed outline; about to drop onto the shelf.
    case fading
}

public struct Page: Identifiable, Codable, Sendable, Equatable {
    public let id: PageID
    public var url: URL
    /// The document title exactly as WebKit reported it.
    public var rawTitle: String
    /// The short name shown on the bar (from `PageNaming`, or `customName` when set).
    public var name: String
    /// A name the user typed; wins over the derived name until cleared.
    public var customName: String?
    public var usage: Usage
    public var fade: FadeStage
    /// Vertical scroll offset in CSS pixels, restored when a discarded page reloads.
    public var scrollY: Double
    /// Seconds the page has been visible and frontmost, in total.
    public var dwell: TimeInterval

    public init(id: PageID = PageID(), url: URL, rawTitle: String = "", name: String, customName: String? = nil,
                usage: Usage, fade: FadeStage = .live, scrollY: Double = 0, dwell: TimeInterval = 0) {
        self.id = id; self.url = url; self.rawTitle = rawTitle; self.name = name; self.customName = customName
        self.usage = usage; self.fade = fade; self.scrollY = scrollY; self.dwell = dwell
    }
}

/// A website on one window's bar: one or more pages that share a `SiteKey`.
/// A site with one page is drawn as a single named button; two or more form a capsule.
public struct Site: Identifiable, Codable, Sendable, Equatable {
    public let id: SiteID
    public var key: SiteKey
    public var name: String
    /// Never empty while the site is on a bar. Order is display order, left to right.
    public var pages: [Page]
    /// The page shown when the site is selected as a whole (its most recently selected page).
    public var currentPageID: PageID
    /// "Kept" sites never fade, and neither do their pages.
    public var isKept: Bool
    public var fade: FadeStage

    public init(id: SiteID = SiteID(), key: SiteKey, name: String, pages: [Page], currentPageID: PageID? = nil,
                isKept: Bool = false, fade: FadeStage = .live) {
        precondition(!pages.isEmpty, "A site needs at least one page")
        self.id = id; self.key = key; self.name = name; self.pages = pages
        self.currentPageID = currentPageID ?? pages[pages.count - 1].id
        self.isKept = isKept; self.fade = fade
    }

    public var currentPage: Page { pages.first { $0.id == currentPageID } ?? pages[0] }
    /// The most recent use of any page in the site.
    public var lastUsed: Date { pages.map(\.usage.lastUsed).max() ?? .distantPast }
}

/// A pinned site is a resident mini-app: exactly one page, drawn as an icon-only tile at the
/// left of every window's bar. Pins are global, never fade and never grow a capsule. A link
/// inside a pin that leaves the pin's site key opens as an ordinary page instead.
public struct PinnedSite: Identifiable, Codable, Sendable, Equatable {
    public let id: SiteID
    public var key: SiteKey
    public var name: String
    /// Where the pin goes back to when reset.
    public var homeURL: URL
    public var page: Page

    public init(id: SiteID = SiteID(), key: SiteKey, name: String, homeURL: URL, page: Page) {
        self.id = id; self.key = key; self.name = name; self.homeURL = homeURL; self.page = page
    }
}

// MARK: - Windows

/// Two pages shown side by side. Both stay on the bar as separate entries, joined by a bracket.
/// Closing or shelving either page ends the split.
public struct SplitPair: Codable, Sendable, Equatable {
    public var leading: PageID
    public var trailing: PageID
    /// Share of the width given to the leading pane, 0.2...0.8.
    public var fraction: Double

    public init(leading: PageID, trailing: PageID, fraction: Double = 0.5) {
        self.leading = leading; self.trailing = trailing; self.fraction = fraction
    }

    public func contains(_ id: PageID) -> Bool { leading == id || trailing == id }
    public func other(than id: PageID) -> PageID? {
        id == leading ? trailing : (id == trailing ? leading : nil)
    }
}

/// Each window owns its bar. The shelf, pins and history are global.
public struct WindowState: Identifiable, Codable, Sendable, Equatable {
    public let id: WindowID
    public var sites: [Site]
    /// The page with keyboard focus: a page in `sites`, a pin's page, or nil for an empty window.
    public var selectedPageID: PageID?
    public var split: SplitPair?
    /// Window frame in screen points as [x, y, width, height], when known.
    public var frame: [Double]?
    /// When set, the bar shows only the sites of this group (plus the site of the selected page).
    /// Nothing is closed or shelved: clearing it shows everything again.
    public var focusedGroup: GroupID?

    public init(id: WindowID = WindowID(), sites: [Site] = [], selectedPageID: PageID? = nil,
                split: SplitPair? = nil, frame: [Double]? = nil, focusedGroup: GroupID? = nil) {
        self.id = id; self.sites = sites; self.selectedPageID = selectedPageID; self.split = split; self.frame = frame
        self.focusedGroup = focusedGroup
    }

    /// Every page on screen in this window: the selected page plus its split partner.
    public var visiblePageIDs: Set<PageID> {
        var ids = Set<PageID>()
        if let selectedPageID { ids.insert(selectedPageID) }
        if let split, let selectedPageID, split.contains(selectedPageID) {
            ids.insert(split.leading); ids.insert(split.trailing)
        }
        return ids
    }

    public func site(containing page: PageID) -> Site? {
        sites.first { $0.pages.contains { $0.id == page } }
    }
    public func page(_ id: PageID) -> Page? {
        for site in sites { if let p = site.pages.first(where: { $0.id == id }) { return p } }
        return nil
    }
}

// MARK: - Shelf, history, search

/// Pages of one site that have dropped off a bar. One entry per site key: pages that fade
/// later from the same site are merged into the existing entry.
public struct ShelfEntry: Identifiable, Codable, Sendable, Equatable {
    public let id: SiteID
    public var key: SiteKey
    public var name: String
    public var pages: [Page]
    /// When the most recent page joined the entry.
    public var shelvedAt: Date

    public init(id: SiteID = SiteID(), key: SiteKey, name: String, pages: [Page], shelvedAt: Date) {
        self.id = id; self.key = key; self.name = name; self.pages = pages; self.shelvedAt = shelvedAt
    }
}

public struct HistoryEntry: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public var url: URL
    public var title: String
    public var name: String
    public var key: SiteKey
    public var visitedAt: Date
    /// Seconds the page was frontmost during this visit. Later: only entries with 30 s or more are embedded.
    public var dwell: TimeInterval

    public init(id: UUID = UUID(), url: URL, title: String, name: String, key: SiteKey, visitedAt: Date, dwell: TimeInterval = 0) {
        self.id = id; self.url = url; self.title = title; self.name = name; self.key = key
        self.visitedAt = visitedAt; self.dwell = dwell
    }
}

public struct SearchResult: Identifiable, Sendable, Equatable {
    public enum Target: Sendable, Equatable {
        case openPage(PageID, window: WindowID)
        case pin(SiteID)
        case shelf(entry: SiteID, page: PageID)
        case history(URL)
    }
    public var id: String
    public var target: Target
    public var title: String
    /// Usually the URL, shortened for display.
    public var subtitle: String
    public var key: SiteKey
    /// Found by semantic (embedding) search rather than by keyword. Listed after keyword results,
    /// under a "By meaning" heading.
    public var byMeaning: Bool
    /// The one result confident enough to be the default for what was typed (an inline-completion
    /// quality match). Always first in its list.
    public var isTopHit: Bool

    public init(id: String, target: Target, title: String, subtitle: String, key: SiteKey, byMeaning: Bool = false, isTopHit: Bool = false) {
        self.id = id; self.target = target; self.title = title; self.subtitle = subtitle; self.key = key
        self.byMeaning = byMeaning; self.isTopHit = isTopHit
    }
}

// MARK: - Shortcut order

public enum BarOrder {
    /// The order ⌘1–9 counts in: every page button left to right, pins first, then each
    /// site's pages in order. Independent of how the bar is currently collapsed.
    public static func pageOrder(pins: [PinnedSite], sites: [Site]) -> [PageID] {
        pins.map(\.page.id) + sites.flatMap { $0.pages.map(\.id) }
    }
}
