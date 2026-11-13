import Foundation
import CoreGraphics

// What the layout engine takes and what the bar view draws.

public enum BarTextStyle: Sendable, Hashable {
    /// 13 pt medium: a page name that is not current.
    case page
    /// 13 pt semibold: the current page.
    case currentPage
    /// 13 pt regular: a faded single-page site, and the search button.
    case regular
}

/// Sizes in points, taken from the bar artboard.
public struct BarMetrics: Sendable, Equatable {
    public var barHeight: CGFloat = 64
    public var sideInset: CGFloat = 20
    public var bottomInset: CGFloat = 16
    public var barCornerRadius: CGFloat = 20
    public var barPadding: CGFloat = 10
    public var itemGap: CGFloat = 8
    /// Pin tiles, the new-page button, and the height of every page button.
    public var tile: CGFloat = 44
    public var tileCornerRadius: CGFloat = 12
    public var dividerWidth: CGFloat = 1
    public var dividerHeight: CGFloat = 28
    public var capsuleHeight: CGFloat = 48
    public var capsuleCornerRadius: CGFloat = 14
    public var capsuleLeading: CGFloat = 10
    public var capsuleTrailing: CGFloat = 2
    public var capsuleGap: CGFloat = 2
    public var iconSize: CGFloat = 16
    public var iconCornerRadius: CGFloat = 4
    /// Space between a capsule's icon and its first page button (on top of `capsuleGap`).
    public var iconTrailing: CGFloat = 4
    public var pagePadding: CGFloat = 10
    public var currentPagePadding: CGFloat = 14
    /// A single-page site drawn on its own: horizontal padding and icon-to-text gap.
    public var singlePadding: CGFloat = 12
    public var singleIconGap: CGFloat = 8
    public var searchPadding: CGFloat = 14
    public var searchGap: CGFloat = 12
    /// Names are never shortened below this many points of text.
    public var minLabelWidth: CGFloat = 36
    /// Names are never drawn wider than this, however much room there is.
    public var maxLabelWidth: CGFloat = 180

    public init() {}
    public static let standard = BarMetrics()
}

public struct BarInput: Sendable, Equatable {
    public var pins: [PinnedSite]
    public var sites: [Site]
    /// The page with focus.
    public var selected: PageID?
    public var split: SplitPair?

    public init(pins: [PinnedSite], sites: [Site], selected: PageID?, split: SplitPair?) {
        self.pins = pins; self.sites = sites; self.selected = selected; self.split = split
    }
}

public enum SplitRole: Sendable, Equatable { case leading, trailing }

public struct BarPinItem: Identifiable, Sendable, Equatable {
    public var id: SiteID
    public var pageID: PageID
    public var key: SiteKey
    public var name: String
    public var isCurrent: Bool
    /// 1...9 when ⌘-number reaches this page.
    public var shortcut: Int?

    public init(id: SiteID, pageID: PageID, key: SiteKey, name: String, isCurrent: Bool, shortcut: Int?) {
        self.id = id; self.pageID = pageID; self.key = key; self.name = name; self.isCurrent = isCurrent; self.shortcut = shortcut
    }
}

public struct BarPageItem: Identifiable, Sendable, Equatable {
    public var id: PageID
    /// The name as drawn. The view truncates with an ellipsis to `labelWidth`.
    public var name: String
    /// Width given to the text alone, excluding padding.
    public var labelWidth: CGFloat
    /// Filled with the accent: the focused page, and its split partner.
    public var isCurrent: Bool
    public var fade: FadeStage
    public var shortcut: Int?
    public var splitRole: SplitRole?

    public init(id: PageID, name: String, labelWidth: CGFloat, isCurrent: Bool, fade: FadeStage, shortcut: Int?, splitRole: SplitRole?) {
        self.id = id; self.name = name; self.labelWidth = labelWidth; self.isCurrent = isCurrent
        self.fade = fade; self.shortcut = shortcut; self.splitRole = splitRole
    }
}

public enum BarSiteForm: Sendable, Equatable {
    /// One page: icon and page name in one button, no capsule background.
    case single
    /// Two or more pages inside a capsule led by the site icon.
    case capsule
    /// Icon, site name and a page count; `pages` is empty. Either overflow (the name, until it is
    /// shortened away) or folded by hand (`BarSiteItem.isFolded`: icon and count only).
    case collapsed
}

public struct BarSiteItem: Identifiable, Sendable, Equatable {
    public var id: SiteID
    public var key: SiteKey
    public var name: String
    public var form: BarSiteForm
    public var fade: FadeStage
    public var isKept: Bool
    public var pages: [BarPageItem]
    public var pageCount: Int
    /// Width given to the site name when collapsed, excluding padding.
    public var labelWidth: CGFloat
    /// Full outer width of the item.
    public var width: CGFloat
    /// Collapsed because the user folded it, not because the bar ran out of room.
    public var isFolded: Bool

    public init(id: SiteID, key: SiteKey, name: String, form: BarSiteForm, fade: FadeStage, isKept: Bool,
                pages: [BarPageItem], pageCount: Int, labelWidth: CGFloat, width: CGFloat, isFolded: Bool = false) {
        self.id = id; self.key = key; self.name = name; self.form = form; self.fade = fade; self.isKept = isKept
        self.pages = pages; self.pageCount = pageCount; self.labelWidth = labelWidth; self.width = width
        self.isFolded = isFolded
    }
}

public struct BarLayout: Sendable, Equatable {
    public var pins: [BarPinItem]
    public var sites: [BarSiteItem]
    /// Width of the sites region as laid out.
    public var sitesWidth: CGFloat
    /// Width the sites region may occupy before it has to scroll.
    public var sitesAvailable: CGFloat
    /// True only when collapsing and shortening were not enough.
    public var scrolls: Bool

    public init(pins: [BarPinItem], sites: [BarSiteItem], sitesWidth: CGFloat, sitesAvailable: CGFloat, scrolls: Bool) {
        self.pins = pins; self.sites = sites; self.sitesWidth = sitesWidth; self.sitesAvailable = sitesAvailable; self.scrolls = scrolls
    }
}

/// Implemented by `PlinthLayout.BarLayoutEngine`. Pure.
public protocol BarLayouting: Sendable {
    /// - Parameters:
    ///   - barWidth: the bar's full outer width (window width minus both side insets).
    ///   - measure: width of a string in a text style, in points.
    func layout(_ input: BarInput, barWidth: CGFloat, metrics: BarMetrics,
                measure: (String, BarTextStyle) -> CGFloat) -> BarLayout
}

/// Everything the bar can ask for. The bar view only reports; the shell decides.
public enum BarAction: Sendable, Equatable {
    case selectPage(PageID)
    case closePage(PageID)
    case selectPin(SiteID)
    /// A collapsed site was clicked.
    case selectSite(SiteID)
    /// The icon at the head of a capsule (fold it) or of a folded site (unfold it) was clicked.
    case toggleFold(SiteID)
    case newPage
    case openCommandBar
    case openShelf
    /// The downloads tray button, next to the shelf.
    case openDownloads
    /// The back, forward and reload buttons at the left of the bar (reload turns into stop while loading).
    case goBack
    case goForward
    case reload
    case stopLoading
    case setKept(SiteID, Bool)
    case pinSite(SiteID)
    case unpin(SiteID)
    case resetPin(SiteID)
    case shelveSite(SiteID)
    case closeSite(SiteID)
    case renamePage(PageID, String?)
    /// Show this page beside the current one.
    case splitWithCurrent(PageID)
    case endSplit
    /// A site (single button, capsule or collapsed item) was dragged to a new position among the
    /// window's sites. `toIndex` is the index in `WindowState.sites` after removal (store semantics).
    case moveSite(SiteID, toIndex: Int)
    /// A page was dragged to a new position inside its own capsule. `toIndex` is the index in the
    /// site's `pages` after removal.
    case movePage(PageID, toIndex: Int)
    /// A page was dropped onto another page: show the two side by side (dragged one trailing).
    case splitPages(PageID, onto: PageID)
}
