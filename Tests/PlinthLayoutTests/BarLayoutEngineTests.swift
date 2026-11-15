import Foundation
import CoreGraphics
import Testing
import PlinthModel
@testable import PlinthLayout

// MARK: - Fixtures

/// 7 pt per character, 7.5 for the semibold current page.
private let measure: @Sendable (String, BarTextStyle) -> CGFloat = { text, style in
    CGFloat(text.count) * (style == .currentPage ? 7.5 : 7)
}
private let m = BarMetrics.standard
private let engine = BarLayoutEngine()
private let t0 = Date(timeIntervalSince1970: 1_000_000)
private typealias E = BarLayoutEngine

private func page(_ name: String, used: TimeInterval = 0, fade: FadeStage = .live) -> Page {
    Page(url: URL(string: "https://example.com/\(name)")!, name: name, usage: Usage(at: t0.addingTimeInterval(used)), fade: fade)
}
private func site(_ name: String, _ pages: [Page], kept: Bool = false, fade: FadeStage = .live) -> Site {
    Site(key: SiteKey(name + ".com"), name: name, pages: pages, isKept: kept, fade: fade)
}
/// A site with `count` pages named `<prefix>0`, `<prefix>1`…, all used at `used`.
private func site(_ name: String, pages count: Int, prefix: String = "page", used: TimeInterval = 0) -> Site {
    site(name, (0..<count).map { page("\(prefix)\($0)", used: used) })
}
private func pin(_ name: String) -> PinnedSite {
    PinnedSite(key: SiteKey(name + ".com"), name: name, homeURL: URL(string: "https://\(name).com")!, page: page(name))
}
private func input(pins: [PinnedSite] = [], _ sites: [Site], selected: PageID? = nil, split: SplitPair? = nil) -> BarInput {
    BarInput(pins: pins, sites: sites, selected: selected, split: split)
}
private func run(_ input: BarInput, width: CGFloat) -> BarLayout {
    engine.layout(input, barWidth: width, metrics: m, measure: measure)
}
/// Bar width that leaves exactly `available` points for the sites region.
private func barWidth(forAvailable available: CGFloat, pins: Int = 0) -> CGFloat {
    available + 184 + E.pinsBlockWidth(pinCount: pins, metrics: m)
}
/// The invariants every layout must satisfy.
private func checkConsistent(_ layout: BarLayout, _ input: BarInput, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(layout.sites.count == input.sites.count, sourceLocation: sourceLocation)
    var sum: CGFloat = 0
    for (item, site) in zip(layout.sites, input.sites) {
        #expect(item.id == site.id, sourceLocation: sourceLocation)
        #expect(item.width == E.width(of: item, metrics: m, measure: measure), sourceLocation: sourceLocation)
        #expect(item.pageCount == site.pages.count, sourceLocation: sourceLocation)
        switch item.form {
        case .single: #expect(item.pages.count == 1 && site.pages.count == 1, sourceLocation: sourceLocation)
        case .capsule: #expect(item.pages.count == site.pages.count && site.pages.count >= 2, sourceLocation: sourceLocation)
        case .collapsed: #expect(item.pages.isEmpty, sourceLocation: sourceLocation)
        }
        for p in item.pages {
            #expect(p.labelWidth >= 0 && p.labelWidth <= m.maxLabelWidth, sourceLocation: sourceLocation)
        }
        sum += item.width
    }
    sum += CGFloat(max(0, layout.sites.count - 1)) * m.itemGap
    #expect(abs(layout.sitesWidth - sum) < 0.001, sourceLocation: sourceLocation)
    #expect(layout.scrolls == (layout.sitesWidth > layout.sitesAvailable + 0.001), sourceLocation: sourceLocation)
}
private func collapsedIDs(_ layout: BarLayout) -> Set<SiteID> {
    Set(layout.sites.filter { $0.form == .collapsed }.map(\.id))
}

// MARK: - Fixed parts

@Suite struct FixedParts {
    @Test func searchButtonWidth() {
        // 14 + "Search" 42 + 12 + "⌘L" 14 + 14
        #expect(E.searchButtonWidth(metrics: m, measure: measure) == 96)
    }

    @Test func availableWithoutPins() {
        // 1000 − 20 padding − 24 gaps − 44 new page − 96 search
        #expect(run(input([]), width: 1000).sitesAvailable == 816)
    }

    @Test func availableWithPins() {
        // two pins: 44 + 8 + 44, then 8 + 1 + 8
        #expect(E.pinsBlockWidth(pinCount: 2, metrics: m) == 113)
        #expect(run(input(pins: [pin("a"), pin("b")], []), width: 1000).sitesAvailable == 703)
    }

    @Test func availableNeverNegative() {
        let layout = run(input([site("A", pages: 1)]), width: 50)
        #expect(layout.sitesAvailable == 0)
        #expect(layout.scrolls)
    }

    @Test func zeroSites() {
        let layout = run(input([]), width: 1000)
        #expect(layout.sites.isEmpty && layout.pins.isEmpty)
        #expect(layout.sitesWidth == 0)
        #expect(!layout.scrolls)
    }

    @Test func zeroSitesOnATinyBarDoesNotScroll() {
        let layout = run(input([]), width: 10)
        #expect(layout.sitesWidth == 0 && !layout.scrolls)
    }
}

// MARK: - Natural widths

@Suite struct NaturalFit {
    @Test func singleWidth() {
        let i = input([site("Site", [page("abcde")])])
        let layout = run(i, width: 1000)
        let item = layout.sites[0]
        #expect(item.form == .single)
        #expect(item.pages[0].labelWidth == 35)
        #expect(item.width == 83) // 12 + 16 + 8 + 35 + 12
        #expect(layout.sitesWidth == 83)
        #expect(!layout.scrolls)
        checkConsistent(layout, i)
    }

    @Test func currentSingleIsMeasuredSemibold() {
        let p = page("abcde")
        let layout = run(input([site("Site", [p])], selected: p.id), width: 1000)
        #expect(layout.sites[0].pages[0].isCurrent)
        #expect(layout.sites[0].pages[0].labelWidth == 37.5)
        #expect(layout.sites[0].width == 85.5)
    }

    @Test func capsuleWidth() {
        let i = input([site("Site", [page("aaaa"), page("bbbb")])])
        let layout = run(i, width: 1000)
        #expect(layout.sites[0].form == .capsule)
        #expect(layout.sites[0].width == 132) // 10 + 16 + 4 + 2·(2 + 10 + 28 + 10) + 2
        checkConsistent(layout, i)
    }

    @Test func capsuleCurrentPageGetsWiderPadding() {
        let a = page("aaaa"), b = page("bbbb")
        let layout = run(input([site("Site", [a, b])], selected: b.id), width: 1000)
        #expect(layout.sites[0].pages.map(\.isCurrent) == [false, true])
        #expect(layout.sites[0].pages[1].labelWidth == 30)
        // 10 + 16 + 4 + (2 + 48) + (2 + 14 + 30 + 14) + 2
        #expect(layout.sites[0].width == 142)
        #expect(E.pageButtonWidth(layout.sites[0].pages[1], metrics: m) == 58)
    }

    @Test func labelsAreCappedAtMaxWidth() {
        let layout = run(input([site("Site", [page(String(repeating: "x", count: 60))])]), width: 2000)
        #expect(layout.sites[0].pages[0].labelWidth == m.maxLabelWidth)
        #expect(layout.sites[0].pages[0].name.count == 60)
    }

    @Test func gapsBetweenSites() {
        let i = input([site("A", [page("abcde")]), site("B", [page("abcde")]), site("C", [page("abcde")])])
        let layout = run(i, width: 1000)
        #expect(layout.sitesWidth == CGFloat(3 * 83 + 2 * 8))
        checkConsistent(layout, i)
    }

    @Test func exactFitDoesNotDegrade() {
        let i = input([site("A", pages: 3, used: 1), site("B", pages: 3, used: 2)])
        let natural = run(i, width: 5000).sitesWidth
        let layout = run(i, width: barWidth(forAvailable: natural))
        #expect(layout.sitesAvailable == natural)
        #expect(collapsedIDs(layout).isEmpty && !layout.scrolls)
    }

    @Test func fadeAndKeptAreCopiedThrough() {
        let fadingPage = page("old", fade: .fading)
        let i = input([site("A", [page("one"), fadingPage], kept: true), site("B", [page("solo")], fade: .fading)])
        let layout = run(i, width: 1000)
        #expect(layout.sites[0].isKept && layout.sites[0].fade == .live)
        #expect(layout.sites[0].pages.map(\.fade) == [.live, .fading])
        #expect(layout.sites[1].fade == .fading && layout.sites[1].form == .single && !layout.sites[1].isKept)
    }

    @Test func fadingSiteKeepsItsCapsuleForm() {
        let i = input([site("A", [page("one"), page("two")], fade: .fading)])
        let layout = run(i, width: 1000)
        #expect(layout.sites[0].form == .capsule && layout.sites[0].fade == .fading)
    }

    @Test func emptySiteLabelWhenNotCollapsed() {
        let layout = run(input([site("Site", pages: 2)]), width: 1000)
        #expect(layout.sites[0].labelWidth == 0)
        #expect(layout.sites[0].name == "Site")
    }
}

// MARK: - Current, split, shortcuts

@Suite struct Marking {
    @Test func onlySelectedIsCurrentWithoutSplit() {
        let a = page("a"), b = page("b"), c = page("c")
        let layout = run(input([site("S", [a, b]), site("T", [c])], selected: b.id), width: 1000)
        #expect(layout.sites.flatMap(\.pages).filter(\.isCurrent).map(\.id) == [b.id])
        #expect(layout.sites.flatMap(\.pages).allSatisfy { $0.splitRole == nil })
    }

    @Test func splitPairBothCurrentWithRoles() {
        let a = page("a"), b = page("b"), c = page("c")
        let split = SplitPair(leading: c.id, trailing: a.id)
        let layout = run(input([site("S", [a, b]), site("T", [c])], selected: a.id, split: split), width: 1000)
        let pages = layout.sites.flatMap(\.pages)
        #expect(pages.map(\.isCurrent) == [true, false, true])
        #expect(pages.map(\.splitRole) == [.trailing, nil, .leading])
    }

    @Test func splitNotOnScreenKeepsRolesButIsNotCurrent() {
        let a = page("a"), b = page("b"), c = page("c")
        let split = SplitPair(leading: a.id, trailing: b.id)
        let layout = run(input([site("S", [a]), site("T", [b]), site("U", [c])], selected: c.id, split: split), width: 1000)
        let pages = layout.sites.flatMap(\.pages)
        #expect(pages.map(\.isCurrent) == [false, false, true])
        #expect(pages.map(\.splitRole) == [.leading, .trailing, nil])
    }

    @Test func nothingSelected() {
        let layout = run(input([site("S", pages: 2)]), width: 1000)
        #expect(layout.sites[0].pages.allSatisfy { !$0.isCurrent })
    }

    @Test func pinIsCurrentWhenItsPageIsSelected() {
        let p1 = pin("mail"), p2 = pin("chat")
        let layout = run(input(pins: [p1, p2], [site("S", pages: 1)], selected: p2.page.id), width: 1000)
        #expect(layout.pins.map(\.isCurrent) == [false, true])
        #expect(layout.pins.map(\.id) == [p1.id, p2.id])
        #expect(layout.pins.map(\.pageID) == [p1.page.id, p2.page.id])
        #expect(layout.pins[0].name == "mail" && layout.pins[0].key == SiteKey("mail.com"))
        #expect(layout.sites[0].pages[0].isCurrent == false)
    }

    @Test func shortcutsCountPinsFirst() {
        let i = input(pins: [pin("p1"), pin("p2")], [site("A", pages: 2), site("B", pages: 1)])
        let layout = run(i, width: 2000)
        #expect(layout.pins.map(\.shortcut) == [1, 2])
        #expect(layout.sites.flatMap(\.pages).map(\.shortcut) == [3, 4, 5])
    }

    @Test func shortcutsStopAtNine() {
        let i = input(pins: [pin("p1")], [site("A", pages: 5), site("B", pages: 5), site("C", pages: 1)])
        let layout = run(i, width: 5000)
        #expect(layout.sites.flatMap(\.pages).map(\.shortcut) == [2, 3, 4, 5, 6, 7, 8, 9, nil, nil, nil])
    }

    @Test func manyPinsHaveNoShortcutPastNine() {
        let i = input(pins: (0..<11).map { pin("p\($0)") }, [site("A", pages: 1)])
        let layout = run(i, width: 5000)
        #expect(layout.pins.map(\.shortcut) == [1, 2, 3, 4, 5, 6, 7, 8, 9, nil, nil])
        #expect(layout.sites[0].pages[0].shortcut == nil)
    }

    @Test func shortcutsDoNotChangeWhenSitesFold() {
        let sel = page("selected", used: 100)
        let i = input([folded(site("Old", pages: 3, prefix: "a long page name ", used: 1)), site("Now", [sel, page("other", used: 100)])],
                      selected: sel.id)
        let wide = run(i, width: 5000), narrow = run(i, width: barWidth(forAvailable: 300))
        #expect(narrow.sites[0].form == .collapsed && wide.sites[0].form == .collapsed)
        #expect(wide.sites[1].pages.map(\.shortcut) == [4, 5])
        #expect(narrow.sites[1].pages.map(\.shortcut) == [4, 5])
    }
}

// MARK: - Collapsed width arithmetic

@Suite struct Collapsing {
    @Test func collapsedWidthArithmetic() {
        let a = folded(site("Beta", pages: 3, prefix: "betaapage"))
        let layout = run(input([a]), width: 5000)
        let beta = layout.sites[0]
        #expect(beta.form == .collapsed && beta.pages.isEmpty && beta.pageCount == 3)
        #expect(beta.width == CGFloat(60))
        #expect(E.badgeWidth(pageCount: 3, metrics: m, measure: measure) == 16)
    }

    @Test func wideBadgeForLargeCounts() {
        // "123" = 21 + 2·4
        #expect(E.badgeWidth(pageCount: 123, metrics: m, measure: measure) == 29)
        #expect(E.countText(12) == "12")
    }

    @Test func nothingCollapsesOnItsOwn() {
        let sites = (0..<12).map { site("Site\($0)", pages: 3, prefix: "a long page name ", used: TimeInterval($0)) }
        for width in stride(from: CGFloat(0), through: 3000, by: 37) {
            #expect(collapsedIDs(run(input(sites), width: width)).isEmpty)
        }
    }
}

// MARK: - Compact and scrolling

@Suite struct Overflow {
    /// A 20-character page is 140 pt of text; compact keeps 96.
    private func longTabs(_ n: Int) -> [Site] {
        (0..<n).map { site("S\($0)", [page(String(format: "page number %08d", $0), used: TimeInterval($0))]) }
    }

    @Test func compactCapsNonVisibleNamesAtOneFixedWidth() {
        let sites = longTabs(4)
        let i = input(sites, selected: sites[1].pages[0].id)
        let natural = run(i, width: 5000)
        #expect(natural.sites[0].pages[0].labelWidth == 140)
        let layout = run(i, width: barWidth(forAvailable: natural.sitesWidth - 1))
        #expect(layout.sites.map { $0.pages[0].labelWidth } == [96, 150, 96, 96])   // current keeps its natural, semibold name
        #expect(!layout.scrolls)
        checkConsistent(layout, i)
    }

    @Test func scrollsWhenCompactDoesNotFit() {
        let sites = longTabs(30)
        let i = input(sites, selected: sites[0].pages[0].id)
        let layout = run(i, width: 1200)
        #expect(layout.scrolls)
        #expect(layout.sitesAvailable == E.sitesAvailable(barWidth: 1200, pinCount: 0, metrics: m, measure: measure) - m.overflowReserve)
        // Nothing but the compact cap is applied: no collapsing, no icon-only.
        #expect(layout.sites.allSatisfy { $0.form == .single && $0.pages[0].labelWidth >= 96 })
        checkConsistent(layout, i)
    }

    @Test func exactCompactFitDoesNotScroll() {
        let sites = longTabs(5)
        let i = input(sites, selected: sites[0].pages[0].id)
        let compactWidth = run(i, width: barWidth(forAvailable: 0)).sitesWidth
        #expect(!run(i, width: barWidth(forAvailable: compactWidth)).scrolls)
        #expect(run(i, width: barWidth(forAvailable: compactWidth - 1)).scrolls)
    }

    @Test func twoHundredSitesTerminateQuicklyAndScroll() {
        var sites = (0..<200).map { n in
            site("Site number \(n)", pages: 1 + n % 4, prefix: "a page with a long name ", used: TimeInterval(n * 37 % 199))
        }
        let sel = page("selected", used: 10_000)
        sites.append(site("Now", [sel]))
        let i = input(pins: [pin("a"), pin("b")], sites, selected: sel.id)
        let clock = ContinuousClock()
        var layout = run(i, width: 1200)
        let elapsed = clock.measure { for _ in 0..<20 { layout = run(i, width: 1200) } }
        #expect(elapsed < .seconds(2))
        #expect(layout.scrolls && layout.sites.count == 201)
        #expect(layout.sites.allSatisfy { $0.form != .collapsed })
        checkConsistent(layout, i)
        let roomy = run(i, width: 1_000_000)
        #expect(!roomy.scrolls && collapsedIDs(roomy).isEmpty)
    }

    @Test func degenerateInputsDoNotCrash() {
        let i = input([site("", [page("")]), site("", [page(""), page("")])])
        for width in [CGFloat(-100), 0, 300, 5000] {
            checkConsistent(run(i, width: width), i)
        }
    }
}

// MARK: - Stable positions

/// Left edge of every site, keyed by id, in the sites row.
private func xs(_ layout: BarLayout) -> [SiteID: CGFloat] {
    var x: CGFloat = 0
    var out: [SiteID: CGFloat] = [:]
    for item in layout.sites { out[item.id] = x; x += item.width + m.itemGap }
    return out
}
private func widths(_ layout: BarLayout) -> [SiteID: CGFloat] {
    Dictionary(uniqueKeysWithValues: layout.sites.map { ($0.id, $0.width) })
}

@Suite struct StablePositions {
    private func many(_ n: Int, used: (Int) -> TimeInterval = { _ in 0 }) -> [Site] {
        (0..<n).map { site("S\($0)", [page(String(format: "a fairly long page title %03d", $0), used: used($0))]) }
    }
    private let barW: CGFloat = 1300

    @Test func selectingATabNeverChangesAnyOtherTabsWidth() {
        let sites = many(40, used: { TimeInterval($0 * 13 % 41) })
        let base = run(input(sites, selected: sites[0].pages[0].id), width: barW)
        #expect(base.scrolls)
        for pick in [5, 17, 22, 39] {
            let picked = run(input(sites, selected: sites[pick].pages[0].id), width: barW)
            let a = widths(base), b = widths(picked)
            for s in sites where s.id != sites[0].id && s.id != sites[pick].id {
                #expect(a[s.id] == b[s.id], "selecting \(pick) changed \(s.name)")
            }
        }
    }

    @Test func recencyHasNoEffectOnTheLayout() {
        let sites = many(40)
        var touched = sites
        touched[20].pages[0].usage = Usage(at: t0.addingTimeInterval(99_999))
        let sel = sites[3].pages[0].id
        #expect(run(input(sites, selected: sel), width: barW).sites.map(\.width)
                == run(input(touched, selected: sel), width: barW).sites.map(\.width))
    }

    @Test func selectionOnlyShiftsTabsAfterTheChange() {
        let sites = many(40)
        let a = run(input(sites, selected: sites[10].pages[0].id), width: barW)
        let b = run(input(sites, selected: sites[25].pages[0].id), width: barW)
        let xa = xs(a), xb = xs(b)
        // Left of both selections nothing moves; right of both, everything moves by the same amount.
        for s in sites[0...10] { #expect(xa[s.id] == xb[s.id]) }
        let shift = xb[sites[39].id]! - xa[sites[39].id]!
        for s in sites[26...] { #expect(abs((xb[s.id]! - xa[s.id]!) - shift) < 0.001) }
    }

    @Test func addingATabInTheMiddleOnlyMakesRoomAfterIt() {
        let sites = many(40)
        let sel = sites[0].pages[0].id
        let before = run(input(sites, selected: sel), width: barW)
        var more = sites
        let extra = site("New", [page("brand new tab title")])
        more.insert(extra, at: 20)
        let after = run(input(more, selected: sel), width: barW)
        let xb = xs(before), xa = xs(after)
        let wb = widths(before), wa = widths(after)
        let added = wa[extra.id]! + m.itemGap
        for s in sites {
            #expect(wb[s.id] == wa[s.id])
            let idx = sites.firstIndex { $0.id == s.id }!
            #expect(abs(xa[s.id]! - xb[s.id]! - (idx >= 20 ? added : 0)) < 0.001)
        }
    }

    @Test func closingATabInTheMiddleOnlyClosesTheGap() {
        let sites = many(40)
        let sel = sites[0].pages[0].id
        let before = run(input(sites, selected: sel), width: barW)
        var fewer = sites
        let gone = fewer.remove(at: 20)
        let after = run(input(fewer, selected: sel), width: barW)
        let xb = xs(before), xa = xs(after)
        let gap = widths(before)[gone.id]! + m.itemGap
        for s in fewer {
            let idx = sites.firstIndex { $0.id == s.id }!
            #expect(widths(before)[s.id] == widths(after)[s.id])
            #expect(abs(xb[s.id]! - xa[s.id]! - (idx > 20 ? gap : 0)) < 0.001)
        }
    }

    @Test func resizeKeepsEveryOrderAndWidthOnceCompact() {
        let sites = many(40)
        let i = input(sites, selected: sites[7].pages[0].id)
        let a = run(i, width: 1000), b = run(i, width: 1700)
        #expect(a.scrolls && b.scrolls)
        #expect(a.sites == b.sites)   // the strip is the same, only the window onto it changed
        #expect(b.sitesAvailable > a.sitesAvailable)
    }

    @Test func currentAndSplitPagesAndPinsAreNeverHidden() {
        let sites = many(40)
        let split = SplitPair(leading: sites[30].pages[0].id, trailing: sites[2].pages[0].id)
        let pins = [pin("a"), pin("b"), pin("c")]
        let i = input(pins: pins, sites, selected: sites[30].pages[0].id, split: split)
        for width in stride(from: CGFloat(400), through: 2400, by: 50) {
            let l = run(i, width: width)
            #expect(l.pins.count == 3 && l.pinSlots.count == 3)
            #expect(l.sites[30].pages[0].isCurrent && l.sites[2].pages[0].isCurrent)
            #expect(l.sites.count == 40)
            if l.scrolls { #expect(l.sitesAvailable >= 0) }
        }
    }

    @Test func pinFoldersDoNotChangeTheStripWidths() {
        let sites = many(40)
        let f = PinFolder(name: "Work")
        var p1 = pin("a"), p2 = pin("b")
        p1.folder = f; p2.folder = f
        let sel = sites[0].pages[0].id
        let plain = run(input(pins: [pin("a"), pin("b")], sites, selected: sel), width: barW)
        let grouped = run(input(pins: [p1, p2], sites, selected: sel), width: barW)
        #expect(plain.sites.map(\.width) == grouped.sites.map(\.width))
        #expect(grouped.sitesAvailable > plain.sitesAvailable)   // a folder is one tile
    }
}

// MARK: - Whole-sweep properties

@Suite struct Properties {
    private func scenario() -> BarInput {
        let sel = page("Inbox (3)", used: 900), partner = page("Pull request 4127", used: 800)
        let sites = [
            site("Mail", [sel, page("Calendar", used: 400)]),
            site("Docs", [page("Quarterly planning notes", used: 300)]),
            site("Code", [page("Issues", used: 100), partner, page("Actions", used: 50), page("Settings and members", used: 20)]),
            site("Encyclopedia", [page("Home", used: 5)]),
            site("News", pages: 3, prefix: "Headline number ", used: 200),
            site("Shop", [page("Cart", used: 10), page("A remarkably long product title that goes on", used: 700)], fade: .fading),
            site("Video", [page("Watch later", used: 600, fade: .fading)], kept: true),
        ]
        return input(pins: [pin("chat"), pin("music")], sites, selected: sel.id,
                     split: SplitPair(leading: sel.id, trailing: partner.id))
    }

    @Test func widthsAreConsistentAtEveryBarWidth() {
        let i = scenario()
        for width in stride(from: CGFloat(0), through: 2600, by: 3) {
            let layout = run(i, width: width)
            checkConsistent(layout, i)
            let full = E.sitesAvailable(barWidth: width, pinCount: 2, metrics: m, measure: measure)
            #expect(layout.sitesAvailable == (layout.scrolls ? max(0, full - m.overflowReserve) : full))
            if !layout.scrolls { #expect(layout.sitesWidth <= layout.sitesAvailable + 0.001) }
        }
    }

    @Test func widerBarIsNeverMoreDegraded() {
        let i = scenario()
        var previous = run(i, width: 0)
        for width in stride(from: CGFloat(1), through: 2600, by: 1) {
            let layout = run(i, width: width)
            #expect(!layout.scrolls || previous.scrolls, "width \(width)")
            for (now, before) in zip(layout.sites, previous.sites) {
                #expect(now.form == before.form)
                for (p, q) in zip(now.pages, before.pages) {
                    #expect(p.labelWidth >= q.labelWidth - 0.001, "width \(width)")
                }
            }
            previous = layout
        }
        #expect(previous.sites == run(i, width: 100_000).sites)
    }

    @Test func visibleSitesNeverCollapseAtAnyWidth() {
        let i = scenario()
        for width in stride(from: CGFloat(0), through: 2600, by: 11) {
            let layout = run(i, width: width)
            #expect(layout.sites[0].form == .capsule && layout.sites[2].form == .capsule)
            #expect(layout.sites.flatMap(\.pages).filter(\.isCurrent).count == 2)
            #expect(layout.sites[0].pages[0].splitRole == .leading && layout.sites[2].pages[1].splitRole == .trailing)
        }
    }

    @Test func shortcutsAndFadeAreStableAtAnyWidth() {
        let i = scenario()
        for width in [CGFloat(0), 400, 700, 1000, 3000] {
            let layout = run(i, width: width)
            #expect(layout.pins.map(\.shortcut) == [1, 2])
            #expect(layout.sites[0].pages.map(\.shortcut) == [3, 4])
            #expect(layout.sites[2].pages.map(\.shortcut) == [6, 7, 8, 9])
            #expect(layout.sites[5].fade == .fading && layout.sites[6].isKept)
        }
    }

    @Test func layoutIsDeterministic() {
        let i = scenario()
        for width in [CGFloat(300), 640, 900, 1400] {
            #expect(run(i, width: width) == run(i, width: width))
        }
    }

    @Test func customMetricsAreHonoured() {
        var custom = BarMetrics()
        custom.itemGap = 20; custom.singlePadding = 5; custom.maxLabelWidth = 21
        let i = input([site("A", [page("abcde")]), site("B", [page("ab")])])
        let layout = engine.layout(i, barWidth: 5000, metrics: custom, measure: measure)
        #expect(layout.sites[0].pages[0].labelWidth == 21)
        #expect(layout.sites[0].width == CGFloat(55))
        #expect(layout.sitesWidth == CGFloat(55 + 20 + 48))
    }

    @Test func conformsToTheSharedProtocol() {
        let layouting: any BarLayouting = BarLayoutEngine()
        let layout = layouting.layout(input([site("A", pages: 1)]), barWidth: 800, metrics: .standard, measure: measure)
        #expect(layout.sites.count == 1)
    }
}


// MARK: - Folded sites

private func folded(_ s: Site) -> Site { var s = s; s.isFolded = true; return s }

@Suite struct FoldedSites {
    @Test func aFoldedSiteIsJustIconAndCountEvenWithRoomToSpare() {
        let a = folded(site("a", pages: 5)), b = site("b", pages: 2)
        let i = input([a, b], selected: b.pages[0].id)
        let layout = run(i, width: 100_000)
        checkConsistent(layout, i)
        let item = layout.sites[0]
        #expect(item.form == .collapsed && item.isFolded && item.labelWidth == 0 && item.pageCount == 5 && item.pages.isEmpty)
        #expect(item.width == 12 + 16 + 4 + E.badgeWidth(pageCount: 5, metrics: m, measure: measure) + 12)
        #expect(layout.sites[1].form == .capsule && !layout.sites[1].isFolded)
    }

    @Test func foldingAppliesEvenToTheSiteOfTheSelectedPage() {
        let a = folded(site("a", pages: 3))
        let layout = run(input([a], selected: a.pages[1].id), width: 100_000)
        #expect(layout.sites[0].form == .collapsed && layout.sites[0].isFolded)
    }

    @Test func aSingleOrSplitSiteIgnoresTheFlag() {
        let one = folded(site("one", pages: 1))
        let two = folded(site("two", pages: 2))
        let i = input([one, two], selected: two.pages[0].id, split: SplitPair(leading: two.pages[0].id, trailing: two.pages[1].id))
        let layout = run(i, width: 100_000)
        #expect(layout.sites[0].form == .single && layout.sites[1].form == .capsule)
    }

    @Test func foldedSitesStayFoldedAndOthersNeverCollapseAtAnyWidth() {
        let a = folded(site("a", pages: 3)), b = site("b", pages: 4, used: 10), c = site("c", pages: 4, used: 20)
        let i = input([a, b, c], selected: c.pages[0].id)
        for width in stride(from: CGFloat(0), through: 1400, by: 13) {
            let layout = run(i, width: width)
            checkConsistent(layout, i)
            #expect(layout.sites[0].form == .collapsed && layout.sites[0].isFolded)
            #expect(layout.sites[1].form == .capsule && layout.sites[2].form == .capsule)
        }
    }
}

@Suite struct PinFolderLayoutTests {
    private func inFolder(_ p: PinnedSite, _ f: PinFolder) -> PinnedSite { var p = p; p.folder = f; return p }

    @Test func aFolderIsOnePinTileWide() {
        let f = PinFolder(name: "Work")
        let pins = [pin("a"), inFolder(pin("b"), f), inFolder(pin("c"), f), inFolder(pin("d"), f)]
        let withFolder = run(input(pins: pins, []), width: 1000)
        let two = run(input(pins: [pin("a"), pin("b")], []), width: 1000)
        #expect(withFolder.pinSlots.count == 2)
        #expect(withFolder.pins.count == 4)
        #expect(withFolder.sitesAvailable == two.sitesAvailable)
        guard case .folder(let item) = withFolder.pinSlots[1] else { Issue.record("expected a folder"); return }
        #expect(item.name == "Work" && item.members.count == 3)
    }

    @Test func membersGroupAtTheFirstMemberAndKeepShortcuts() {
        let f = PinFolder(name: "Work")
        let pins = [inFolder(pin("a"), f), pin("b"), inFolder(pin("c"), f)]
        let layout = run(input(pins: pins, []), width: 1000)
        #expect(layout.pins.map(\.name) == ["a", "c", "b"])
        #expect(layout.pins.map(\.shortcut) == [1, 2, 3])
        #expect(layout.pinSlots.count == 2)
    }

    @Test func folderIsCurrentWhenAMemberIs() {
        let f = PinFolder(name: "Work")
        let b = inFolder(pin("b"), f)
        let layout = run(input(pins: [inFolder(pin("a"), f), b], [], selected: b.page.id), width: 1000)
        guard case .folder(let item) = layout.pinSlots[0] else { Issue.record("expected a folder"); return }
        #expect(item.isCurrent)
        #expect(item.members.map(\.isCurrent) == [false, true])
    }
}
