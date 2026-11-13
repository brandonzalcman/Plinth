import Foundation
import Testing
import PlinthModel
@testable import PlinthStore

@MainActor @Suite struct SemanticResultsTests {
    /// An open page, a pin, a shelved page and a history-only URL.
    func populated() -> (Rig, WindowID, open: PageID, pin: SiteID, shelved: PageID) {
        let r = Rig()
        let w = r.store.createWindow()
        let gone = r.open("https://old.com/archive", in: w)
        r.store.closePage(gone)
        r.open("https://pin.com/hub", in: w)
        r.store.pin(site: r.store.window(w)!.sites[0].id)
        let shelved = r.open("https://shelf.com/draft", in: w)
        let open = r.open("https://open.com/live", in: w)
        r.store.shelve(site: r.store.window(w)!.site(containing: shelved)!.id)
        return (r, w, open, r.store.pins[0].id, shelved)
    }

    func m(_ s: String, _ title: String = "T") -> SemanticMatch {
        SemanticMatch(url: u(s), title: title, key: FakeIdentity().key(for: u(s)), score: 0.5)
    }

    @Test func mapsEachURLToTheBestPlaceInMatchOrder() {
        let (r, w, open, pin, shelved) = populated()
        let results = r.store.semanticResults([m("https://old.com/archive", "Archive"), m("https://shelf.com/draft"),
                                               m("https://open.com/live"), m("https://pin.com/hub"),
                                               m("https://never.com/x", "Never seen")],
                                              excluding: [], limit: 10)
        #expect(results.map(\.target) == [
            .history(u("https://old.com/archive")),
            .shelf(entry: r.store.shelf[0].id, page: shelved),
            .openPage(open, window: w),
            .pin(pin),
            .history(u("https://never.com/x")),
        ])
        #expect(results.allSatisfy { $0.byMeaning })
        #expect(Set(results.map(\.id)).count == 5)
        #expect(results[0].title == "archive") // the history entry's name wins
        #expect(results[4].title == "Never seen")
        #expect(results[2].subtitle == "open.com/live")
        #expect(results[2].key == SiteKey("open.com"))
    }

    @Test func skipsWhatKeywordSearchFoundAndDeduplicates() {
        let (r, _, _, _, _) = populated()
        let keyword = r.store.search("live") + r.store.search("archive")
        #expect(keyword.count == 2)
        let results = r.store.semanticResults([m("https://open.com/live"), m("https://old.com/archive"),
                                               m("https://pin.com/hub"), m("https://pin.com/hub"),
                                               m("https://shelf.com/draft")],
                                              excluding: keyword, limit: 10)
        #expect(results.map(\.subtitle) == ["pin.com/hub", "shelf.com/draft"])
    }

    @Test func limit() {
        let (r, _, _, _, _) = populated()
        let all = [m("https://a.com/1"), m("https://a.com/2"), m("https://a.com/3")]
        #expect(r.store.semanticResults(all, excluding: [], limit: 2).count == 2)
        #expect(r.store.semanticResults(all, excluding: [], limit: 0).isEmpty)
        #expect(r.store.semanticResults([], excluding: [], limit: 5).isEmpty)
    }

    @Test func latestHistoryEntryForBarPinAndShelf() {
        let (r, _, open, _, shelved) = populated()
        #expect(r.store.latestHistoryEntry(for: open)?.url == u("https://open.com/live"))
        #expect(r.store.latestHistoryEntry(for: r.store.pins[0].page.id)?.url == u("https://pin.com/hub"))
        #expect(r.store.latestHistoryEntry(for: shelved)?.url == u("https://shelf.com/draft"))
        r.store.pageDidUpdate(open, url: u("https://open.com/next"), title: "Next", siteNameHint: nil)
        #expect(r.store.latestHistoryEntry(for: open)?.url == u("https://open.com/next"))
        r.store.closePage(open)
        #expect(r.store.latestHistoryEntry(for: open) == nil)
        #expect(r.store.latestHistoryEntry(for: PageID()) == nil)
    }
}

@MainActor @Suite struct SyncTests {
    /// Pin pin.com; shelf.com shelved; open.com on the bar.
    func populated() -> (Rig, WindowID) {
        let r = Rig()
        let w = r.store.createWindow()
        r.open("https://pin.com/home", in: w)
        r.store.pin(site: r.store.window(w)!.sites[0].id)
        let s = r.open("https://shelf.com/1", in: w)
        r.open("https://shelf.com/2", in: w)
        r.open("https://open.com/1", in: w)
        r.store.shelve(site: r.store.window(w)!.site(containing: s)!.id)
        return (r, w)
    }

    @Test func applyingYourOwnPayloadChangesNothing() {
        let (r, _) = populated()
        let payload = r.store.syncPayload()
        #expect(payload.pins == r.store.pins)
        #expect(payload.shelf == r.store.shelf)
        #expect(payload.history == r.store.history)
        let windows = r.store.windows
        r.log.clear()
        r.store.applySynced(payload)
        #expect(r.store.syncPayload() == payload)
        #expect(r.store.windows == windows)
        #expect(r.log.events.isEmpty)
        r.ok()
    }

    @Test func matchedPinsKeepTheirLocalPage() {
        let (r, _) = populated()
        let local = r.store.pins[0]
        r.store.pageDidScroll(local.page.id, y: 420)
        var payload = r.store.syncPayload()
        payload.pins[0] = PinnedSite(key: local.key, name: "Pin Remote", homeURL: u("https://pin.com/start"),
                                     page: Page(url: u("https://pin.com/elsewhere"), name: "x", usage: Usage(at: .distantPast)))
        r.log.clear()
        r.store.applySynced(payload)
        #expect(r.store.pins.count == 1)
        let pin = r.store.pins[0]
        #expect(pin.id == local.id)
        #expect(pin.page.id == local.page.id)
        #expect(pin.page.url == local.page.url)
        #expect(pin.page.scrollY == 420)
        #expect(pin.page.usage == local.page.usage)
        #expect(pin.name == "Pin Remote")
        #expect(pin.homeURL == u("https://pin.com/start"))
        #expect(r.log.events.isEmpty)
        r.ok()
    }

    @Test func removedPinsAreClosedAndSelectionMoves() {
        let (r, w) = populated()
        let pinPage = r.store.pins[0].page.id
        r.store.selectPin(r.store.pins[0].id, in: w)
        let other = r.store.createWindow()
        r.open("https://x.com/1", in: other)
        r.store.select(pinPage, in: other)
        var payload = r.store.syncPayload()
        payload.pins = []
        r.log.clear()
        r.store.applySynced(payload)
        #expect(r.store.pins.isEmpty)
        #expect(r.log.events.first == .pageClosed(pinPage))
        #expect(r.log.events.contains(.selectionChanged(w)))
        #expect(r.log.events.contains(.selectionChanged(other)))
        #expect(r.store.window(w)?.selectedPageID == r.store.window(w)?.sites[0].pages[0].id)
        #expect(r.store.window(other)?.selectedPageID == r.store.window(other)?.sites[0].pages[0].id)
        #expect(r.store.latestHistoryEntry(for: pinPage) == nil)
        r.ok()
    }

    @Test func newRemotePinsGetAFreshPageAndEmitNothingUntilSelected() {
        let (r, w) = populated()
        let remote = Rig()
        let rw = remote.store.createWindow()
        remote.open("https://mail.com/inbox/42", in: rw)
        remote.store.pin(site: remote.store.window(rw)!.sites[0].id)
        let remotePin = remote.store.pins[0]
        var payload = r.store.syncPayload()
        payload.pins.append(remotePin)
        r.log.clear()
        r.store.applySynced(payload)
        #expect(r.log.events.isEmpty)
        #expect(r.store.pins.count == 2)
        let pin = r.store.pins[1]
        #expect(pin.key == SiteKey("mail.com"))
        #expect(pin.id == remotePin.id)
        #expect(pin.page.id != remotePin.page.id)
        #expect(pin.page.url == remotePin.homeURL)
        #expect(!pin.page.name.isEmpty)
        r.ok()
        r.store.selectPin(pin.id, in: w)
        #expect(r.store.window(w)?.selectedPageID == pin.page.id)
        #expect(r.log.events == [.selectionChanged(w)])
        r.ok()
    }

    @Test func shelfPagesMergeByID() {
        let (r, w) = populated()
        let entry = r.store.shelf[0]
        let kept = entry.pages[0], dropped = entry.pages[1]
        r.store.rename(kept.id, to: "Local name")
        let openPage = r.store.window(w)!.sites[0].pages[0]
        var remoteKept = kept
        remoteKept.customName = "Remote name"; remoteKept.name = "Remote name"
        let newRemote = Page(url: u("https://shelf.com/3"), name: "3", usage: Usage(at: r.clock.t))
        var payload = r.store.syncPayload()
        payload.shelf = [ShelfEntry(id: entry.id, key: entry.key, name: entry.name, pages: [remoteKept, newRemote], shelvedAt: entry.shelvedAt),
                         ShelfEntry(key: SiteKey("open.com"), name: "Open", pages: [openPage], shelvedAt: r.clock.t)]
        r.log.clear()
        r.store.applySynced(payload)
        #expect(r.log.events == [.pageClosed(dropped.id)])
        #expect(r.store.shelf.count == 1) // open.com's page is on this Mac's bar: not duplicated
        #expect(r.store.shelf[0].pages.map(\.id) == [kept.id, newRemote.id])
        #expect(r.store.shelf[0].pages[0].name == "Local name")
        #expect(r.store.window(w)?.sites[0].pages[0] == openPage)
        r.ok()
        // A page that arrived by sync can be restored like any other.
        r.store.restore(entry: r.store.shelf[0].id, page: newRemote.id, into: w)
        #expect(r.store.window(w)?.selectedPageID == newRemote.id)
        r.ok()
    }

    @Test func historyIsReplacedAndPointersKeptWhereTheyStillExist() {
        let (r, w) = populated()
        let openID = r.store.window(w)!.sites[0].pages[0].id
        let shelvedID = r.store.shelf[0].pages[0].id
        let openEntry = r.store.latestHistoryEntry(for: openID)!
        #expect(r.store.latestHistoryEntry(for: shelvedID) != nil)
        let foreign = HistoryEntry(url: u("https://far.com/1"), title: "Far", name: "Far", key: SiteKey("far.com"), visitedAt: r.clock.t)
        var payload = r.store.syncPayload()
        payload.history = [foreign, openEntry]
        r.store.applySynced(payload)
        #expect(r.store.history == [foreign, openEntry])
        #expect(r.store.latestHistoryEntry(for: openID) == openEntry)
        #expect(r.store.latestHistoryEntry(for: shelvedID) == nil)
        r.store.recordDwell(openID, seconds: 5)
        #expect(r.store.history[1].dwell == 5)
        r.ok()
    }

    @Test func sanitisingRunsOnTheMergedResult() {
        let (r, _) = populated()
        var payload = r.store.syncPayload()
        let dupPin = PinnedSite(key: r.store.pins[0].key, name: "Again", homeURL: u("https://pin.com/again"),
                                page: Page(url: u("https://pin.com/again"), name: "a", usage: Usage(at: r.clock.t)))
        payload.pins.append(dupPin)
        let stray = Page(url: u("https://elsewhere.com/1"), name: "e", usage: Usage(at: r.clock.t))
        payload.shelf[0].pages.append(stray) // wrong site for this entry
        r.store.applySynced(payload)
        #expect(r.store.pins.count == 1)
        #expect(Set(r.store.shelf.map(\.key.host)) == ["shelf.com", "elsewhere.com"])
        r.ok()
    }

    @Test func openPagesSummary() {
        let r = Rig()
        let w1 = r.store.createWindow(), w2 = r.store.createWindow()
        r.open("https://a.com/1", in: w1)
        r.open("https://b.com/1", in: w1)
        r.open("https://a.com/2", in: w1)
        r.open("about:blank", in: w1)
        r.open("https://b.com/1", in: w2)
        r.open("https://c.com/1", in: w2)
        r.open("https://pin.com/1", in: w2)
        r.store.pin(site: r.store.window(w2)!.site(containing: r.store.window(w2)!.selectedPageID!)!.id)
        let summary = r.store.openPagesSummary()
        #expect(summary.map(\.url.absoluteString) == ["https://a.com/1", "https://a.com/2", "https://b.com/1", "https://c.com/1"])
        #expect(summary[0].key == SiteKey("a.com"))
        #expect(summary[0].name == "1")
    }
}
