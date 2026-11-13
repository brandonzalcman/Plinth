import Foundation
import Testing
import PlinthModel
@testable import PlinthStore

@MainActor @Suite struct PrivateWindowTests {
    /// A normal window with a.com and a private window with secret.com and b.com.
    private func rig(dir: URL? = nil) -> (r: Rig, normal: WindowID, priv: WindowID) {
        let r = Rig(dir: dir)
        let normal = r.store.createWindow()
        r.open("https://a.com/1", in: normal)
        let priv = r.store.createPrivateWindow()
        r.open("https://secret.com/1", in: priv)
        r.open("https://b.com/1", in: priv)
        return (r, normal, priv)
    }

    @Test func historyRecordsNothingForPrivatePages() {
        let (r, _, priv) = rig()
        let page = r.store.window(priv)!.sites[0].pages[0].id
        r.store.pageDidUpdate(page, url: u("https://secret.com/next"), title: "Next", siteNameHint: nil)
        r.store.pageDidUpdate(page, url: nil, title: "Renamed", siteNameHint: nil)
        r.store.recordDwell(page, seconds: 30)
        #expect(r.store.history.map(\.url.host) == ["a.com"])
        #expect(r.store.latestHistory[page] == nil)
        #expect(r.store.latestHistoryEntry(for: page) == nil)
        r.ok()
    }

    @Test func closingAPrivatePageOrSiteKeepsNothingToReopen() {
        let (r, normal, priv) = rig()
        let w = r.store.window(priv)!
        r.log.clear()
        r.store.closePage(w.sites[0].pages[0].id)
        r.store.closeSite(w.sites[1].id)
        #expect(r.log.events.filter { if case .pageClosed = $0 { true } else { false } }.count == 2)
        #expect(r.store.closed.isEmpty)
        #expect(r.store.reopenClosedPage(in: priv) == nil)
        r.store.closePage(r.store.window(normal)!.sites[0].pages[0].id)
        // A normal window's closed page does not come back inside a private window either.
        #expect(r.store.reopenClosedPage(in: priv) == nil)
        #expect(r.store.closed.count == 1)
        r.ok()
    }

    @Test func closingThePrivateWindowDiscardsItsPagesInsteadOfShelving() {
        let (r, _, priv) = rig()
        let ids = r.store.window(priv)!.sites.flatMap { $0.pages.map(\.id) }
        r.log.clear()
        r.store.closeWindow(priv)
        #expect(r.store.shelf.isEmpty)
        #expect(!r.log.events.contains { if case .pagesShelved = $0 { true } else { false } })
        for id in ids { #expect(r.log.events.contains(.pageClosed(id))) }
        #expect(r.store.siteStats[SiteKey("secret.com")] == nil)
        #expect(r.store.siteStats[SiteKey("a.com")] != nil)
        r.ok()
    }

    @Test func fadingAndPuttingAwayDiscardPrivateSites() {
        let (r, _, priv) = rig()
        let sites = r.store.window(priv)!.sites
        r.fader.script = { all, _ in FadeVerdict(sitesToShelve: all.filter { $0.key.host == "secret.com" }.map(\.id)) }
        r.log.clear()
        r.store.runFade()
        #expect(r.store.shelf.isEmpty)
        #expect(r.store.window(priv)!.sites.map(\.key.host) == ["b.com"])
        #expect(r.log.events.contains(.pageClosed(sites[0].pages[0].id)))
        r.store.shelve(site: r.store.window(priv)!.sites[0].id)
        #expect(r.store.shelf.isEmpty)
        r.ok()
    }

    @Test func siteStatsAreNotCountedForPrivateVisits() {
        let r = Rig()
        let normal = r.store.createWindow()
        r.open("https://a.com/1", in: normal)
        let before = r.store.siteStats[SiteKey("a.com")]!
        let priv = r.store.createPrivateWindow()
        r.open("https://a.com/2", in: priv)
        r.open("https://fresh.com/1", in: priv)
        #expect(r.store.siteStats[SiteKey("a.com")] == before)
        // Fading still has a record for the private site while it is open.
        #expect(r.store.siteStats[SiteKey("fresh.com")] != nil)
        r.ok()
    }

    @Test func coOpenTimeIgnoresPrivateWindows() {
        let r = Rig()
        let priv = r.store.createPrivateWindow()
        r.open("https://a.com/1", in: priv)
        r.open("https://b.com/1", in: priv)
        for _ in 0..<60 { r.store.noteCoOpen(seconds: 60) }
        #expect(r.store.coOpenTime(SiteKey("a.com"), SiteKey("b.com")) == 0)
        #expect(r.store.groupSuggestion(for: priv) == nil)
    }

    @Test func savedStateHasNoPrivateWindowAndRelaunchRestoresOnlyTheNormalOne() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (r, normal, _) = rig(dir: dir)
        try r.store.save()
        let text = try String(contentsOf: dir.appendingPathComponent("state.json"), encoding: .utf8)
        #expect(!text.contains("secret.com") && !text.contains("b.com"))
        #expect(!text.contains("\"isPrivate\":true"))

        let again = Rig(dir: dir)
        #expect(again.store.windows.map(\.id) == [normal])
        #expect(again.store.siteStats[SiteKey("secret.com")] == nil)
        #expect(again.store.history.map(\.url.host) == ["a.com"])
        again.ok()
    }

    @Test func aPrivateWindowInAStateFileIsDropped() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = Rig(dir: dir)
        r.store.createWindow()
        // Written by hand: the store never saves one.
        r.store.windows.append(WindowState(isPrivate: true))
        let snapshot = StoreSnapshot(version: 1, windows: r.store.windows, pins: [], shelf: [], history: [], siteStats: [:], closed: [])
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try snapshot.encoded().write(to: dir.appendingPathComponent("state.json"))
        #expect(Rig(dir: dir).store.windows.count == 1)
    }

    @Test func windowStateFromAnOlderFileIsNotPrivate() throws {
        let id = WindowID()
        let json = #"{"id":{"raw":"\#(id.raw.uuidString)"},"sites":[]}"#
        let w = try JSONDecoder().decode(WindowState.self, from: Data(json.utf8))
        #expect(w.isPrivate == false)
        let back = try JSONDecoder().decode(WindowState.self, from: JSONEncoder().encode(WindowState(isPrivate: true)))
        #expect(back.isPrivate)
    }

    @Test func commandBarAndSearchNeverOfferPrivatePages() {
        let (r, _, _) = rig()
        for query in ["secret", "b.com", "secret.com"] {
            #expect(r.store.search(query).isEmpty)
            #expect(r.store.suggestions(for: query).allSatisfy { !$0.subtitle.contains("secret") })
        }
        #expect(!r.store.search("a.com").isEmpty)
        let match = SemanticMatch(url: u("https://secret.com/1"), title: "S", key: SiteKey("secret.com"), score: 0.9)
        let found = r.store.semanticResults([match], excluding: [])
        if case .openPage? = found.first?.target { Issue.record("a private page was offered by meaning") }
    }

    @Test func syncAndOpenPagesLeaveOutPrivatePages() {
        let (r, _, _) = rig()
        #expect(r.store.openPagesSummary().map(\.key.host) == ["a.com"])
        let payload = r.store.syncPayload()
        #expect(payload.history.allSatisfy { $0.key.host == "a.com" })
        #expect(payload.pins.isEmpty && payload.shelf.isEmpty)
    }

    @Test func pinsStayOutOfPrivateWindows() {
        let (r, normal, priv) = rig()
        r.store.pin(site: r.store.window(normal)!.sites[0].id)
        let pin = r.store.pins[0]
        #expect(r.store.pins(in: priv).isEmpty)
        #expect(r.store.pins(in: normal).count == 1)
        let selected = r.store.window(priv)!.selectedPageID
        r.store.selectPin(pin.id, in: priv)
        #expect(r.store.window(priv)!.selectedPageID == selected)
        r.store.selectByShortcut(1, in: priv)
        #expect(r.store.window(priv)!.selectedPageID != pin.page.id)
        r.store.pin(site: r.store.window(priv)!.sites[0].id)
        #expect(r.store.pins.count == 1)
        r.store.unpin(pin.id, into: priv)
        #expect(r.store.pins.count == 1)
        r.ok()
    }

    @Test func theShelfCannotBeRestoredIntoAPrivateWindow() {
        let (r, normal, priv) = rig()
        r.store.shelve(site: r.store.window(normal)!.sites[0].id)
        let entry = r.store.shelf[0]
        #expect(r.store.restore(entry: entry.id, page: nil, into: priv).isEmpty)
        #expect(r.store.shelf.count == 1)
    }

    @Test func eachPrivateWindowIsItsOwn() {
        let r = Rig()
        let one = r.store.createPrivateWindow()
        let two = r.store.createPrivateWindow()
        #expect(r.store.isPrivate(window: one) && r.store.isPrivate(window: two) && one != two)
        let page = r.open("https://x.com/", in: one)
        #expect(r.store.isPrivate(page: page))
        #expect(!r.store.isPrivate(page: PageID()))
    }

    @Test func privateWindowsHaveNoGroups() {
        let r = Rig()
        let normal = r.store.createWindow()
        r.open("https://a.com/1", in: normal)
        r.open("https://b.com/1", in: normal)
        for _ in 0..<30 { r.store.noteCoOpen(seconds: 60) }
        r.open("https://c.com/1", in: normal)
        let suggestion = r.store.groupSuggestion(for: normal)!
        let group = r.store.acceptSuggestion(suggestion)
        #expect(r.store.groups(in: normal).count == 1)

        let priv = r.store.createPrivateWindow()
        r.open("https://a.com/2", in: priv)
        r.open("https://b.com/2", in: priv)
        #expect(r.store.groups(in: priv).isEmpty)
        #expect(r.store.groupSuggestion(for: priv) == nil)
        r.store.setFocus(group, in: priv)
        r.store.showGroup(group, in: priv)
        #expect(r.store.window(priv)!.focusedGroup == nil)
        #expect(r.store.visibleSites(in: priv).count == 2)
        r.ok()
    }
}
