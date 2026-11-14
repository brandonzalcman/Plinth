import Foundation
import Testing
import PlinthModel
@testable import PlinthStore

@MainActor @Suite struct SuggestedPagesTests {
    let rig = Rig()
    var store: BrowserStore { rig.store }

    private func visit(_ s: String, daysAgo: Double = 0, title: String = "") -> HistoryEntry {
        let link = u(s)
        return HistoryEntry(url: link, title: title, name: title.isEmpty ? (link.host ?? s) : title,
                            key: SiteKey(link.host ?? "x"), visitedAt: rig.clock.t.addingTimeInterval(-daysAgo * 86_400))
    }

    private func load(_ entries: [HistoryEntry]) {
        store.applySynced(SyncPayload(pins: store.pins, shelf: store.shelf,
                                      history: entries.sorted { $0.visitedAt > $1.visitedAt }))
    }

    @Test func emptyHistoryHasNoSuggestions() {
        #expect(store.suggestedPages().isEmpty)
    }

    @Test func mostVisitedAndRecentFirstOnePerPage() {
        load([visit("https://a.com/x", daysAgo: 40), visit("https://a.com/x", daysAgo: 41),
              visit("https://b.com/y", daysAgo: 0), visit("https://b.com/y", daysAgo: 1), visit("https://b.com/y", daysAgo: 2),
              visit("https://c.com/z", daysAgo: 0)])
        let rows = store.suggestedPages()
        #expect(rows.map(\.subtitle) == ["b.com/y", "c.com/z", "a.com/x"])
        #expect(Set(rows.map(\.id)).count == rows.count)
    }

    @Test func limitAndHostCap() {
        load((1...6).map { visit("https://same.com/p\($0)", daysAgo: Double($0)) } + [visit("https://other.com/", daysAgo: 9)])
        let rows = store.suggestedPages(limit: 4)
        #expect(rows.filter { $0.key == SiteKey("same.com") }.count == 2)
        #expect(rows.count == 3)
        #expect(store.suggestedPages(limit: 1).count == 1)
        #expect(store.suggestedPages(limit: 0).isEmpty)
    }

    @Test func openPinnedAndShelvedPagesAreLeftOut() {
        let w = store.createWindow()
        rig.open("https://open.com/a", in: w)
        rig.open("https://pinned.com/", in: w)
        store.pin(site: store.window(w)!.sites.first { $0.key.host == "pinned.com" }!.id)
        load([visit("https://open.com/a"), visit("https://hist.com/"), visit("https://pinned.com/"), visit("https://gone.com/q")])
        #expect(store.suggestedPages().map(\.key.host).sorted() == ["gone.com", "hist.com"])
    }

    @Test func privateWindowGetsNone() {
        load([visit("https://a.com/")])
        #expect(store.suggestedPages(isPrivate: true).isEmpty)
    }

    @Test func downloadsAreNotSuggested() {
        load([visit("https://a.com/setup.dmg"), visit("https://a.com/")])
        #expect(store.suggestedPages().map(\.subtitle) == ["a.com"])
    }

    @Test func plinthIsSuggestedWhenTypedEvenWithoutHistory() {
        for typed in ["plinth", "Plin", "get", "getplinth", "pli"] {
            #expect(store.suggestions(for: typed).contains { $0.target == .history(URL(string: "https://getplinth.dev/")!) }, "\(typed)")
        }
        #expect(store.suggestions(for: "").isEmpty)
        #expect(store.suggestedPages().isEmpty)
    }

    @Test func plinthIsNotListedTwiceWhenHistoryHasIt() {
        load([visit("https://getplinth.dev/", daysAgo: 1), visit("https://getplinth.dev/", daysAgo: 2), visit("https://www.getplinth.dev/", daysAgo: 3)])
        #expect(store.suggestions(for: "plinth").filter { $0.key.host.hasSuffix(PlinthPromo.host) }.count == 1)
        #expect(Set(store.suggestions(for: "plinth").map(\.id)).count == store.suggestions(for: "plinth").count)
    }

    @Test func thePlinthSiteIsNeverASuggestedPage() {
        load([visit("https://getplinth.dev/", daysAgo: 0), visit("https://getplinth.dev/", daysAgo: 1),
              visit("https://www.getplinth.dev/privacy", daysAgo: 0), visit("https://a.com/", daysAgo: 2)])
        #expect(store.suggestedPages().map(\.key.host) == ["a.com"])
    }

    @Test func plinthDoesNotCrowdUnrelatedQueries() {
        load([visit("https://github.com/", daysAgo: 1), visit("https://github.com/", daysAgo: 2)])
        #expect(!store.suggestions(for: "github").contains { $0.key.host == PlinthPromo.host })
    }

    @Test func firstLaunchRule() {
        #expect(PlinthPromo.firstLaunchURL(hasCompletedOnboarding: false, profileHadWindows: false) == PlinthPromo.url)
        #expect(PlinthPromo.firstLaunchURL(hasCompletedOnboarding: true, profileHadWindows: false) == nil)
        #expect(PlinthPromo.firstLaunchURL(hasCompletedOnboarding: false, profileHadWindows: true) == nil)
        #expect(PlinthPromo.firstLaunchURL(hasCompletedOnboarding: false, profileHadWindows: false, hasExplicitURLs: true) == nil)
        #expect(PlinthPromo.firstLaunchURL(hasCompletedOnboarding: false, profileHadWindows: false, alreadyOpened: true) == nil)
        #expect(PlinthPromo.isPlinthHost("www.getplinth.dev") && !PlinthPromo.isPlinthHost("evil-getplinth.dev"))
    }
}
