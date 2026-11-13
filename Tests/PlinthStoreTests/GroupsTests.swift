import Foundation
import Testing
import PlinthModel
@testable import PlinthStore

@MainActor func tick(_ r: Rig, minutes: Int) {
    for _ in 0..<minutes { r.store.noteCoOpen(seconds: 60) }
}

@MainActor @Suite struct MovePageTests {
    @Test func reordersInsideItsSiteAndClamps() {
        let r = Rig()
        let w = r.store.createWindow()
        let p1 = r.open("https://a.com/p1", in: w)
        r.open("https://a.com/p2", in: w)
        let p3 = r.open("https://a.com/p3", in: w)
        r.open("https://b.com/x", in: w)
        r.store.movePage(p3, toIndex: 0)
        #expect(r.bar(w) == "a.com[p3,p1,p2] b.com[x]")
        r.store.movePage(p3, toIndex: 99)
        #expect(r.bar(w) == "a.com[p1,p2,p3] b.com[x]")
        r.store.movePage(p1, toIndex: -5)
        #expect(r.bar(w) == "a.com[p1,p2,p3] b.com[x]")
        r.store.movePage(p1, toIndex: 1)
        #expect(r.bar(w) == "a.com[p2,p1,p3] b.com[x]")
        r.ok()
    }

    @Test func unknownPagesAndPinsAreIgnored() {
        let r = Rig()
        let w = r.store.createWindow()
        r.open("https://a.com/1", in: w)
        r.store.pin(site: r.store.window(w)!.sites[0].id)
        r.open("https://b.com/1", in: w)
        let before = r.store.windows
        r.store.movePage(r.store.pins[0].page.id, toIndex: 0)
        r.store.movePage(PageID(), toIndex: 0)
        #expect(r.store.windows == before)
        r.ok()
    }
}

@MainActor @Suite struct CoOpenTests {
    @Test func accumulatesPairsOnEachBarButNotPins() {
        let r = Rig()
        let w = r.store.createWindow()
        r.open("https://pin.com/1", in: w)
        r.store.pin(site: r.store.window(w)!.sites[0].id)
        r.open("https://a.com/1", in: w)
        r.open("https://b.com/1", in: w)
        r.open("https://a.com/2", in: w)
        r.store.noteCoOpen(seconds: 5)
        r.store.noteCoOpen(seconds: 5)
        #expect(r.store.coOpenTime(SiteKey("a.com"), SiteKey("b.com")) == 10)
        #expect(r.store.coOpenTime(SiteKey("b.com"), SiteKey("a.com")) == 10)
        #expect(r.store.coOpenTime(SiteKey("pin.com"), SiteKey("a.com")) == 0)
        #expect(r.store.coOpen.count == 1)
    }

    @Test func aPairCountsOncePerTickAndTicksAreCapped() {
        let r = Rig()
        for _ in 0..<2 {
            let w = r.store.createWindow()
            r.open("https://a.com/1", in: w)
            r.open("https://b.com/1", in: w)
        }
        r.store.noteCoOpen(seconds: 3)
        #expect(r.store.coOpenTime(SiteKey("a.com"), SiteKey("b.com")) == 3)
        r.store.noteCoOpen(seconds: 3600)
        #expect(r.store.coOpenTime(SiteKey("a.com"), SiteKey("b.com")) == 3 + BrowserStore.coOpenMaxTick)
        r.store.noteCoOpen(seconds: -1)
        r.store.noteCoOpen(seconds: .nan)
        r.store.noteCoOpen(seconds: .infinity)
        #expect(r.store.coOpenTime(SiteKey("a.com"), SiteKey("b.com")) == 3 + BrowserStore.coOpenMaxTick)
    }

    @Test func idlePairsHalveEveryFourteenDaysAndAreForgotten() {
        let r = Rig()
        let w = r.store.createWindow()
        r.open("https://a.com/1", in: w)
        let b = r.open("https://b.com/1", in: w)
        tick(r, minutes: 20)
        r.store.closePage(b)
        r.clock.advance(BrowserStore.coOpenDecayInterval - 10)
        r.store.noteCoOpen(seconds: 1)
        #expect(r.store.coOpenTime(SiteKey("a.com"), SiteKey("b.com")) == 1200)
        r.clock.advance(20)
        r.store.noteCoOpen(seconds: 1)
        #expect(r.store.coOpenTime(SiteKey("a.com"), SiteKey("b.com")) == 600)
        r.clock.advance(BrowserStore.coOpenDecayInterval * 2)
        r.store.noteCoOpen(seconds: 1)
        #expect(r.store.coOpenTime(SiteKey("a.com"), SiteKey("b.com")) == 150)
        r.clock.advance(BrowserStore.coOpenDecayInterval * 2)
        r.store.noteCoOpen(seconds: 1)
        #expect(r.store.coOpenTime(SiteKey("a.com"), SiteKey("b.com")) == 0) // 37.5 s: under the minimum
        #expect(r.store.coOpen.isEmpty)
    }

    @Test func tableIsCapped() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = Rig(dir: dir)
        let w = r.store.createWindow()
        for i in 0..<40 { r.open("https://s\(i).com/1", in: w) } // 780 pairs
        r.store.noteCoOpen(seconds: 1)
        #expect(r.store.coOpen.count == BrowserStore.coOpenPairCap)
        r.ok()
        try r.store.save()
        let snapshot = try StoreSnapshot.decode(Data(contentsOf: dir.appendingPathComponent("state.json")))
        #expect(snapshot.coOpen?.count == BrowserStore.coOpenPairCap)
    }
}

@MainActor @Suite struct GroupSuggestionTests {
    /// a, b, c open together for `minutes`, then d opened.
    func rig(minutes: Int = 20) -> (Rig, WindowID) {
        let r = Rig()
        let w = r.store.createWindow()
        r.open("https://c.com/1", in: w)
        r.open("https://a.com/1", in: w)
        r.open("https://b.com/1", in: w)
        tick(r, minutes: minutes)
        r.open("https://d.com/1", in: w)
        return (r, w)
    }

    @Test func nothingBeforeTheThreshold() {
        let (r, w) = rig(minutes: 19)
        #expect(r.store.groupSuggestion(for: w) == nil)
        r.store.noteCoOpen(seconds: 60) // d now has 1 min with each; a, b, c reach 20
        let s = r.store.groupSuggestion(for: w)
        #expect(s?.keys == [SiteKey("a.com"), SiteKey("b.com"), SiteKey("c.com")])
        #expect(s?.siteNames == ["A", "B", "C"])
        #expect(s?.window == w)
    }

    @Test func needsAnotherSiteToHide() {
        let r = Rig()
        let w = r.store.createWindow()
        r.open("https://a.com/1", in: w)
        r.open("https://b.com/1", in: w)
        tick(r, minutes: 30)
        #expect(r.store.groupSuggestion(for: w) == nil)
        r.open("https://c.com/1", in: w)
        // c has not been open with them long enough: the pair a+b is the set, c is left to hide.
        #expect(r.store.groupSuggestion(for: w)?.keys == [SiteKey("a.com"), SiteKey("b.com")])
        tick(r, minutes: 20)
        // All three qualify but nothing would be left: the best two (by host) are suggested.
        #expect(r.store.groupSuggestion(for: w)?.keys == [SiteKey("a.com"), SiteKey("b.com")])
    }

    @Test func atMostFiveSites() {
        let r = Rig()
        let w = r.store.createWindow()
        for h in ["g", "f", "e", "d", "c", "b", "a"] { r.open("https://\(h).com/1", in: w) }
        tick(r, minutes: 20)
        #expect(r.store.groupSuggestion(for: w)?.keys.map(\.host) == ["a.com", "b.com", "c.com", "d.com", "e.com"])
    }

    @Test func otherWindowsDoNotCount() {
        let (r, _) = rig()
        let other = r.store.createWindow()
        r.open("https://a.com/1", in: other)
        r.open("https://x.com/1", in: other)
        r.open("https://y.com/1", in: other)
        #expect(r.store.groupSuggestion(for: other) == nil)
        #expect(r.store.groupSuggestion(for: WindowID()) == nil)
    }

    @Test func dismissingRemembersTheSetAndChangesNothingElse() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = Rig(dir: dir)
        let w = r.store.createWindow()
        for h in ["a", "b", "c"] { r.open("https://\(h).com/1", in: w) }
        tick(r, minutes: 20)
        r.open("https://d.com/1", in: w)
        let s = try #require(r.store.groupSuggestion(for: w))
        let windows = r.store.windows
        r.log.clear()
        r.store.dismissSuggestion(s)
        #expect(r.store.windows == windows)
        #expect(r.store.groups.isEmpty)
        #expect(r.log.events.isEmpty)
        // Neither the set nor any part of it comes back.
        #expect(r.store.groupSuggestion(for: w) == nil)
        try r.store.save()
        let again = Rig(dir: dir)
        #expect(again.store.groupSuggestion(for: w) == nil)
        // A bigger set is new.
        tick(again, minutes: 20)
        again.open("https://e.com/1", in: w)
        #expect(again.store.groupSuggestion(for: w)?.keys.count == 4)
        again.ok()
    }

    @Test func acceptingCreatesAGroupWithoutFocusing() throws {
        let (r, w) = rig()
        let s = try #require(r.store.groupSuggestion(for: w))
        let id = r.store.acceptSuggestion(s)
        #expect(r.store.groups.count == 1)
        #expect(r.store.groups[0].id == id)
        #expect(r.store.groups[0].keys == s.keys)
        #expect(r.store.groups[0].name == "A, B & C")
        #expect(r.store.groups[0].createdAt == r.clock.t)
        #expect(r.store.window(w)?.focusedGroup == nil)
        #expect(r.store.groups(in: w).map(\.id) == [id])
        #expect(r.store.groupSuggestion(for: w) == nil) // already a group
        #expect(r.store.acceptSuggestion(s) == id)
        #expect(r.store.groups.count == 1)
        r.ok()
    }

    @Test func groupNames() {
        #expect(BrowserStore.groupName([]) == "Group")
        #expect(BrowserStore.groupName(["Docs"]) == "Docs")
        #expect(BrowserStore.groupName(["Docs", "Mail"]) == "Docs & Mail")
        #expect(BrowserStore.groupName(["Docs", "Mail", "Calendar"]) == "Docs, Mail & Calendar")
        #expect(BrowserStore.groupName(["Docs", "Mail", "Calendar", "Drive", "Meet"]) == "Docs, Mail, Calendar +2")
        #expect(BrowserStore.groupName([" ", "Docs", ""]) == "Docs")
    }

    @Test func noSuggestionWhileFocused() throws {
        let (r, w) = rig()
        let s = try #require(r.store.groupSuggestion(for: w))
        let id = r.store.acceptSuggestion(s)
        r.open("https://e.com/1", in: w)
        r.store.setFocus(id, in: w)
        #expect(r.store.window(w)?.focusedGroup == id)
        #expect(r.store.groupSuggestion(for: w) == nil)
    }
}

@MainActor @Suite struct GroupFocusTests {
    /// Pin p; sites a, b, c, d; group {a, c}.
    func rig() -> (Rig, WindowID, pages: [String: PageID], group: GroupID) {
        let r = Rig()
        let w = r.store.createWindow()
        var pages: [String: PageID] = [:]
        pages["p"] = r.open("https://p.com/1", in: w)
        r.store.pin(site: r.store.window(w)!.sites[0].id)
        for h in ["a", "b", "c", "d"] { pages[h] = r.open("https://\(h).com/1", in: w) }
        pages["a2"] = r.open("https://a.com/2", in: w)
        let id = r.store.acceptSuggestion(GroupSuggestion(window: w, keys: [SiteKey("a.com"), SiteKey("c.com")], siteNames: ["A", "C"]))
        return (r, w, pages, id)
    }

    @Test func focusShowsTheGroupPlusTheSelectedSite() {
        let (r, w, pages, g) = rig()
        r.store.select(pages["d"]!, in: w)
        r.store.setFocus(g, in: w)
        #expect(r.store.window(w)?.focusedGroup == g)
        #expect(r.store.visibleSites(in: w).map(\.key.host) == ["a.com", "c.com", "d.com"])
        #expect(r.store.window(w)?.sites.count == 4) // nothing closed or shelved
        r.store.select(pages["a"]!, in: w)
        #expect(r.store.visibleSites(in: w).map(\.key.host) == ["a.com", "c.com"])
        r.store.setFocus(nil, in: w)
        #expect(r.store.visibleSites(in: w).map(\.key.host) == ["a.com", "b.com", "c.com", "d.com"])
        r.ok()
    }

    @Test func showGroupMovesSelectionOffASiteOutsideTheGroup() {
        let (r, w, pages, g) = rig()
        r.store.select(pages["d"]!, in: w)
        r.store.showGroup(g, in: w)
        #expect(r.store.window(w)?.focusedGroup == g)
        #expect(r.store.visibleSites(in: w).map(\.key.host) == ["a.com", "c.com"])
        let selected = r.store.window(w)?.selectedPageID
        #expect(selected.flatMap { r.store.window(w)?.site(containing: $0)?.key.host }.map { ["a.com", "c.com"].contains($0) } == true)
        r.ok()
    }

    @Test func showGroupKeepsASelectionInsideTheGroup() {
        let (r, w, pages, g) = rig()
        r.store.select(pages["c"]!, in: w)
        r.store.showGroup(g, in: w)
        #expect(r.store.window(w)?.selectedPageID == pages["c"])
        #expect(r.store.visibleSites(in: w).map(\.key.host) == ["a.com", "c.com"])
        r.ok()
    }

    @Test func shortcutsCountOnlyVisibleSites() {
        let (r, w, pages, g) = rig()
        r.store.select(pages["a"]!, in: w)
        r.store.setFocus(g, in: w)
        r.store.selectByShortcut(1, in: w)
        #expect(r.store.window(w)?.selectedPageID == pages["p"])
        r.store.selectByShortcut(3, in: w)
        #expect(r.store.window(w)?.selectedPageID == pages["a2"])
        r.store.selectByShortcut(4, in: w)
        #expect(r.store.window(w)?.selectedPageID == pages["c"])
        r.store.selectByShortcut(5, in: w) // out of range while focused
        #expect(r.store.window(w)?.selectedPageID == pages["c"])
        r.store.selectAdjacent(offset: 1, in: w)
        #expect(r.store.window(w)?.selectedPageID == pages["p"]) // wraps past c, skipping d
        r.store.selectAdjacent(offset: -1, in: w)
        #expect(r.store.window(w)?.selectedPageID == pages["c"])
        r.store.setFocus(nil, in: w)
        r.store.selectByShortcut(5, in: w)
        #expect(r.store.window(w)?.selectedPageID == pages["c"]) // p, a, a2, b, c
        r.ok()
    }

    @Test func focusClearsWhenTheGroupLeavesTheWindow() {
        let (r, w, pages, g) = rig()
        r.store.setFocus(g, in: w)
        r.store.closeSite(r.store.window(w)!.site(containing: pages["a"]!)!.id)
        #expect(r.store.window(w)?.focusedGroup == g)
        r.ok()
        r.store.shelve(site: r.store.window(w)!.site(containing: pages["c"]!)!.id)
        #expect(r.store.window(w)?.focusedGroup == nil)
        #expect(r.store.groups.count == 1) // the group itself stays
        #expect(r.store.groups(in: w).isEmpty)
        r.ok()
    }

    @Test func focusIgnoresUnknownGroupsAndGroupsNotInTheWindow() {
        let (r, w, _, g) = rig()
        r.store.setFocus(GroupID(), in: w)
        #expect(r.store.window(w)?.focusedGroup == nil)
        let other = r.store.createWindow()
        r.open("https://z.com/1", in: other)
        r.store.setFocus(g, in: other)
        #expect(r.store.window(other)?.focusedGroup == nil)
        #expect(r.store.groups(in: other).isEmpty)
        r.ok()
    }

    @Test func deleteAndRename() {
        let (r, w, _, g) = rig()
        r.store.renameGroup(g, to: "  Work  ")
        #expect(r.store.group(g)?.name == "Work")
        r.store.renameGroup(g, to: "   ")
        #expect(r.store.group(g)?.name == "Work")
        r.store.setFocus(g, in: w)
        r.store.deleteGroup(g)
        #expect(r.store.groups.isEmpty)
        #expect(r.store.window(w)?.focusedGroup == nil)
        r.ok()
    }

    @Test func fadingStillRunsWhileFocused() {
        let (r, w, pages, g) = rig()
        r.store.select(pages["a"]!, in: w)
        r.store.setFocus(g, in: w)
        let bSite = r.store.window(w)!.site(containing: pages["b"]!)!.id
        r.fader.script = { _, _ in FadeVerdict(sitesToShelve: [bSite]) }
        r.store.runFade()
        #expect(r.store.window(w)?.sites.map(\.key.host) == ["a.com", "c.com", "d.com"])
        #expect(r.store.window(w)?.focusedGroup == g)
        r.ok()
    }

    @Test func invariantsCatchBadFocus() {
        let (r, w, _, g) = rig()
        r.store.setFocus(g, in: w)
        r.store.groups = []
        #expect(!r.store.checkInvariants().isEmpty)
    }
}

@MainActor @Suite struct GroupPersistenceTests {
    @Test func roundTrip() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = Rig(dir: dir)
        let w = r.store.createWindow()
        for h in ["a", "b", "c"] { r.open("https://\(h).com/1", in: w) }
        tick(r, minutes: 25)
        r.open("https://d.com/1", in: w)
        let g = r.store.acceptSuggestion(GroupSuggestion(window: w, keys: [SiteKey("a.com"), SiteKey("b.com")], siteNames: ["A", "B"]))
        r.store.setFocus(g, in: w)
        r.store.dismissSuggestion(GroupSuggestion(window: w, keys: [SiteKey("c.com"), SiteKey("a.com")], siteNames: ["C", "A"]))
        try r.store.save()

        let again = Rig(dir: dir)
        #expect(again.store.groups == r.store.groups)
        #expect(again.store.window(w)?.focusedGroup == g)
        #expect(again.store.coOpen == r.store.coOpen)
        #expect(again.store.coOpenTime(SiteKey("a.com"), SiteKey("c.com")) == 25 * 60)
        #expect(again.store.dismissedSuggestions == [[SiteKey("a.com"), SiteKey("c.com")]])
        #expect(again.store.qualifiedPairs == r.store.qualifiedPairs)
        again.ok()
    }

    @Test func oldFileWithoutTheNewFieldsLoads() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let page = UUID(), site = UUID(), window = UUID()
        // Exactly the shape the first version 1 wrote: no groups, coOpen, dismissedSuggestions or focusedGroup.
        let json = """
        {"version":1,
         "windows":[{"id":{"raw":"\(window)"},"sites":[{"id":{"raw":"\(site)"},"key":{"host":"a.com"},"name":"A",
            "pages":[{"id":{"raw":"\(page)"},"url":"https://a.com/1","rawTitle":"","name":"1",
                      "usage":{"visitCount":1,"activeDays":1,"firstUsed":1000,"lastUsed":1000},
                      "fade":"live","scrollY":0,"dwell":0}],
            "currentPageID":{"raw":"\(page)"},"isKept":false,"fade":"live"}],
            "selectedPageID":{"raw":"\(page)"}}],
         "pins":[],"shelf":[],"history":[],"siteStats":{},"closed":[]}
        """
        try Data(json.utf8).write(to: dir.appendingPathComponent("state.json"))
        let r = Rig(dir: dir)
        #expect(r.store.recoveredCorruptFile == nil)
        #expect(r.store.windows.count == 1)
        #expect(r.store.windows[0].focusedGroup == nil)
        #expect(r.store.groups.isEmpty)
        #expect(r.store.coOpen.isEmpty)
        #expect(r.store.dismissedSuggestions.isEmpty)
        r.ok()
        // And it saves the new fields from then on.
        r.store.acceptSuggestion(GroupSuggestion(window: WindowID(window), keys: [SiteKey("a.com"), SiteKey("b.com")], siteNames: ["A", "B"]))
        try r.store.save()
        #expect(Rig(dir: dir).store.groups.count == 1)
    }

    @Test func loadRepairsGroupsAndFocus() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let t = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let p = Page(url: u("https://a.com/1"), name: "1", usage: Usage(at: t))
        let gid = GroupID()
        let window = WindowState(sites: [Site(key: SiteKey("a.com"), name: "A", pages: [p])], selectedPageID: p.id,
                                 focusedGroup: GroupID())
        let groups = [SiteGroup(id: gid, keys: [SiteKey("a.com"), SiteKey("a.com"), SiteKey("b.com")], name: " ", createdAt: t),
                      SiteGroup(id: gid, keys: [SiteKey("x.com")], name: "Dup", createdAt: t),
                      SiteGroup(keys: [], name: "Empty", createdAt: t)]
        let snapshot = StoreSnapshot(version: 1, windows: [window], pins: [], shelf: [], history: [], siteStats: [:], closed: [],
                                     latestHistory: nil, groups: groups,
                                     coOpen: [CoOpenRecord(a: "a.com", b: "a.com", seconds: 5000, updatedAt: t),
                                              CoOpenRecord(a: "b.com", b: "a.com", seconds: -5, updatedAt: t),
                                              CoOpenRecord(a: "b.com", b: "a.com", seconds: 1300, updatedAt: t)],
                                     dismissedSuggestions: [["c.com", "b.com", "b.com"], [], ["b.com", "c.com"]])
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try snapshot.encoded().write(to: dir.appendingPathComponent("state.json"))
        let r = Rig(dir: dir)
        #expect(r.store.recoveredCorruptFile == nil)
        #expect(r.store.groups.count == 1)
        #expect(r.store.groups[0].keys == [SiteKey("a.com"), SiteKey("b.com")])
        #expect(r.store.groups[0].name == "A & B")
        #expect(r.store.windows[0].focusedGroup == nil)
        #expect(r.store.coOpen.count == 1)
        #expect(r.store.coOpenTime(SiteKey("a.com"), SiteKey("b.com")) == 1300)
        #expect(r.store.qualifiedPairs == [CoOpenPair(SiteKey("a.com"), SiteKey("b.com"))])
        #expect(r.store.dismissedSuggestions == [[SiteKey("b.com"), SiteKey("c.com")]])
        r.ok()
    }
}
