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

    @Test func shortcutsDoNotChangeWhenSitesCollapse() {
        let sel = page("selected", used: 100)
        let i = input([site("Old", pages: 3, prefix: "a long page name ", used: 1), site("Now", [sel, page("other", used: 100)])],
                      selected: sel.id)
        let wide = run(i, width: 5000), narrow = run(i, width: barWidth(forAvailable: 300))
        #expect(narrow.sites[0].form == .collapsed)
        #expect(wide.sites[1].pages.map(\.shortcut) == [4, 5])
        #expect(narrow.sites[1].pages.map(\.shortcut) == [4, 5])
    }
}

// MARK: - Stage 2: collapsing

@Suite struct Collapsing {
    /// Three three-page capsules of 10-character names: each 10+16+4 + 3·(2+70+20) + 2 = 308.
    private func three(selected: Int? = nil) -> (BarInput, [Site]) {
        let sites = [site("Alpha", pages: 3, prefix: "alphapage", used: 30),
                     site("Beta", pages: 3, prefix: "betaapage", used: 10),
                     site("Gamma", pages: 3, prefix: "gammapage", used: 20)]
        return (input(sites, selected: selected.map { sites[$0].pages[0].id }), sites)
    }

    @Test func collapsedWidthArithmetic() {
        let (i, sites) = three()
        #expect(run(i, width: 5000).sitesWidth == CGFloat(3 * 308 + 16))
        let layout = run(i, width: barWidth(forAvailable: 939))
        let beta = layout.sites[1]
        #expect(beta.form == .collapsed && beta.id == sites[1].id)
        #expect(beta.pages.isEmpty && beta.pageCount == 3)
        #expect(beta.labelWidth == 28)
        #expect(E.badgeWidth(pageCount: 3, metrics: m, measure: measure) == 16)
        #expect(beta.width == 96) // 12 + 16 + 8 + 28 + 4 + 16 + 12
        checkConsistent(layout, i)
    }

    @Test func wideBadgeForLargeCounts() {
        // "123" = 21 + 2·4
        #expect(E.badgeWidth(pageCount: 123, metrics: m, measure: measure) == 29)
        #expect(E.countText(12) == "12")
    }

    @Test func leastRecentlyUsedCollapsesFirst() {
        let (i, sites) = three()
        // One point short: only Beta (used at 10) goes.
        let one = run(i, width: barWidth(forAvailable: 939))
        #expect(collapsedIDs(one) == [sites[1].id])
        #expect(!one.scrolls)
        // 96 + 308 + 308 + 16 = 728; one point short of that: Gamma (20) goes next.
        let two = run(i, width: barWidth(forAvailable: 727))
        #expect(collapsedIDs(two) == [sites[1].id, sites[2].id])
        let three = run(i, width: barWidth(forAvailable: 515))
        #expect(collapsedIDs(three) == Set(sites.map(\.id)))
        // Labels are untouched while collapsing alone is enough.
        #expect(two.sites[0].pages.allSatisfy { $0.labelWidth == 70 })
        #expect(three.sites.allSatisfy { $0.labelWidth == CGFloat($0.name.count) * 7 })
    }

    @Test func collapsingStopsAsSoonAsItFits() {
        let (i, _) = three()
        #expect(collapsedIDs(run(i, width: barWidth(forAvailable: 728))).count == 1)
        #expect(collapsedIDs(run(i, width: barWidth(forAvailable: 940))).isEmpty)
    }

    @Test func lastUsedIsTheMostRecentPageOfTheSite() {
        // A has one very old page but one fresh page; B is uniformly middling. B goes first.
        let a = site("Aaaa", [page("old page name", used: 1), page("new page name", used: 500)])
        let b = site("Bbbb", [page("mid page name", used: 100), page("mid page two.", used: 100)])
        let i = input([a, b])
        let natural = run(i, width: 5000).sitesWidth
        #expect(collapsedIDs(run(i, width: barWidth(forAvailable: natural - 1))) == [b.id])
    }

    @Test func tiesCollapseLeftmostFirst() {
        let a = site("Aaaa", pages: 3, used: 5), b = site("Bbbb", pages: 3, used: 5)
        let i = input([a, b])
        let natural = run(i, width: 5000).sitesWidth
        #expect(collapsedIDs(run(i, width: barWidth(forAvailable: natural - 1))) == [a.id])
    }

    @Test func siteWithSelectedPageNeverCollapses() {
        // Beta is the least recently used but holds the selected page.
        let (i, sites) = three(selected: 1)
        for available in stride(from: CGFloat(0), through: 1000, by: 13) {
            let layout = run(i, width: barWidth(forAvailable: available))
            #expect(layout.sites[1].form == .capsule)
            #expect(layout.sites[1].pages[0].isCurrent)
            checkConsistent(layout, i)
        }
        let layout = run(i, width: barWidth(forAvailable: 900))
        #expect(collapsedIDs(layout) == [sites[2].id])
    }

    @Test func splitPartnerSiteNeverCollapses() {
        let (base, sites) = three()
        let split = SplitPair(leading: sites[0].pages[0].id, trailing: sites[1].pages[2].id)
        let i = input(base.sites, selected: sites[0].pages[0].id, split: split)
        for available in stride(from: CGFloat(0), through: 1000, by: 17) {
            let layout = run(i, width: barWidth(forAvailable: available))
            #expect(layout.sites[0].form == .capsule && layout.sites[1].form == .capsule)
            #expect(layout.sites[1].pages[2].isCurrent && layout.sites[1].pages[2].splitRole == .trailing)
        }
        #expect(run(i, width: barWidth(forAvailable: 0)).sites[2].form == .collapsed)
    }

    @Test func singleCollapsesOnlyWhenItSavesWidth() {
        // "Docs" is shorter than its page name: collapsing saves. "Encyclopedia" is longer than "Home": it does not.
        let saves = site("Docs", [page("Quarterly planning notes", used: 1)])
        let noSave = site("Encyclopedia", [page("Home", used: 2)])
        let i = input([saves, noSave])
        let layout = run(i, width: barWidth(forAvailable: 200))
        #expect(layout.sites[0].form == .collapsed)
        #expect(layout.sites[0].pageCount == 1 && layout.sites[0].labelWidth == 28)
        #expect(layout.sites[0].width == 76) // 12 + 16 + 8 + 28 + 12, no count
        #expect(layout.sites[1].form == .single)
        #expect(!layout.scrolls)
        // However narrow the bar gets, the single that cannot save width stays a single.
        #expect(run(i, width: 0).sites[1].form == .single)
        checkConsistent(layout, i)
    }

    @Test func unhelpfulCollapseIsSkippedAndTheNextSiteIsTried() {
        // The least recently used site would not get narrower; the next one must still collapse.
        let stubborn = site("Encyclopedia", [page("Home", used: 1)])
        let capsule = site("Wiki", pages: 3, prefix: "long article ", used: 2)
        let i = input([stubborn, capsule])
        let natural = run(i, width: 5000).sitesWidth
        let layout = run(i, width: barWidth(forAvailable: natural - 1))
        #expect(layout.sites.map(\.form) == [.single, .collapsed])
        #expect(!layout.scrolls)
    }

    @Test func capsuleWithShortPagesAndLongNameIsLeftAlone() {
        // Capsule: 32 + 2·(2 + 7 + 20) = 90. Collapsed would be 12+16+8+180+4+16+12 = 248.
        let i = input([site(String(repeating: "N", count: 40), [page("a"), page("b")])])
        let layout = run(i, width: barWidth(forAvailable: 60))
        #expect(layout.sites[0].form == .capsule)
        #expect(layout.scrolls)
    }

    @Test func returnsToFullerFormWhenThereIsRoomAgain() {
        let (i, _) = three()
        let wide = run(i, width: 5000)
        let narrow = run(i, width: barWidth(forAvailable: 300))
        #expect(narrow != wide)
        #expect(run(i, width: 5000) == wide)
        #expect(collapsedIDs(run(i, width: barWidth(forAvailable: 940))).isEmpty)
    }
}

// MARK: - Stage 3: shortening

@Suite struct Shortening {
    @Test func levelCutsLongestFirst() {
        // Cutting 30 from [100, 80, 40]: the 100 comes down to 80, then both to 75.
        #expect(E.level(for: [100, 80, 40], reduceBy: 30, floor: 36) == 75)
        #expect(E.level(for: [100, 80, 40], reduceBy: 10, floor: 36) == 90)
        #expect(E.level(for: [100, 80, 40], reduceBy: 0, floor: 36) == .infinity)
        #expect(E.level(for: [100, 80, 40], reduceBy: 1000, floor: 36) == 36)
        #expect(E.level(for: [100, 80, 40], reduceBy: 112, floor: 36) == 36)
        #expect(E.level(for: [], reduceBy: 5, floor: 36) == 36)
    }

    @Test func nonCurrentLabelsShrinkBeforeTheCurrentOne() {
        let cur = page("current page name") // 17 chars: 127.5 semibold
        let other = page("another page name") // 17 chars: 119
        let i = input([site("S", [cur, other])], selected: cur.id)
        // natural: 32 + (2 + 28 + 127.5) + (2 + 20 + 119) = 330.5
        #expect(run(i, width: 5000).sitesWidth == 330.5)
        let layout = run(i, width: barWidth(forAvailable: 300.5))
        #expect(layout.sites[0].pages[0].labelWidth == 127.5)
        #expect(layout.sites[0].pages[1].labelWidth == 89)
        #expect(layout.sitesWidth == 300.5 && !layout.scrolls)
        checkConsistent(layout, i)
    }

    @Test func currentLabelShrinksOnceOthersAreAtMinimum() {
        let cur = page("current page name"), other = page("another page name")
        let i = input([site("S", [cur, other])], selected: cur.id)
        // other at 36 → 247.5; ask for 20 less.
        let layout = run(i, width: barWidth(forAvailable: 227.5))
        #expect(layout.sites[0].pages[1].labelWidth == 36)
        #expect(layout.sites[0].pages[0].labelWidth == 107.5)
        #expect(!layout.scrolls)
    }

    @Test func shortLabelsAreNotStretchedOrCut() {
        // "ab" is 14 pt, already under the minimum: it stays 14 while the long one shrinks.
        let i = input([site("S", [page("ab"), page("a very long page name here")])], selected: nil)
        let wide = run(i, width: 5000)
        let layout = run(i, width: barWidth(forAvailable: wide.sitesWidth - 50))
        // The only candidate is protected by nothing, so it collapses first; pin it open with a selection instead.
        _ = layout
        let sel = input(i.sites, selected: i.sites[0].pages[0].id)
        let natural = run(sel, width: 5000)
        let cut = run(sel, width: barWidth(forAvailable: natural.sitesWidth - 50))
        #expect(cut.sites[0].pages[0].labelWidth == natural.sites[0].pages[0].labelWidth)
        #expect(cut.sites[0].pages[1].labelWidth == natural.sites[0].pages[1].labelWidth - 50)
        let tiny = run(sel, width: 0)
        #expect(tiny.sites[0].pages[0].labelWidth == 15) // "ab" semibold, never raised to the minimum
        #expect(tiny.sites[0].pages[1].labelWidth == 36)
    }

    @Test func labelsShrinkFairlyLongestFirst() {
        let sel = page("x")
        let i = input([site("S", [sel, page(String(repeating: "a", count: 20)), page(String(repeating: "b", count: 10))])],
                      selected: sel.id)
        let natural = run(i, width: 5000).sitesWidth
        // 140 and 70: removing 40 only touches the long one.
        var layout = run(i, width: barWidth(forAvailable: natural - 40))
        #expect(layout.sites[0].pages.map(\.labelWidth) == [7.5, 100, 70])
        // Removing 100: both end level at 55.
        layout = run(i, width: barWidth(forAvailable: natural - 100))
        #expect(layout.sites[0].pages.map(\.labelWidth) == [7.5, 55, 55])
    }

    @Test func collapsedNamesShrinkAlongsidePageNames() {
        let sel = page("selected page name here", used: 50)
        let other = site("A very long site name", pages: 2, prefix: "some long page name ", used: 1)
        let i = input([other, site("Now", [sel])], selected: sel.id)
        // Collapsed: 12+16+8+147+4+16+12 = 215. Single: 48 + 172.5 = 220.5. Total 443.5.
        let collapsed = run(i, width: barWidth(forAvailable: 443.5))
        #expect(collapsed.sites[0].form == .collapsed && collapsed.sites[0].labelWidth == 147)
        let layout = run(i, width: barWidth(forAvailable: 400))
        #expect(layout.sites[0].labelWidth == 103.5)
        #expect(layout.sites[1].pages[0].labelWidth == 172.5) // current: untouched so far
        #expect(!layout.scrolls)
        checkConsistent(layout, i)
    }

    @Test func iconOnlyIsTheLastResort() {
        let sel = page("selected page name here", used: 50)
        let other = site("A very long site name", pages: 2, prefix: "some long page name ", used: 1)
        let i = input([other, site("Now", [sel])], selected: sel.id)
        // Everything at minimum: collapsed 12+16+8+36+4+16+12 = 104, single 48 + 36 = 84, gap 8 → 196.
        let atMinimum = run(i, width: barWidth(forAvailable: 196))
        #expect(atMinimum.sites[0].labelWidth == 36)
        #expect(atMinimum.sites[1].pages[0].labelWidth == 36)
        #expect(!atMinimum.scrolls)
        // One point less: the collapsed site drops its name. 12 + 16 + 4 + 16 + 12 = 60.
        let iconOnly = run(i, width: barWidth(forAvailable: 195))
        #expect(iconOnly.sites[0].form == .collapsed && iconOnly.sites[0].labelWidth == 0)
        #expect(iconOnly.sites[0].width == 60)
        #expect(iconOnly.sites[0].pageCount == 2)
        #expect(!iconOnly.scrolls)
        checkConsistent(iconOnly, i)
    }

    @Test func iconOnlyGoesLeastRecentlyUsedFirst() {
        let sel = page("x", used: 99)
        let a = site("Alphabet", pages: 2, prefix: "long page name ", used: 2)
        let b = site("Betamaxx", pages: 2, prefix: "long page name ", used: 1)
        let i = input([a, b, site("Now", [sel])], selected: sel.id)
        // Minimum with names: 104 + 104 + (48 + 7.5) + 16 = 279.5
        let layout = run(i, width: barWidth(forAvailable: 279))
        #expect(layout.sites[0].labelWidth == 36)
        #expect(layout.sites[1].labelWidth == 0)
        #expect(!layout.scrolls)
    }

    @Test func collapsedSingleCanGoIconOnlyWithoutACount() {
        let sel = page("x", used: 99)
        let i = input([site("Docs", [page("Quarterly planning notes", used: 1)]), site("Now", [sel])], selected: sel.id)
        let layout = run(i, width: 0)
        #expect(layout.sites[0].form == .collapsed && layout.sites[0].labelWidth == 0)
        #expect(layout.sites[0].width == 40) // 12 + 16 + 12
    }
}

// MARK: - Stage 4: scrolling

@Suite struct Scrolling {
    @Test func scrollsOnlyWhenEverythingIsAtMinimum() {
        let sel = page("selected page name here", used: 50)
        let other = site("A very long site name", pages: 2, prefix: "some long page name ", used: 1)
        let i = input([other, site("Now", [sel])], selected: sel.id)
        // Minimum: 60 + 8 + 84 = 152.
        let fits = run(i, width: barWidth(forAvailable: 152))
        #expect(!fits.scrolls && fits.sitesWidth == 152)
        let scrolls = run(i, width: barWidth(forAvailable: 151))
        #expect(scrolls.scrolls && scrolls.sitesWidth == 152)
        #expect(scrolls.sites[0].labelWidth == 0)
        #expect(scrolls.sites[1].pages[0].labelWidth == 36)
        checkConsistent(scrolls, i)
    }

    @Test func stagesHappenInOrderAsTheBarNarrows() {
        let sel = page("the selected page", used: 99)
        let sites = [site("Reference", pages: 3, prefix: "reference page ", used: 1),
                     site("Journal", pages: 2, prefix: "journal entry ", used: 2),
                     site("Now", [sel, page("a sibling page", used: 99)])]
        let i = input(sites, selected: sel.id)
        /// 0 natural, 1 collapsing, 2 shortening, 3 icon-only, 4 scrolling.
        func stage(_ l: BarLayout) -> Int {
            let natural = run(i, width: 9000)
            if l.scrolls { return 4 }
            if l.sites.contains(where: { $0.form == .collapsed && $0.labelWidth == 0 }) { return 3 }
            let shortened = zip(l.sites, natural.sites).contains { a, b in
                a.form == .collapsed ? a.labelWidth < CGFloat(a.name.count) * 7 : zip(a.pages, b.pages).contains { $0.labelWidth < $1.labelWidth }
            }
            if shortened { return 2 }
            return collapsedIDs(l).isEmpty ? 0 : 1
        }
        var seen: [Int] = []
        for width in stride(from: CGFloat(1500), through: 100, by: -1) {
            let s = stage(run(i, width: width))
            if seen.last != s { seen.append(s) }
        }
        #expect(seen == [0, 1, 2, 3, 4])
    }

    @Test func twoHundredSitesTerminateQuicklyAndScroll() {
        let sel = page("selected", used: 10_000)
        var sites = (0..<200).map { n in
            site("Site number \(n)", pages: 1 + n % 4, prefix: "a page with a long name ", used: TimeInterval(n * 37 % 199))
        }
        sites.append(site("Now", [sel]))
        let i = input(pins: [pin("a"), pin("b")], sites, selected: sel.id)
        let clock = ContinuousClock()
        var layout = run(i, width: 1200)
        let elapsed = clock.measure { for _ in 0..<20 { layout = run(i, width: 1200) } }
        #expect(elapsed < .seconds(2))
        #expect(layout.scrolls)
        #expect(layout.sites.count == 201)
        #expect(layout.sites.dropLast().allSatisfy { $0.form == .collapsed && $0.labelWidth == 0 })
        #expect(layout.sites.last?.form == .single)
        #expect(layout.sites.last?.pages[0].labelWidth == 36)
        checkConsistent(layout, i)
        // And with unlimited room it is all back.
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
            #expect(layout.sitesAvailable == E.sitesAvailable(barWidth: width, pinCount: 2, metrics: m, measure: measure))
            if !layout.scrolls { #expect(layout.sitesWidth <= layout.sitesAvailable + 0.001) }
        }
    }

    @Test func widerBarIsNeverMoreDegraded() {
        let i = scenario()
        var previous = run(i, width: 0)
        for width in stride(from: CGFloat(1), through: 2600, by: 1) {
            let layout = run(i, width: width)
            #expect(collapsedIDs(layout).isSubset(of: collapsedIDs(previous)), "width \(width)")
            #expect(!layout.scrolls || previous.scrolls, "width \(width)")
            for (now, before) in zip(layout.sites, previous.sites) {
                if now.form == .collapsed {
                    #expect(now.labelWidth >= before.labelWidth - 0.001, "width \(width)")
                } else if before.form != .collapsed {
                    for (p, q) in zip(now.pages, before.pages) {
                        #expect(p.labelWidth >= q.labelWidth - 0.001, "width \(width)")
                    }
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

    @Test func overflowCollapseLeavesFoldedSitesAloneAndStillCollapsesOthers() {
        let a = folded(site("a", pages: 3)), b = site("b", pages: 4, used: 10), c = site("c", pages: 4, used: 20)
        let i = input([a, b, c], selected: c.pages[0].id)
        for width in stride(from: CGFloat(0), through: 1400, by: 13) {
            let layout = run(i, width: width)
            checkConsistent(layout, i)
            #expect(layout.sites[0].form == .collapsed && layout.sites[0].isFolded && layout.sites[0].labelWidth == 0)
            #expect(!layout.sites[1].isFolded && !layout.sites[2].isFolded)
        }
        // Tight enough for b to collapse for room: that one is not "folded".
        let tight = run(i, width: barWidth(forAvailable: 330))
        #expect(tight.sites[1].form == .collapsed && !tight.sites[1].isFolded)
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
