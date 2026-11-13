import Foundation
import Testing
import PlinthModel
@testable import PlinthStore

@MainActor @Suite struct SiteTests {
    @Test func setKeptClearsFade() {
        let r = Rig()
        let w = r.store.createWindow()
        let a = r.open("https://a.com/1", in: w)
        r.open("https://b.com/1", in: w)
        let siteA = r.store.window(w)!.sites[0].id
        r.fader.script = { _, _ in FadeVerdict(pageStages: [a: .fading], siteStages: [siteA: .fading]) }
        r.store.runFade()
        r.fader.script = { _, _ in FadeVerdict() }
        r.store.setKept(siteA, true)
        #expect(r.store.window(w)!.sites[0].isKept)
        #expect(r.store.window(w)!.sites[0].fade == .live)
        #expect(r.store.page(a)?.fade == .live)
        r.store.setKept(siteA, false)
        #expect(!r.store.window(w)!.sites[0].isKept)
        r.ok()
    }

    @Test func moveSiteReordersAndClamps() {
        let r = Rig()
        let w = r.store.createWindow()
        r.open("https://a.com/1", in: w)
        r.open("https://b.com/1", in: w)
        r.open("https://c.com/1", in: w)
        let a = r.store.window(w)!.sites[0].id
        r.store.moveSite(a, toIndex: 2, in: w)
        #expect(r.store.window(w)!.sites.map(\.key.host) == ["b.com", "c.com", "a.com"])
        r.store.moveSite(a, toIndex: -4, in: w)
        #expect(r.store.window(w)!.sites.map(\.key.host) == ["a.com", "b.com", "c.com"])
        r.store.moveSite(a, toIndex: 99, in: w)
        #expect(r.store.window(w)!.sites.map(\.key.host) == ["b.com", "c.com", "a.com"])
        r.store.moveSite(a, toIndex: 1, in: w)
        #expect(r.store.window(w)!.sites.map(\.key.host) == ["b.com", "a.com", "c.com"])
        r.ok()
    }
}

@MainActor @Suite struct PinTests {
    @Test func pinTakesCurrentPageAndLeavesTheRest() {
        let r = Rig()
        let w = r.store.createWindow()
        r.open("https://a.com/1", in: w)
        let a2 = r.open("https://a.com/2", in: w)
        r.open("https://a.com/3", in: w)
        r.store.select(a2, in: w)
        r.store.pin(site: r.store.window(w)!.sites[0].id)
        #expect(r.store.pins.count == 1)
        #expect(r.store.pins[0].page.id == a2)
        #expect(r.store.pins[0].homeURL == u("https://a.com/2"))
        #expect(r.store.pins[0].key == SiteKey("a.com"))
        #expect(r.bar(w) == "a.com[1,3]")
        #expect(r.store.window(w)?.selectedPageID == a2)
        #expect(r.store.page(a2) != nil)
        r.ok()
    }

    @Test func pinningTheSameKeyTwiceIsIgnored() {
        let r = Rig()
        let w = r.store.createWindow()
        r.open("https://a.com/1", in: w)
        r.open("https://a.com/2", in: w)
        r.store.pin(site: r.store.window(w)!.sites[0].id)
        r.store.pin(site: r.store.window(w)!.sites[0].id)
        #expect(r.store.pins.count == 1)
        #expect(r.bar(w) == "a.com[1]")
        r.ok()
    }

    @Test func pinIsSelectableFromEveryWindow() {
        let r = Rig()
        let w1 = r.store.createWindow(), w2 = r.store.createWindow()
        let a = r.open("https://a.com/1", in: w1)
        let b = r.open("https://b.com/1", in: w2)
        let pinSite = r.store.window(w1)!.sites[0].id
        r.store.pin(site: pinSite)
        let pin = r.store.pins[0].id
        r.clock.advance()
        r.store.selectPin(pin, in: w2)
        #expect(r.store.window(w2)?.selectedPageID == a)
        #expect(r.store.pins[0].page.usage.visitCount == 2)
        #expect(r.store.windowID(containing: a) == w1)
        r.store.select(b, in: w2)
        #expect(r.store.window(w2)?.selectedPageID == b)
        r.ok()
    }

    @Test func pinPageAcceptsAnyURL() {
        let r = Rig()
        let w = r.store.createWindow()
        let a = r.open("https://a.com/1", in: w)
        r.store.pin(site: r.store.window(w)!.sites[0].id)
        r.store.pageDidUpdate(a, url: u("https://login.other.com/sso"), title: "Sign in", siteNameHint: "Other")
        #expect(r.store.pins[0].page.url == u("https://login.other.com/sso"))
        #expect(r.store.pins[0].key == SiteKey("a.com"))
        #expect(r.store.pins[0].name == "A")
        #expect(r.store.pins[0].page.name == "Sign in")
        #expect(r.store.window(w)?.sites.isEmpty == true)
        r.ok()
    }

    @Test func resetPinNavigatesHome() {
        let r = Rig()
        let w = r.store.createWindow()
        let a = r.open("https://a.com/home", in: w)
        r.store.pin(site: r.store.window(w)!.sites[0].id)
        r.store.pageDidUpdate(a, url: u("https://a.com/deep/inside"), title: nil, siteNameHint: nil)
        r.log.clear()
        r.store.resetPin(r.store.pins[0].id)
        #expect(r.log.events == [.navigate(a, u("https://a.com/home"))])
        r.ok()
    }

    @Test func unpinRoundTrip() {
        let r = Rig()
        let w = r.store.createWindow()
        r.open("https://b.com/1", in: w)
        let a = r.open("https://a.com/1", in: w)
        r.store.pin(site: r.store.window(w)!.sites[1].id)
        #expect(r.bar(w) == "b.com[1]")
        r.store.unpin(r.store.pins[0].id, into: w)
        #expect(r.store.pins.isEmpty)
        #expect(r.bar(w) == "a.com[1] b.com[1]")
        #expect(r.store.window(w)?.selectedPageID == a)
        #expect(r.store.window(w)?.site(containing: a)?.name == "A")
        r.ok()
    }

    @Test func unpinJoinsTheExistingSite() {
        let r = Rig()
        let w = r.store.createWindow()
        r.open("https://a.com/1", in: w)
        let a2 = r.open("https://a.com/2", in: w)
        r.store.pin(site: r.store.window(w)!.sites[0].id)
        r.store.unpin(r.store.pins[0].id, into: w)
        #expect(r.bar(w) == "a.com[1,2]")
        #expect(r.store.window(w)?.selectedPageID == a2)
        r.ok()
    }

    @Test func unpinFixesOtherWindowsShowingThePin() {
        let r = Rig()
        let w1 = r.store.createWindow(), w2 = r.store.createWindow(), w3 = r.store.createWindow()
        r.open("https://a.com/1", in: w1)
        let b = r.open("https://b.com/1", in: w2)
        r.store.pin(site: r.store.window(w1)!.sites[0].id)
        let pin = r.store.pins[0].id
        r.store.selectPin(pin, in: w2)
        r.store.selectPin(pin, in: w3)
        r.log.clear()
        r.store.unpin(pin, into: w1)
        #expect(r.store.window(w2)?.selectedPageID == b)
        #expect(r.store.window(w3)?.selectedPageID == nil)
        #expect(r.log.events.contains(.selectionChanged(w2)))
        #expect(r.log.events.contains(.selectionChanged(w3)))
        r.ok()
    }

    @Test func pinningHalfOfASplitEndsIt() {
        let r = Rig()
        let w = r.store.createWindow()
        let a = r.open("https://a.com/1", in: w)
        let b = r.open("https://b.com/1", in: w)
        r.store.split(a, with: b, in: w)
        r.store.pin(site: r.store.window(w)!.sites[0].id)
        #expect(r.store.window(w)?.split == nil)
        r.ok()
    }
}

@MainActor @Suite struct SplitTests {
    @Test func splitShowsBothAndKeepsFocus() {
        let r = Rig()
        let w = r.store.createWindow()
        let a = r.open("https://a.com/1", in: w)
        let b = r.open("https://b.com/1", in: w)
        r.log.clear()
        r.store.split(b, with: a, in: w)
        let state = r.store.window(w)!
        #expect(state.split == SplitPair(leading: b, trailing: a))
        #expect(state.selectedPageID == b)
        #expect(state.visiblePageIDs == [a, b])
        #expect(r.log.events == [.selectionChanged(w)])
        r.ok()
    }

    @Test func splitFromOutsideFocusesLeading() {
        let r = Rig()
        let w = r.store.createWindow()
        let a = r.open("https://a.com/1", in: w)
        let b = r.open("https://b.com/1", in: w)
        r.open("https://c.com/1", in: w)
        r.store.split(a, with: b, in: w)
        #expect(r.store.window(w)?.selectedPageID == a)
        r.ok()
    }

    @Test func selectingPartnerMovesFocusAndKeepsSplit() {
        let r = Rig()
        let w = r.store.createWindow()
        let a = r.open("https://a.com/1", in: w)
        let b = r.open("https://b.com/1", in: w)
        r.store.split(a, with: b, in: w)
        r.store.select(a, in: w)
        #expect(r.store.window(w)?.selectedPageID == a)
        #expect(r.store.window(w)?.split != nil)
        #expect(r.store.window(w)?.visiblePageIDs == [a, b])
        r.ok()
    }

    @Test func selectingOutsideHidesButKeepsSplit() {
        let r = Rig()
        let w = r.store.createWindow()
        let a = r.open("https://a.com/1", in: w)
        let b = r.open("https://b.com/1", in: w)
        let c = r.open("https://c.com/1", in: w)
        r.store.split(a, with: b, in: w)
        r.store.select(c, in: w)
        #expect(r.store.window(w)?.split != nil)
        #expect(r.store.window(w)?.visiblePageIDs == [c])
        r.store.select(b, in: w)
        #expect(r.store.window(w)?.visiblePageIDs == [a, b])
        r.ok()
    }

    @Test func closingEitherPageEndsSplitAndFocusesPartner() {
        let r = Rig()
        let w = r.store.createWindow()
        let a = r.open("https://a.com/1", in: w)
        let b = r.open("https://b.com/1", in: w)
        r.open("https://c.com/1", in: w)
        r.store.split(a, with: b, in: w)
        r.store.select(a, in: w)
        r.store.closePage(a)
        #expect(r.store.window(w)?.split == nil)
        #expect(r.store.window(w)?.selectedPageID == b)
        r.ok()
    }

    @Test func closingUnfocusedHalfEndsSplitAndTellsTheShell() {
        let r = Rig()
        let w = r.store.createWindow()
        let a = r.open("https://a.com/1", in: w)
        let b = r.open("https://b.com/1", in: w)
        r.store.split(a, with: b, in: w)
        r.store.select(a, in: w)
        r.log.clear()
        r.store.closePage(b)
        #expect(r.store.window(w)?.split == nil)
        #expect(r.store.window(w)?.selectedPageID == a)
        #expect(r.log.events == [.pageClosed(b), .selectionChanged(w)])
        r.ok()
    }

    @Test func endSplitAndFraction() {
        let r = Rig()
        let w = r.store.createWindow()
        let a = r.open("https://a.com/1", in: w)
        let b = r.open("https://b.com/1", in: w)
        r.store.setSplitFraction(0.7, in: w)
        #expect(r.store.window(w)?.split == nil)
        r.store.split(a, with: b, in: w)
        r.store.setSplitFraction(0.95, in: w)
        #expect(r.store.window(w)?.split?.fraction == 0.8)
        r.store.setSplitFraction(0.05, in: w)
        #expect(r.store.window(w)?.split?.fraction == 0.2)
        r.store.setSplitFraction(0.4, in: w)
        #expect(r.store.window(w)?.split?.fraction == 0.4)
        r.store.endSplit(in: w)
        #expect(r.store.window(w)?.split == nil)
        r.ok()
    }

    @Test func invalidSplitsAreIgnored() {
        let r = Rig()
        let w = r.store.createWindow(), w2 = r.store.createWindow()
        let a = r.open("https://a.com/1", in: w)
        let other = r.open("https://b.com/1", in: w2)
        r.store.split(a, with: a, in: w)
        r.store.split(a, with: other, in: w)
        r.store.split(a, with: PageID(), in: w)
        #expect(r.store.window(w)?.split == nil)
        r.ok()
    }
}

@MainActor @Suite struct FadeTests {
    @Test func runFadePassesEachWindowItsOwnState() {
        let r = Rig()
        let w1 = r.store.createWindow(), w2 = r.store.createWindow()
        let a = r.open("https://a.com/1", in: w1)
        let b = r.open("https://b.com/1", in: w2)
        let c = r.open("https://c.com/1", in: w2)
        r.store.split(b, with: c, in: w2)
        r.clock.advance()
        r.store.runFade()
        #expect(r.fader.calls.count == 2)
        #expect(r.fader.calls[0].sites.map(\.key.host) == ["a.com"])
        #expect(r.fader.calls[0].visible == [a])
        #expect(r.fader.calls[1].visible == [b, c])
        #expect(r.fader.calls[0].now == r.clock.t)
        #expect(Set(r.fader.calls[0].stats.keys) == [SiteKey("a.com"), SiteKey("b.com"), SiteKey("c.com")])
    }

    @Test func runFadeReturnsEarliestNextCheck() {
        let r = Rig()
        let w1 = r.store.createWindow(), w2 = r.store.createWindow()
        r.open("https://a.com/1", in: w1)
        r.open("https://b.com/1", in: w2)
        let soon = r.clock.t + 100, later = r.clock.t + 900
        r.fader.script = { sites, _ in FadeVerdict(nextCheck: sites[0].key.host == "a.com" ? later : soon) }
        #expect(r.store.runFade() == soon)
        r.fader.script = { _, _ in FadeVerdict() }
        #expect(r.store.runFade() == nil)
    }

    @Test func stagesAreApplied() {
        let r = Rig()
        let w = r.store.createWindow()
        let a1 = r.open("https://a.com/1", in: w)
        let a2 = r.open("https://a.com/2", in: w)
        r.open("https://b.com/1", in: w)
        let siteA = r.store.window(w)!.sites[0].id
        r.fader.script = { _, _ in FadeVerdict(pageStages: [a1: .fading], siteStages: [siteA: .fading]) }
        r.store.runFade()
        #expect(r.store.page(a1)?.fade == .fading)
        #expect(r.store.page(a2)?.fade == .live)
        #expect(r.store.window(w)!.sites[0].fade == .fading)
        r.fader.script = { _, _ in FadeVerdict(pageStages: [a1: .live], siteStages: [siteA: .live]) }
        r.store.runFade()
        #expect(r.store.page(a1)?.fade == .live)
        #expect(r.store.window(w)!.sites[0].fade == .live)
        r.ok()
    }

    @Test func pagesAndSitesDropOntoTheShelf() {
        let r = Rig()
        let w = r.store.createWindow()
        let a1 = r.open("https://a.com/1", in: w)
        let a2 = r.open("https://a.com/2", in: w)
        let b = r.open("https://b.com/1", in: w)
        let c = r.open("https://c.com/1", in: w)
        r.store.pageDidScroll(a1, y: 77)
        let siteB = r.store.window(w)!.sites[1].id
        r.fader.script = { _, _ in FadeVerdict(pagesToShelve: [a1], sitesToShelve: [siteB]) }
        r.log.clear()
        r.clock.advance()
        r.store.runFade()
        #expect(r.bar(w) == "a.com[2] c.com[1]")
        #expect(r.store.shelf.map(\.key.host) == ["a.com", "b.com"])
        #expect(r.store.shelf[0].pages.map(\.id) == [a1])
        #expect(r.store.shelf[0].pages[0].scrollY == 77)
        #expect(r.store.shelf[0].shelvedAt == r.clock.t)
        #expect(r.store.shelf[1].pages.map(\.id) == [b])
        #expect(r.log.events == [.pagesShelved([b], key: SiteKey("b.com")), .pagesShelved([a1], key: SiteKey("a.com"))])
        #expect(r.store.window(w)?.selectedPageID == c)
        #expect(r.store.page(a1) == nil)
        _ = a2
        r.ok()
    }

    @Test func laterFadesMergeIntoTheSameEntryAndMoveItToTheFront() {
        let r = Rig()
        let w = r.store.createWindow()
        let a1 = r.open("https://a.com/1", in: w)
        let a2 = r.open("https://a.com/2", in: w)
        let b = r.open("https://b.com/1", in: w)
        r.open("https://c.com/1", in: w)
        r.fader.script = { _, _ in FadeVerdict(pagesToShelve: [a1]) }
        r.store.runFade()
        let first = r.store.shelf[0]
        r.clock.advance(500)
        r.fader.script = { _, _ in FadeVerdict(pagesToShelve: [b]) }
        r.store.runFade()
        #expect(r.store.shelf.map(\.key.host) == ["b.com", "a.com"])
        r.clock.advance(500)
        r.fader.script = { _, _ in FadeVerdict(pagesToShelve: [a2]) }
        r.store.runFade()
        #expect(r.store.shelf.map(\.key.host) == ["a.com", "b.com"])
        #expect(r.store.shelf[0].id == first.id)
        #expect(r.store.shelf[0].pages.map(\.id) == [a2, a1])
        #expect(r.store.shelf[0].shelvedAt == r.clock.t)
        #expect(r.store.shelf[0].shelvedAt > first.shelvedAt)
        r.ok()
    }

    @Test func shelvingEveryPageOfASiteRemovesTheSite() {
        let r = Rig()
        let w = r.store.createWindow()
        let a1 = r.open("https://a.com/1", in: w)
        let a2 = r.open("https://a.com/2", in: w)
        r.open("https://b.com/1", in: w)
        r.fader.script = { _, _ in FadeVerdict(pagesToShelve: [a2, a1]) }
        r.log.clear()
        r.store.runFade()
        #expect(r.bar(w) == "b.com[1]")
        #expect(r.log.events == [.pagesShelved([a1, a2], key: SiteKey("a.com"))])
        r.ok()
    }

    @Test func visiblePagesAreNeverShelved() {
        let r = Rig()
        let w = r.store.createWindow()
        let a = r.open("https://a.com/1", in: w)
        let b = r.open("https://b.com/1", in: w)
        let c = r.open("https://c.com/1", in: w)
        r.store.split(b, with: c, in: w)
        let sites = r.store.window(w)!.sites.map(\.id)
        r.fader.script = { _, _ in FadeVerdict(pagesToShelve: [a, b, c], sitesToShelve: sites) }
        r.store.runFade()
        #expect(r.bar(w) == "b.com[1] c.com[1]")
        #expect(r.store.window(w)?.split != nil)
        r.ok()
    }

    @Test func shelvingAHiddenSplitPageEndsTheSplit() {
        let r = Rig()
        let w = r.store.createWindow()
        let a = r.open("https://a.com/1", in: w)
        let b = r.open("https://b.com/1", in: w)
        let c = r.open("https://c.com/1", in: w)
        r.store.split(a, with: b, in: w)
        r.store.select(c, in: w)
        r.fader.script = { _, _ in FadeVerdict(pagesToShelve: [a]) }
        r.store.runFade()
        #expect(r.store.window(w)?.split == nil)
        #expect(r.store.window(w)?.selectedPageID == c)
        r.ok()
    }

    @Test func staleVerdictIDsAreIgnored() {
        let r = Rig()
        let w = r.store.createWindow()
        r.open("https://a.com/1", in: w)
        r.fader.script = { _, _ in
            FadeVerdict(pageStages: [PageID(): .fading], siteStages: [SiteID(): .fading],
                        pagesToShelve: [PageID()], sitesToShelve: [SiteID()])
        }
        r.log.clear()
        r.store.runFade()
        #expect(r.store.shelf.isEmpty)
        #expect(r.log.events.isEmpty)
        r.ok()
    }

    @Test func manualShelveOfCurrentSiteMovesSelection() {
        let r = Rig()
        let w = r.store.createWindow()
        let a = r.open("https://a.com/1", in: w)
        let b1 = r.open("https://b.com/1", in: w)
        let b2 = r.open("https://b.com/2", in: w)
        r.log.clear()
        r.store.shelve(site: r.store.window(w)!.sites[1].id)
        #expect(r.bar(w) == "a.com[1]")
        #expect(r.store.window(w)?.selectedPageID == a)
        #expect(r.log.events == [.pagesShelved([b1, b2], key: SiteKey("b.com")), .selectionChanged(w)])
        r.ok()
    }

    @Test func siteStatsOutliveTheSite() {
        let r = Rig()
        let w = r.store.createWindow()
        let a = r.open("https://a.com/1", in: w)
        r.store.closePage(a)
        #expect(r.store.siteStats[SiteKey("a.com")]?.visitCount == 1)
        r.open("https://a.com/2", in: w)
        #expect(r.store.siteStats[SiteKey("a.com")]?.visitCount == 2)
        r.ok()
    }
}

@MainActor @Suite struct ShelfTests {
    @Test func restoreOnePage() {
        let r = Rig()
        let w = r.store.createWindow()
        let a1 = r.open("https://a.com/1", in: w)
        let a2 = r.open("https://a.com/2", in: w)
        r.open("https://b.com/1", in: w)
        r.store.pageDidScroll(a1, y: 55)
        r.fader.script = { _, _ in FadeVerdict(pageStages: [a1: .fading, a2: .fading]) }
        r.store.runFade()
        r.store.shelve(site: r.store.window(w)!.sites[0].id)
        let entry = r.store.shelf[0].id
        r.log.clear()
        let ids = r.store.restore(entry: entry, page: a1, into: w)
        #expect(ids == [a1])
        #expect(r.bar(w) == "b.com[1] a.com[1]")
        #expect(r.store.page(a1)?.fade == .live)
        #expect(r.store.page(a1)?.scrollY == 55)
        #expect(r.store.window(w)?.selectedPageID == a1)
        #expect(r.store.shelf[0].pages.map(\.id) == [a2])
        #expect(r.log.events == [.pagesRestored([a1], window: w), .selectionChanged(w)])
        r.ok()
    }

    @Test func restoreWholeEntrySelectsMostRecentlyUsed() {
        let r = Rig()
        let w = r.store.createWindow()
        let a1 = r.open("https://a.com/1", in: w)
        let a2 = r.open("https://a.com/2", in: w)
        r.open("https://b.com/1", in: w)
        r.clock.advance(); r.store.select(a1, in: w)
        r.store.shelve(site: r.store.window(w)!.sites[0].id)
        let w2 = r.store.createWindow()
        let ids = r.store.restore(entry: r.store.shelf[0].id, page: nil, into: w2)
        #expect(ids == [a1, a2])
        #expect(r.store.shelf.isEmpty)
        #expect(r.bar(w2) == "a.com[1,2]")
        #expect(r.store.window(w2)?.selectedPageID == a1)
        r.ok()
    }

    @Test func restoreJoinsTheSiteAlreadyOnTheBar() {
        let r = Rig()
        let w = r.store.createWindow()
        let a1 = r.open("https://a.com/1", in: w)
        r.open("https://a.com/2", in: w)
        r.fader.script = { _, _ in FadeVerdict(pagesToShelve: [a1]) }
        r.store.runFade()
        r.store.restore(entry: r.store.shelf[0].id, page: nil, into: w)
        #expect(r.bar(w) == "a.com[2,1]")
        #expect(r.store.window(w)!.sites.count == 1)
        r.ok()
    }

    @Test func restoreWithUnknownIDsReturnsNothing() {
        let r = Rig()
        let w = r.store.createWindow()
        r.open("https://a.com/1", in: w)
        r.open("https://b.com/1", in: w)
        r.store.shelve(site: r.store.window(w)!.sites[0].id)
        #expect(r.store.restore(entry: SiteID(), page: nil, into: w).isEmpty)
        #expect(r.store.restore(entry: r.store.shelf[0].id, page: PageID(), into: w).isEmpty)
        #expect(r.store.restore(entry: r.store.shelf[0].id, page: nil, into: WindowID()).isEmpty)
        #expect(r.store.shelf.count == 1)
        r.ok()
    }

    @Test func removeFromShelf() {
        let r = Rig()
        let w = r.store.createWindow()
        let a1 = r.open("https://a.com/1", in: w)
        let a2 = r.open("https://a.com/2", in: w)
        r.open("https://b.com/1", in: w)
        r.store.shelve(site: r.store.window(w)!.sites[0].id)
        let entry = r.store.shelf[0].id
        r.log.clear()
        r.store.removeFromShelf(entry: entry, page: a1)
        #expect(r.store.shelf[0].pages.map(\.id) == [a2])
        #expect(r.log.events == [.pageClosed(a1)])
        r.store.removeFromShelf(entry: entry, page: nil)
        #expect(r.store.shelf.isEmpty)
        #expect(r.store.reopenClosedPage(in: w) == nil)
        r.ok()
    }

    @Test func shelvedPagesCanStillBeRenamedAndRetitled() {
        let r = Rig()
        let w = r.store.createWindow()
        let a = r.open("https://a.com/1", in: w)
        r.open("https://b.com/1", in: w)
        r.store.shelve(site: r.store.window(w)!.sites[0].id)
        r.store.pageDidUpdate(a, url: u("https://elsewhere.com/"), title: "Late title", siteNameHint: nil)
        #expect(r.store.shelf[0].pages[0].name == "Late title")
        #expect(r.store.shelf[0].pages[0].url == u("https://a.com/1"))
        r.store.rename(a, to: "Kept name")
        #expect(r.store.shelf[0].pages[0].name == "Kept name")
        r.ok()
    }
}

@MainActor @Suite struct HistoryTests {
    @Test func openingRecordsAVisit() {
        let r = Rig()
        let w = r.store.createWindow()
        r.open("https://a.com/1", in: w)
        #expect(r.store.history.count == 1)
        #expect(r.store.history[0].url == u("https://a.com/1"))
        #expect(r.store.history[0].key == SiteKey("a.com"))
        #expect(r.store.history[0].visitedAt == r.clock.t)
    }

    @Test func repeatedUpdatesForOneURLAreOneEntryAndTitleArrivesLater() {
        let r = Rig()
        let w = r.store.createWindow()
        let a = r.open("https://a.com/1", in: w)
        r.store.pageDidUpdate(a, url: u("https://a.com/1"), title: nil, siteNameHint: nil)
        r.store.pageDidUpdate(a, url: u("https://a.com/1"), title: "First - A", siteNameHint: nil)
        r.store.pageDidUpdate(a, url: u("https://a.com/1"), title: "First - A", siteNameHint: nil)
        #expect(r.store.history.count == 1)
        #expect(r.store.history[0].title == "First - A")
        #expect(r.store.history[0].name == "First")
    }

    @Test func eachNewURLIsANewEntryNewestFirst() {
        let r = Rig()
        let w = r.store.createWindow()
        let a = r.open("https://a.com/1", in: w)
        r.store.pageDidUpdate(a, url: nil, title: "One", siteNameHint: nil)
        r.clock.advance()
        r.store.pageDidUpdate(a, url: u("https://a.com/2"), title: nil, siteNameHint: nil)
        #expect(r.store.history.map(\.url) == [u("https://a.com/2"), u("https://a.com/1")])
        #expect(r.store.history[0].title == "")
        r.store.pageDidUpdate(a, url: nil, title: "Two", siteNameHint: nil)
        #expect(r.store.history.map(\.title) == ["Two", "One"])
        r.store.recordDwell(a, seconds: 31)
        #expect(r.store.history.map(\.dwell) == [31, 0])
    }

    @Test func blankPagesStayOutOfHistory() {
        let r = Rig()
        let w = r.store.createWindow()
        let a = r.open("about:blank", in: w)
        #expect(r.store.history.isEmpty)
        r.store.pageDidUpdate(a, url: u("https://a.com/1"), title: nil, siteNameHint: nil)
        #expect(r.store.history.count == 1)
        #expect(r.bar(w) == "a.com[1]")
        r.ok()
    }

    @Test func historyIsCapped() {
        let r = Rig()
        let w = r.store.createWindow()
        let a = r.open("https://a.com/0", in: w)
        for i in 1...(BrowserStore.historyCap + 25) {
            r.store.pageDidUpdate(a, url: u("https://a.com/\(i)"), title: nil, siteNameHint: nil)
        }
        #expect(r.store.history.count == BrowserStore.historyCap)
        #expect(r.store.history.first?.url == u("https://a.com/\(BrowserStore.historyCap + 25)"))
        r.ok()
    }
}
