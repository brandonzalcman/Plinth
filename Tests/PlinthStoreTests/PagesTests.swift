import Foundation
import Testing
import PlinthModel
@testable import PlinthStore

@MainActor @Suite struct WindowTests {
    @Test func emptyStoreHasNoWindows() {
        let r = Rig()
        #expect(r.store.windows.isEmpty)
        #expect(r.store.pins.isEmpty && r.store.shelf.isEmpty && r.store.history.isEmpty)
        r.ok()
    }

    @Test func createWindowIsEmptyAndUnselected() {
        let r = Rig()
        let w = r.store.createWindow()
        #expect(r.store.window(w)?.sites.isEmpty == true)
        #expect(r.store.window(w)?.selectedPageID == nil)
        #expect(r.store.window(WindowID()) == nil)
        r.ok()
    }

    @Test func setFrameStoresFrame() {
        let r = Rig()
        let w = r.store.createWindow()
        r.store.setFrame([10, 20, 800, 600], for: w)
        #expect(r.store.window(w)?.frame == [10, 20, 800, 600])
        r.ok()
    }

    @Test func closeWindowShelvesItsSites() {
        let r = Rig()
        let w = r.store.createWindow()
        let a1 = r.open("https://a.com/1", in: w)
        let a2 = r.open("https://a.com/2", in: w)
        let b = r.open("https://b.com/", in: w)
        r.log.clear()
        r.store.closeWindow(w)
        #expect(r.store.windows.isEmpty)
        #expect(r.store.shelf.count == 2)
        #expect(Set(r.store.shelf.flatMap { $0.pages.map(\.id) }) == [a1, a2, b])
        #expect(r.log.events.contains(.pagesShelved([a1, a2], key: SiteKey("a.com"))))
        #expect(r.log.events.contains(.pagesShelved([b], key: SiteKey("b.com"))))
        #expect(!r.log.events.contains { if case .pageClosed = $0 { true } else { false } })
        r.ok()
    }

    @Test func windowsAreIndependent() {
        let r = Rig()
        let w1 = r.store.createWindow(), w2 = r.store.createWindow()
        let p1 = r.open("https://a.com/1", in: w1)
        let p2 = r.open("https://a.com/2", in: w2)
        #expect(r.store.window(w1)?.sites.count == 1)
        #expect(r.store.window(w2)?.sites.count == 1)
        #expect(r.store.windowID(containing: p1) == w1)
        #expect(r.store.windowID(containing: p2) == w2)
        #expect(r.store.windowID(containing: PageID()) == nil)
        r.ok()
    }
}

@MainActor @Suite struct GroupingTests {
    @Test func samePagesOfOneSiteShareASite() {
        let r = Rig()
        let w = r.store.createWindow()
        r.open("https://a.com/one", in: w)
        r.open("https://b.com/two", in: w)
        r.open("https://www.a.com/three", in: w)
        #expect(r.bar(w) == "a.com[one,three] b.com[two]")
        r.ok()
    }

    @Test func newSiteGoesToTheEnd() {
        let r = Rig()
        let w = r.store.createWindow()
        r.open("https://a.com/1", in: w)
        r.open("https://b.com/1", in: w)
        r.open("https://c.com/1", in: w)
        #expect(r.store.window(w)!.sites.map(\.key.host) == ["a.com", "b.com", "c.com"])
        r.ok()
    }

    @Test func siteNameComesFromIdentityThenHint() {
        let r = Rig()
        let w = r.store.createWindow()
        let p = r.open("https://example.com/seats", in: w)
        #expect(r.store.window(w)!.sites[0].name == "Example")
        r.store.pageDidUpdate(p, url: nil, title: "Seat map - Example Air", siteNameHint: "Example Air")
        #expect(r.store.window(w)!.sites[0].name == "Example Air")
        #expect(r.store.page(p)?.name == "Seat map")
        r.ok()
    }

    @Test func hintRenamesEveryPageOfTheSite() {
        let r = Rig()
        let w = r.store.createWindow()
        let p1 = r.open("https://example.com/a", in: w)
        let p2 = r.open("https://example.com/b", in: w)
        r.store.pageDidUpdate(p1, url: nil, title: "Seats - Example Air", siteNameHint: nil)
        #expect(r.store.page(p1)?.name == "Seats - Example Air")
        r.store.pageDidUpdate(p2, url: nil, title: "Bags - Example Air", siteNameHint: "Example Air")
        #expect(r.store.page(p1)?.name == "Seats")
        #expect(r.store.page(p2)?.name == "Bags")
        r.ok()
    }

    @Test func blankHintIsIgnored() {
        let r = Rig()
        let w = r.store.createWindow()
        let p = r.open("https://example.com/a", in: w)
        r.store.pageDidUpdate(p, url: nil, title: nil, siteNameHint: "   ")
        #expect(r.store.window(w)!.sites[0].name == "Example")
        r.ok()
    }

    @Test func openEmitsOpenedThenSelection() {
        let r = Rig()
        let w = r.store.createWindow()
        let p = r.open("https://a.com/1", in: w)
        #expect(r.log.events == [.pageOpened(p, window: w), .selectionChanged(w)])
        #expect(r.store.window(w)?.selectedPageID == p)
    }

    @Test func backgroundOpenKeepsSelection() {
        let r = Rig()
        let w = r.store.createWindow()
        let p1 = r.open("https://a.com/1", in: w)
        r.log.clear()
        let p2 = r.open("https://b.com/1", in: w, select: false)
        #expect(r.store.window(w)?.selectedPageID == p1)
        #expect(r.log.events == [.pageOpened(p2, window: w)])
        #expect(r.store.siteStats[SiteKey("b.com")] != nil)
        r.ok()
    }

    @Test func backgroundOpenIntoEmptyWindowIsSelected() {
        let r = Rig()
        let w = r.store.createWindow()
        let p = r.open("https://a.com/1", in: w, select: false)
        #expect(r.store.window(w)?.selectedPageID == p)
        r.ok()
    }

    @Test func openIntoUnknownWindowDoesNothing() {
        let r = Rig()
        let p = r.store.openPage(url: u("https://a.com/"), in: WindowID())
        #expect(r.store.page(p) == nil)
        #expect(r.log.events.isEmpty)
        r.ok()
    }
}

@MainActor @Suite struct OpenerTests {
    @Test func sameSiteOpensRightAfterOpener() {
        let r = Rig()
        let w = r.store.createWindow()
        let a1 = r.open("https://a.com/1", in: w)
        r.open("https://a.com/2", in: w)
        r.open("https://a.com/3", in: w, opener: a1)
        #expect(r.bar(w) == "a.com[1,3,2]")
        r.ok()
    }

    @Test func newSiteOpensRightAfterOpenersSite() {
        let r = Rig()
        let w = r.store.createWindow()
        let a = r.open("https://a.com/1", in: w)
        r.open("https://b.com/1", in: w)
        r.open("https://c.com/1", in: w, opener: a)
        #expect(r.store.window(w)!.sites.map(\.key.host) == ["a.com", "c.com", "b.com"])
        r.ok()
    }

    @Test func existingOtherSiteAppends() {
        let r = Rig()
        let w = r.store.createWindow()
        let a = r.open("https://a.com/1", in: w)
        r.open("https://b.com/1", in: w)
        r.open("https://c.com/1", in: w)
        r.open("https://b.com/2", in: w, opener: a)
        #expect(r.bar(w) == "a.com[1] b.com[1,2] c.com[1]")
        r.ok()
    }

    @Test func unknownOpenerFallsBackToEnd() {
        let r = Rig()
        let w = r.store.createWindow()
        r.open("https://a.com/1", in: w)
        r.open("https://b.com/1", in: w, opener: PageID())
        #expect(r.store.window(w)!.sites.map(\.key.host) == ["a.com", "b.com"])
        r.ok()
    }
}

@MainActor @Suite struct NavigationTests {
    @Test func crossSiteNavigationOfOnlyPageReplacesSiteInPlace() {
        let r = Rig()
        let w = r.store.createWindow()
        r.open("https://a.com/1", in: w)
        let b = r.open("https://b.com/1", in: w)
        r.open("https://c.com/1", in: w)
        r.store.pageDidUpdate(b, url: u("https://d.com/x"), title: nil, siteNameHint: nil)
        #expect(r.store.window(w)!.sites.map(\.key.host) == ["a.com", "d.com", "c.com"])
        #expect(r.store.window(w)?.selectedPageID != nil)
        r.ok()
    }

    @Test func crossSiteNavigationFromCapsuleLandsRightAfterIt() {
        let r = Rig()
        let w = r.store.createWindow()
        let a1 = r.open("https://a.com/1", in: w)
        r.open("https://a.com/2", in: w)
        r.open("https://c.com/1", in: w)
        r.store.pageDidUpdate(a1, url: u("https://d.com/x"), title: nil, siteNameHint: nil)
        #expect(r.bar(w) == "a.com[2] d.com[x] c.com[1]")
        r.ok()
    }

    @Test func crossSiteNavigationJoinsExistingSite() {
        let r = Rig()
        let w = r.store.createWindow()
        let a = r.open("https://a.com/1", in: w)
        r.open("https://b.com/1", in: w)
        r.store.pageDidUpdate(a, url: u("https://b.com/2"), title: nil, siteNameHint: nil)
        #expect(r.bar(w) == "b.com[1,2]")
        r.ok()
    }

    @Test func selectionAndSplitFollowAMovedPage() {
        let r = Rig()
        let w = r.store.createWindow()
        let a = r.open("https://a.com/1", in: w)
        let b = r.open("https://b.com/1", in: w)
        r.store.split(a, with: b, in: w)
        r.store.select(a, in: w)
        r.store.pageDidUpdate(a, url: u("https://z.com/1"), title: nil, siteNameHint: nil)
        let state = r.store.window(w)!
        #expect(state.selectedPageID == a)
        #expect(state.split?.leading == a && state.split?.trailing == b)
        #expect(state.site(containing: a)?.key == SiteKey("z.com"))
        #expect(state.site(containing: a)?.currentPageID == a)
        r.ok()
    }

    @Test func movedSelectedPageCountsAsAVisitToTheNewSite() {
        let r = Rig()
        let w = r.store.createWindow()
        let a = r.open("https://a.com/1", in: w)
        r.store.pageDidUpdate(a, url: u("https://z.com/1"), title: nil, siteNameHint: nil)
        #expect(r.store.siteStats[SiteKey("z.com")]?.visitCount == 1)
        r.store.pageDidUpdate(a, url: u("https://a.com/2"), title: nil, siteNameHint: nil)
        #expect(r.store.siteStats[SiteKey("a.com")]?.visitCount == 2)
        r.ok()
    }

    @Test func leavingASiteFixesItsCurrentPage() {
        let r = Rig()
        let w = r.store.createWindow()
        r.open("https://a.com/1", in: w)
        let a2 = r.open("https://a.com/2", in: w)
        r.store.pageDidUpdate(a2, url: u("https://z.com/1"), title: nil, siteNameHint: nil)
        r.ok()
        #expect(r.store.window(w)!.sites[0].pages.count == 1)
    }

    @Test func sameSiteNavigationStaysPut() {
        let r = Rig()
        let w = r.store.createWindow()
        let a = r.open("https://a.com/1", in: w)
        r.open("https://b.com/1", in: w)
        r.store.pageDidUpdate(a, url: u("https://www.a.com/other"), title: "Other", siteNameHint: nil)
        #expect(r.bar(w) == "a.com[Other] b.com[1]")
        #expect(r.store.page(a)?.url == u("https://www.a.com/other"))
        r.ok()
    }

    @Test func navigateOnlyEmits() {
        let r = Rig()
        let w = r.store.createWindow()
        let a = r.open("https://a.com/1", in: w)
        r.log.clear()
        r.store.navigate(a, to: u("https://b.com/"))
        #expect(r.log.events == [.navigate(a, u("https://b.com/"))])
        #expect(r.store.page(a)?.url == u("https://a.com/1"))
        r.store.navigate(PageID(), to: u("https://b.com/"))
        #expect(r.log.events.count == 1)
        r.ok()
    }

    @Test func titleRenamesAndCustomNameWins() {
        let r = Rig()
        let w = r.store.createWindow()
        let a = r.open("https://a.com/doc", in: w)
        #expect(r.store.page(a)?.name == "doc")
        r.store.pageDidUpdate(a, url: nil, title: "Quarterly plan - A", siteNameHint: nil)
        #expect(r.store.page(a)?.name == "Quarterly plan")
        r.store.rename(a, to: "  Plan  ")
        #expect(r.store.page(a)?.name == "Plan")
        r.store.pageDidUpdate(a, url: nil, title: "Something else", siteNameHint: nil)
        #expect(r.store.page(a)?.name == "Plan")
        r.store.rename(a, to: "")
        #expect(r.store.page(a)?.customName == nil)
        #expect(r.store.page(a)?.name == "Something else")
        r.ok()
    }

    @Test func scrollAndDwellAreRecorded() {
        let r = Rig()
        let w = r.store.createWindow()
        let a = r.open("https://a.com/doc", in: w)
        r.store.pageDidScroll(a, y: 420)
        r.store.recordDwell(a, seconds: 12)
        r.store.recordDwell(a, seconds: 30)
        r.store.recordDwell(a, seconds: -5)
        #expect(r.store.page(a)?.scrollY == 420)
        #expect(r.store.page(a)?.dwell == 42)
        #expect(r.store.history.first?.dwell == 42)
        r.ok()
    }
}

@MainActor @Suite struct SelectionTests {
    @Test func selectRecordsAVisitAndClearsFade() {
        let r = Rig()
        let w = r.store.createWindow()
        let a = r.open("https://a.com/1", in: w)
        let b = r.open("https://b.com/1", in: w)
        let siteA = r.store.window(w)!.sites[0].id
        r.fader.script = { _, _ in FadeVerdict(pageStages: [a: .fading], siteStages: [siteA: .fading]) }
        r.store.runFade()
        #expect(r.store.page(a)?.fade == .fading)
        #expect(r.store.window(w)!.sites[0].fade == .fading)
        r.clock.advance(86_400 * 2)
        r.log.clear()
        r.store.select(a, in: w)
        #expect(r.store.page(a)?.fade == .live)
        #expect(r.store.window(w)!.sites[0].fade == .live)
        #expect(r.store.page(a)?.usage.visitCount == 2)
        #expect(r.store.page(a)?.usage.activeDays == 2)
        #expect(r.store.page(a)?.usage.lastUsed == r.clock.t)
        #expect(r.store.siteStats[SiteKey("a.com")]?.visitCount == 2)
        #expect(r.store.page(b)?.usage.visitCount == 1)
        #expect(r.log.events == [.selectionChanged(w)])
        r.ok()
    }

    @Test func reselectingTheSelectedPageDoesNothing() {
        let r = Rig()
        let w = r.store.createWindow()
        let a = r.open("https://a.com/1", in: w)
        r.log.clear()
        r.store.select(a, in: w)
        #expect(r.log.events.isEmpty)
        #expect(r.store.page(a)?.usage.visitCount == 1)
    }

    @Test func selectIgnoresPagesOfOtherWindows() {
        let r = Rig()
        let w1 = r.store.createWindow(), w2 = r.store.createWindow()
        let a = r.open("https://a.com/1", in: w1)
        let b = r.open("https://b.com/1", in: w2)
        r.store.select(b, in: w1)
        #expect(r.store.window(w1)?.selectedPageID == a)
        r.ok()
    }

    @Test func selectSiteSelectsItsCurrentPage() {
        let r = Rig()
        let w = r.store.createWindow()
        let a1 = r.open("https://a.com/1", in: w)
        r.open("https://a.com/2", in: w)
        r.store.select(a1, in: w)
        r.open("https://b.com/1", in: w)
        let siteA = r.store.window(w)!.sites[0].id
        r.store.selectSite(siteA, in: w)
        #expect(r.store.window(w)?.selectedPageID == a1)
        r.ok()
    }

    @Test func shortcutCountsPinsFirst() {
        let r = Rig()
        let w = r.store.createWindow()
        let a = r.open("https://a.com/1", in: w)
        let b1 = r.open("https://b.com/1", in: w)
        let b2 = r.open("https://b.com/2", in: w)
        r.store.pin(site: r.store.window(w)!.sites[0].id)
        r.store.selectByShortcut(2, in: w)
        #expect(r.store.window(w)?.selectedPageID == b1)
        r.store.selectByShortcut(1, in: w)
        #expect(r.store.window(w)?.selectedPageID == a)
        r.store.selectByShortcut(3, in: w)
        #expect(r.store.window(w)?.selectedPageID == b2)
        r.store.selectByShortcut(9, in: w)
        r.store.selectByShortcut(0, in: w)
        #expect(r.store.window(w)?.selectedPageID == b2)
        r.ok()
    }

    @Test func adjacentWrapsBothWays() {
        let r = Rig()
        let w = r.store.createWindow()
        let a = r.open("https://a.com/1", in: w)
        let b = r.open("https://b.com/1", in: w)
        let c = r.open("https://c.com/1", in: w)
        r.store.selectAdjacent(offset: 1, in: w)
        #expect(r.store.window(w)?.selectedPageID == a)
        r.store.selectAdjacent(offset: -1, in: w)
        #expect(r.store.window(w)?.selectedPageID == c)
        r.store.selectAdjacent(offset: -1, in: w)
        #expect(r.store.window(w)?.selectedPageID == b)
        r.ok()
    }
}

@MainActor @Suite struct CloseTests {
    @Test func closeGoesToHistoryNotShelf() {
        let r = Rig()
        let w = r.store.createWindow()
        let a = r.open("https://a.com/1", in: w)
        r.log.clear()
        r.store.closePage(a)
        #expect(r.store.shelf.isEmpty)
        #expect(r.store.history.map(\.url) == [u("https://a.com/1")])
        #expect(r.log.events == [.pageClosed(a), .selectionChanged(w)])
        #expect(r.store.window(w)?.sites.isEmpty == true)
        #expect(r.store.window(w)?.selectedPageID == nil)
        #expect(r.store.page(a) == nil)
        r.ok()
    }

    @Test func closingSelectedPrefersSameSiteNeighbour() {
        let r = Rig()
        let w = r.store.createWindow()
        r.open("https://a.com/1", in: w)
        let b1 = r.open("https://b.com/1", in: w)
        let b2 = r.open("https://b.com/2", in: w)
        let b3 = r.open("https://b.com/3", in: w)
        r.open("https://c.com/1", in: w)
        r.store.select(b2, in: w)
        r.store.closePage(b2)
        #expect(r.store.window(w)?.selectedPageID == b3)
        r.store.closePage(b3)
        #expect(r.store.window(w)?.selectedPageID == b1)
        r.ok()
    }

    @Test func closingLastPageOfSiteSelectsMostRecentlyUsed() {
        let r = Rig()
        let w = r.store.createWindow()
        let a = r.open("https://a.com/1", in: w)
        let b = r.open("https://b.com/1", in: w)
        let c = r.open("https://c.com/1", in: w)
        r.clock.advance(); r.store.select(a, in: w)
        r.clock.advance(); r.store.select(c, in: w)
        r.store.closePage(c)
        #expect(r.store.window(w)?.selectedPageID == a)
        r.store.closePage(a)
        #expect(r.store.window(w)?.selectedPageID == b)
        r.ok()
    }

    @Test func closingUnselectedPageKeepsSelection() {
        let r = Rig()
        let w = r.store.createWindow()
        let a = r.open("https://a.com/1", in: w)
        let b = r.open("https://b.com/1", in: w)
        r.log.clear()
        r.store.closePage(a)
        #expect(r.store.window(w)?.selectedPageID == b)
        #expect(r.log.events == [.pageClosed(a)])
        r.ok()
    }

    @Test func reopenRestoresOldPositionInOldSite() {
        let r = Rig()
        let w = r.store.createWindow()
        r.open("https://a.com/1", in: w)
        let a2 = r.open("https://a.com/2", in: w)
        r.open("https://a.com/3", in: w)
        r.store.closePage(a2)
        #expect(r.bar(w) == "a.com[1,3]")
        r.log.clear()
        let back = r.store.reopenClosedPage(in: w)
        #expect(back == a2)
        #expect(r.bar(w) == "a.com[1,2,3]")
        #expect(r.store.window(w)?.selectedPageID == a2)
        #expect(r.log.events == [.pageOpened(a2, window: w), .navigate(a2, u("https://a.com/2")), .selectionChanged(w)])
        r.ok()
    }

    @Test func reopenWhenSiteIsGoneMakesANewSite() {
        let r = Rig()
        let w = r.store.createWindow()
        let a = r.open("https://a.com/1", in: w)
        r.open("https://b.com/1", in: w)
        r.store.closePage(a)
        #expect(r.store.reopenClosedPage(in: w) == a)
        #expect(r.bar(w) == "b.com[1] a.com[1]")
        r.ok()
    }

    @Test func reopenIsLastInFirstOutAndKeepsPageState() {
        let r = Rig()
        let w = r.store.createWindow()
        let a = r.open("https://a.com/1", in: w)
        let b = r.open("https://b.com/1", in: w)
        r.store.pageDidScroll(a, y: 300)
        r.store.rename(a, to: "Mine")
        r.store.closePage(a)
        r.store.closePage(b)
        #expect(r.store.reopenClosedPage(in: w) == b)
        #expect(r.store.reopenClosedPage(in: w) == a)
        #expect(r.store.reopenClosedPage(in: w) == nil)
        #expect(r.store.page(a)?.scrollY == 300)
        #expect(r.store.page(a)?.name == "Mine")
        r.ok()
    }

    @Test func closedStackIsCappedAtFifty() {
        let r = Rig()
        let w = r.store.createWindow()
        for i in 0..<60 {
            let p = r.open("https://a.com/\(i)", in: w)
            r.store.closePage(p)
        }
        #expect(r.store.closed.count == 50)
        #expect(r.store.closed.first?.page.url == u("https://a.com/10"))
        r.ok()
    }

    @Test func closeSiteClosesEveryPage() {
        let r = Rig()
        let w = r.store.createWindow()
        let b = r.open("https://b.com/1", in: w)
        let a1 = r.open("https://a.com/1", in: w)
        let a2 = r.open("https://a.com/2", in: w)
        r.log.clear()
        r.store.closeSite(r.store.window(w)!.sites[1].id)
        #expect(r.bar(w) == "b.com[1]")
        #expect(r.store.window(w)?.selectedPageID == b)
        #expect(r.log.events == [.pageClosed(a1), .pageClosed(a2), .selectionChanged(w)])
        #expect(r.store.shelf.isEmpty)
        #expect(r.store.reopenClosedPage(in: w) == a2)
        r.ok()
    }

    @Test func closingAPinPageIsIgnored() {
        let r = Rig()
        let w = r.store.createWindow()
        let a = r.open("https://a.com/1", in: w)
        r.store.pin(site: r.store.window(w)!.sites[0].id)
        r.store.closePage(a)
        #expect(r.store.pins.count == 1)
        r.ok()
    }
}
