import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import PlinthModel

/// Turns a window's pins and sites into the bar's layout. Pure: the same inputs always give
/// the same layout, so the bar returns to its fuller form as soon as there is room again.
///
/// ## Bar arithmetic (left to right)
///
///     barPadding
///     [ pins: n·tile + (n−1)·itemGap ]  itemGap  [ divider: dividerWidth ]  itemGap     (only when n > 0)
///     [ sites region: at most `sitesAvailable` wide, scrolls inside itself when `scrolls` ]
///     itemGap  [ new page: tile ]  itemGap  [ flexible space ≥ 0 ]  itemGap  [ search button ]
///     barPadding
///
/// so
///
///     sitesAvailable = barWidth − 2·barPadding − pinsBlock − 3·itemGap − tile − searchButtonWidth
///     pinsBlock      = n·tile + (n−1)·itemGap + itemGap + dividerWidth + itemGap     (0 when n = 0)
///     searchButton   = searchPadding + measure("Search", .regular) + searchGap
///                      + measure("⌘L", .regular) + searchPadding                     (border drawn inside)
///     sitesWidth     = Σ item.width + (count − 1)·itemGap
///
/// `sitesAvailable` is clamped at 0 and does not depend on how many sites there are.
///
/// ## Item widths (see `width(of:metrics:measure:)`)
///
///     single     singlePadding + iconSize + singleIconGap + label + singlePadding
///     capsule    capsuleLeading + iconSize + iconTrailing
///                + Σ over pages (capsuleGap + pad + label + pad) + capsuleTrailing
///                where pad = currentPagePadding for a current page, pagePadding otherwise
///     collapsed  singlePadding + iconSize
///                + (singleIconGap + label          when labelWidth > 0)
///                + (iconTrailing + badge           when pageCount > 1)
///                + singlePadding
///     badge      max(iconSize, measure("\(pageCount)", .regular) + 2·iconTrailing)
///
/// ## Overflow: stable positions
///
/// Where a tab sits must not depend on which other tab was used last, so there is no
/// least-recently-used collapsing and no shared "level" that every name is cut to. Each tab's
/// width depends only on its own contents and on one bar-wide mode:
///
/// 1. **Natural**: each label is its measured width capped at `maxLabelWidth`. Chosen while the
///    selection-free natural width plus `naturalSlack` fits.
/// 2. **Compact**, otherwise: every page, the current ones included, has its name capped at
///    `compactLabelWidth` and the same padding, so selecting a tab never changes a width. It is left
///    again only with `compactHysteresis` more room than it takes to stay natural (`BarInput.wasCompact`).
/// 3. **Scrolling**, when compact does not fit either: the strip keeps its compact widths and scrolls,
///    and an overflow tile (`BarMetrics.overflowReserve`) is carved out of the region's room to list every tab.
///
/// A site the user folded (`Site.isFolded`, two or more pages, no page of the split) is always
/// collapsed to icon and count; nothing else ever collapses on its own.
///
public struct BarLayoutEngine: BarLayouting {
    public init() {}

    public static let searchTitle = "Search"
    public static let searchShortcut = "⌘L"

    // MARK: Width helpers shared with the view

    /// Width of the search button at the right end of the bar.
    public static func searchButtonWidth(metrics: BarMetrics, measure: (String, BarTextStyle) -> CGFloat) -> CGFloat {
        metrics.searchPadding + measure(searchTitle, .regular) + metrics.searchGap
            + measure(searchShortcut, .regular) + metrics.searchPadding
    }

    /// Width of the pin tiles (a folder is one tile), the divider after them and the gaps around the divider. Zero without pins.
    public static func pinsBlockWidth(pinCount: Int, metrics: BarMetrics) -> CGFloat {
        guard pinCount > 0 else { return 0 }
        let n = CGFloat(pinCount)
        return n * metrics.tile + (n - 1) * metrics.itemGap + metrics.itemGap + metrics.dividerWidth + metrics.itemGap
    }

    /// Width the sites region may occupy before it has to scroll. Never negative.
    public static func sitesAvailable(barWidth: CGFloat, pinCount: Int, metrics: BarMetrics,
                                      measure: (String, BarTextStyle) -> CGFloat) -> CGFloat {
        let fixed = 2 * metrics.barPadding + pinsBlockWidth(pinCount: pinCount, metrics: metrics)
            + 3 * metrics.itemGap + metrics.tile + searchButtonWidth(metrics: metrics, measure: measure)
        return max(0, barWidth - fixed)
    }

    /// The text on a collapsed site's count badge.
    public static func countText(_ pageCount: Int) -> String { "\(pageCount)" }

    /// Width of a collapsed site's count badge.
    public static func badgeWidth(pageCount: Int, metrics: BarMetrics, measure: (String, BarTextStyle) -> CGFloat) -> CGFloat {
        max(metrics.iconSize, measure(countText(pageCount), .regular) + 2 * metrics.iconTrailing)
    }

    /// Full width of one page button inside a capsule: text plus padding on both sides.
    public static func pageButtonWidth(_ page: BarPageItem, metrics: BarMetrics, compact: Bool = false) -> CGFloat {
        page.labelWidth + 2 * (page.isCurrent && !compact ? metrics.currentPagePadding : metrics.pagePadding)
    }

    /// Full outer width of a site item, from its contents alone. `BarSiteItem.width` always equals this.
    public static func width(of item: BarSiteItem, metrics: BarMetrics, measure: (String, BarTextStyle) -> CGFloat) -> CGFloat {
        switch item.form {
        case .single:
            return singleWidth(label: item.pages.first?.labelWidth ?? 0, metrics)
        case .capsule:
            return metrics.capsuleLeading + metrics.iconSize + metrics.iconTrailing
                + item.pages.reduce(0) { $0 + metrics.capsuleGap + pageButtonWidth($1, metrics: metrics, compact: item.compact) }
                + metrics.capsuleTrailing
        case .collapsed:
            let badge = item.pageCount > 1 ? badgeWidth(pageCount: item.pageCount, metrics: metrics, measure: measure) : 0
            return collapsedWidth(label: item.labelWidth, badge: badge, metrics)
        }
    }

    /// Width of the sites region: the items plus `itemGap` between neighbours.
    public static func sitesWidth(of items: [BarSiteItem], metrics: BarMetrics) -> CGFloat {
        items.reduce(0) { $0 + $1.width } + CGFloat(max(0, items.count - 1)) * metrics.itemGap
    }

    /// The text style each label is measured in.
    public static func labelStyle(isCurrent: Bool, form: BarSiteForm, fade: FadeStage) -> BarTextStyle {
        if isCurrent { return .currentPage }
        if form != .capsule && fade == .fading { return .regular }
        return .page
    }

    private static func singleWidth(label: CGFloat, _ m: BarMetrics) -> CGFloat {
        m.singlePadding + m.iconSize + m.singleIconGap + label + m.singlePadding
    }

    private static func collapsedWidth(label: CGFloat, badge: CGFloat, _ m: BarMetrics) -> CGFloat {
        m.singlePadding + m.iconSize + (label > 0 ? m.singleIconGap + label : 0)
            + (badge > 0 ? m.iconTrailing + badge : 0) + m.singlePadding
    }

    // MARK: Layout

    private struct Work {
        var collapsed = false
        var folded = false
        var pageLabels: [CGFloat]
        var pageCurrent: [Bool]
        /// Compact: current pages pad like any other.
        var compact = false
        /// Natural site-name width; used only once collapsed.
        var siteLabel: CGFloat
        var badge: CGFloat

        func width(_ m: BarMetrics) -> CGFloat {
            if collapsed { return BarLayoutEngine.collapsedWidth(label: siteLabel, badge: badge, m) }
            if pageLabels.count == 1 { return BarLayoutEngine.singleWidth(label: pageLabels[0], m) }
            var w = m.capsuleLeading + m.iconSize + m.iconTrailing + m.capsuleTrailing
            for i in pageLabels.indices {
                w += m.capsuleGap + pageLabels[i] + 2 * (pageCurrent[i] && !compact ? m.currentPagePadding : m.pagePadding)
            }
            return w
        }
    }

    private static let epsilon: CGFloat = 0.0001

    public func layout(_ input: BarInput, barWidth: CGFloat, metrics m: BarMetrics,
                       measure: (String, BarTextStyle) -> CGFloat) -> BarLayout {
        typealias E = BarLayoutEngine

        // Who is on screen, and the ⌘-number of every page.
        var visible = Set<PageID>()
        if let selected = input.selected {
            visible.insert(selected)
            if let split = input.split, split.contains(selected) {
                visible.insert(split.leading); visible.insert(split.trailing)
            }
        }
        var splitPages = Set<PageID>()
        if let split = input.split {
            splitPages = [split.leading, split.trailing]
        }

        var shortcuts: [PageID: Int] = [:]
        for (index, id) in BarOrder.pageOrder(pins: input.pins, sites: input.sites).prefix(9).enumerated() where shortcuts[id] == nil {
            shortcuts[id] = index + 1
        }

        let pins = BarOrder.arranged(input.pins).map {
            BarPinItem(id: $0.id, pageID: $0.page.id, key: $0.key, name: $0.name,
                       isCurrent: visible.contains($0.page.id), shortcut: shortcuts[$0.page.id], folderID: $0.folder?.id)
        }
        var folderNames: [UUID: String] = [:]
        for pin in input.pins { if let f = pin.folder, folderNames[f.id] == nil { folderNames[f.id] = f.name } }
        var pinSlots: [BarPinSlot] = []
        for pin in pins {
            guard let fid = pin.folderID else { pinSlots.append(.pin(pin)); continue }
            if case .folder(var f)? = pinSlots.last, f.id == fid {
                f.members.append(pin); f.isCurrent = f.isCurrent || pin.isCurrent
                pinSlots[pinSlots.count - 1] = .folder(f)
            } else {
                pinSlots.append(.folder(BarFolderItem(id: fid, name: folderNames[fid] ?? PinFolder.defaultName, members: [pin])))
            }
        }

        let available = E.sitesAvailable(barWidth: barWidth, pinCount: pinSlots.count, metrics: m, measure: measure)
        func natural(_ text: String, _ style: BarTextStyle) -> CGFloat {
            min(max(0, measure(text, style)), m.maxLabelWidth)
        }

        // Stage 1: natural widths. `current` says which pages are drawn as current; the mode decision
        // below passes none, so it never depends on the selection.
        func build(current isCurrentPage: (PageID) -> Bool, compact: Bool) -> [Work] {
            input.sites.map { site in
                let form: BarSiteForm = site.pages.count == 1 ? .single : .capsule
                let current = site.pages.map { isCurrentPage($0.id) }
                let labels = zip(site.pages, current).map { page, isCurrent -> CGFloat in
                    let width = natural(page.name, E.labelStyle(isCurrent: isCurrent, form: form,
                                                                fade: form == .single && site.fade == .fading ? .fading : page.fade))
                    guard compact else { return width }
                    // Compact: reserve the wider of the two weights for every page, so the label is the same
                    // whether or not the page is current and the semibold text never clips when selected.
                    let fade: FadeStage = form == .single && site.fade == .fading ? .fading : page.fade
                    let regular = natural(page.name, E.labelStyle(isCurrent: false, form: form, fade: fade))
                    let semibold = natural(page.name, E.labelStyle(isCurrent: true, form: form, fade: fade))
                    return min(max(regular, semibold), m.compactLabelWidth)
                }
                let folded = site.isFolded && site.pages.count > 1 && !site.pages.contains { splitPages.contains($0.id) }
                var w = Work(collapsed: folded, folded: folded, pageLabels: labels, pageCurrent: current,
                             siteLabel: folded ? 0 : natural(site.name, E.labelStyle(isCurrent: false, form: .collapsed, fade: site.fade)),
                             badge: site.pages.count > 1 ? E.badgeWidth(pageCount: site.pages.count, metrics: m, measure: measure) : 0)
                w.compact = compact
                return w
            }
        }
        func total(_ w: [Work]) -> CGFloat { w.reduce(0) { $0 + $1.width(m) } + CGFloat(max(0, w.count - 1)) * m.itemGap }

        // Stage 2: pick the mode from the selection-free natural width. Compact is entered as soon as natural
        // plus the slack for a growing current page does not fit, and left only with `compactHysteresis` more room.
        let naturalNeed = total(build(current: { _ in false }, compact: false)) + m.naturalSlack
        let stayNatural = naturalNeed <= available - (input.wasCompact ? m.compactHysteresis : 0) + E.epsilon
        var work = build(current: { visible.contains($0) }, compact: false)
        var compact = false
        var scrolls = false
        var room = available
        if !stayNatural || total(work) > available + E.epsilon {
            // Compact: one fixed cap for every page, the current one included, and the same padding,
            // so selecting a tab changes nothing but its highlight.
            compact = true
            work = build(current: { visible.contains($0) }, compact: true)
            if total(work) > available + E.epsilon {
                scrolls = true
                room = max(0, available - m.overflowReserve)
            }
        }

        // Build the items; every width comes from the public helper.
        var items: [BarSiteItem] = []
        items.reserveCapacity(work.count)
        for (site, w) in zip(input.sites, work) {
            let form: BarSiteForm = w.collapsed ? .collapsed : (site.pages.count == 1 ? .single : .capsule)
            var pages: [BarPageItem] = []
            if !w.collapsed {
                for (i, page) in site.pages.enumerated() {
                    let role: SplitRole? = input.split.flatMap { $0.leading == page.id ? .leading : ($0.trailing == page.id ? .trailing : nil) }
                    pages.append(BarPageItem(id: page.id, name: page.name, labelWidth: w.pageLabels[i], isCurrent: w.pageCurrent[i],
                                             fade: page.fade, shortcut: shortcuts[page.id], splitRole: role))
                }
            }
            var item = BarSiteItem(id: site.id, key: site.key, name: site.name, form: form, fade: site.fade, isKept: site.isKept,
                                   pages: pages, pageCount: site.pages.count, labelWidth: w.collapsed ? w.siteLabel : 0, width: 0,
                                   isFolded: w.folded, compact: w.compact)
            item.width = E.width(of: item, metrics: m, measure: measure)
            items.append(item)
        }
        let sitesWidth = E.sitesWidth(of: items, metrics: m)
        return BarLayout(pins: pins, pinSlots: pinSlots, sites: items, sitesWidth: sitesWidth, sitesAvailable: room,
                         scrolls: scrolls, compact: compact)
    }
}
