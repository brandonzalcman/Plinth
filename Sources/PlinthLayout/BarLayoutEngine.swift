import Foundation
import CoreGraphics
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
/// ## Overflow order
///
/// 1. Everything at natural width: each label is its measured width capped at `maxLabelWidth`.
/// 2. Collapse sites one at a time, least recently used first, until the region fits. A site
///    holding a visible page or either page of the split never collapses, and a site whose
///    collapsed form would not be strictly narrower is left alone.
/// 3. Shorten names, longest first (every label over a common level is cut to that level, never
///    below `minLabelWidth`; labels naturally shorter than that are left alone):
///    a. page names that are not current, and collapsed site names;
///    b. current page names;
///    c. collapsed sites drop their name altogether (icon, plus count), least recently used first.
/// 4. `scrolls = true`, with everything at its minimum.
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

    /// Width of the pins, the divider after them and the gaps around the divider. Zero without pins.
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
    public static func pageButtonWidth(_ page: BarPageItem, metrics: BarMetrics) -> CGFloat {
        page.labelWidth + 2 * (page.isCurrent ? metrics.currentPagePadding : metrics.pagePadding)
    }

    /// Full outer width of a site item, from its contents alone. `BarSiteItem.width` always equals this.
    public static func width(of item: BarSiteItem, metrics: BarMetrics, measure: (String, BarTextStyle) -> CGFloat) -> CGFloat {
        switch item.form {
        case .single:
            return singleWidth(label: item.pages.first?.labelWidth ?? 0, metrics)
        case .capsule:
            return metrics.capsuleLeading + metrics.iconSize + metrics.iconTrailing
                + item.pages.reduce(0) { $0 + metrics.capsuleGap + pageButtonWidth($1, metrics: metrics) }
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
        var pageLabels: [CGFloat]
        var pageCurrent: [Bool]
        /// Natural site-name width; used only once collapsed.
        var siteLabel: CGFloat
        var badge: CGFloat
        var canCollapse: Bool

        func width(_ m: BarMetrics) -> CGFloat {
            if collapsed { return BarLayoutEngine.collapsedWidth(label: siteLabel, badge: badge, m) }
            if pageLabels.count == 1 { return BarLayoutEngine.singleWidth(label: pageLabels[0], m) }
            var w = m.capsuleLeading + m.iconSize + m.iconTrailing + m.capsuleTrailing
            for i in pageLabels.indices {
                w += m.capsuleGap + pageLabels[i] + 2 * (pageCurrent[i] ? m.currentPagePadding : m.pagePadding)
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
        var protected = visible
        if let split = input.split { protected.insert(split.leading); protected.insert(split.trailing) }

        var shortcuts: [PageID: Int] = [:]
        for (index, id) in BarOrder.pageOrder(pins: input.pins, sites: input.sites).prefix(9).enumerated() where shortcuts[id] == nil {
            shortcuts[id] = index + 1
        }

        let pins = input.pins.map {
            BarPinItem(id: $0.id, pageID: $0.page.id, key: $0.key, name: $0.name,
                       isCurrent: visible.contains($0.page.id), shortcut: shortcuts[$0.page.id])
        }

        let available = E.sitesAvailable(barWidth: barWidth, pinCount: input.pins.count, metrics: m, measure: measure)
        func natural(_ text: String, _ style: BarTextStyle) -> CGFloat {
            min(max(0, measure(text, style)), m.maxLabelWidth)
        }

        // Stage 1: natural widths.
        var work: [Work] = input.sites.map { site in
            let form: BarSiteForm = site.pages.count == 1 ? .single : .capsule
            let current = site.pages.map { visible.contains($0.id) }
            let labels = zip(site.pages, current).map { page, isCurrent in
                natural(page.name, E.labelStyle(isCurrent: isCurrent, form: form,
                                                fade: form == .single && site.fade == .fading ? .fading : page.fade))
            }
            return Work(pageLabels: labels, pageCurrent: current,
                        siteLabel: natural(site.name, E.labelStyle(isCurrent: false, form: .collapsed, fade: site.fade)),
                        badge: site.pages.count > 1 ? E.badgeWidth(pageCount: site.pages.count, metrics: m, measure: measure) : 0,
                        canCollapse: !site.pages.contains { protected.contains($0.id) })
        }
        var total = work.reduce(0) { $0 + $1.width(m) } + CGFloat(max(0, work.count - 1)) * m.itemGap
        func fits() -> Bool { total <= available + E.epsilon }

        // Least recently used first; ties go to the leftmost site.
        let lruOrder: [Int] = work.indices.filter { work[$0].canCollapse }.sorted {
            let a = input.sites[$0].lastUsed, b = input.sites[$1].lastUsed
            return a != b ? a < b : $0 < $1
        }

        // Stage 2: collapse.
        if !fits() {
            for i in lruOrder {
                let before = work[i].width(m)
                work[i].collapsed = true
                let after = work[i].width(m)
                if after < before - E.epsilon {
                    total -= before - after
                    if fits() { break }
                } else {
                    work[i].collapsed = false
                }
            }
        }

        // Stage 3: shorten names.
        if !fits() {
            // a. Non-current page names and collapsed site names.
            var widths: [CGFloat] = []
            for w in work {
                if w.collapsed { widths.append(w.siteLabel) }
                else { for i in w.pageLabels.indices where !w.pageCurrent[i] { widths.append(w.pageLabels[i]) } }
            }
            var level = E.level(for: widths, reduceBy: total - available, floor: m.minLabelWidth)
            for s in work.indices {
                if work[s].collapsed {
                    let cut = min(work[s].siteLabel, level)
                    total -= work[s].siteLabel - cut; work[s].siteLabel = cut
                } else {
                    for i in work[s].pageLabels.indices where !work[s].pageCurrent[i] {
                        let cut = min(work[s].pageLabels[i], level)
                        total -= work[s].pageLabels[i] - cut; work[s].pageLabels[i] = cut
                    }
                }
            }
            // b. Current page names.
            if !fits() {
                widths = work.flatMap { w in w.collapsed ? [] : w.pageLabels.indices.filter { w.pageCurrent[$0] }.map { w.pageLabels[$0] } }
                level = E.level(for: widths, reduceBy: total - available, floor: m.minLabelWidth)
                for s in work.indices where !work[s].collapsed {
                    for i in work[s].pageLabels.indices where work[s].pageCurrent[i] {
                        let cut = min(work[s].pageLabels[i], level)
                        total -= work[s].pageLabels[i] - cut; work[s].pageLabels[i] = cut
                    }
                }
            }
            // c. Collapsed sites lose their name.
            if !fits() {
                for i in lruOrder where work[i].collapsed && work[i].siteLabel > 0 {
                    let before = work[i].width(m)
                    work[i].siteLabel = 0
                    total -= before - work[i].width(m)
                    if fits() { break }
                }
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
                                   pages: pages, pageCount: site.pages.count, labelWidth: w.collapsed ? w.siteLabel : 0, width: 0)
            item.width = E.width(of: item, metrics: m, measure: measure)
            items.append(item)
        }
        let sitesWidth = E.sitesWidth(of: items, metrics: m)
        return BarLayout(pins: pins, sites: items, sitesWidth: sitesWidth, sitesAvailable: available,
                         scrolls: sitesWidth > available + E.epsilon)
    }

    /// The level L (never below `floor`) at which cutting every width down to L removes `reduceBy`
    /// points in total. Returns `floor` when even that is not enough, and `.infinity` when nothing needs cutting.
    static func level(for widths: [CGFloat], reduceBy: CGFloat, floor: CGFloat) -> CGFloat {
        guard reduceBy > 0 else { return .infinity }
        let sorted = widths.filter { $0 > floor }.sorted(by: >)
        var sum: CGFloat = 0
        for (i, w) in sorted.enumerated() {
            sum += w
            let next = i + 1 < sorted.count ? sorted[i + 1] : floor
            let level = (sum - reduceBy) / CGFloat(i + 1)
            if level >= next { return max(level, floor) }
        }
        return floor
    }
}
