import Foundation
import Testing
import PlinthModel
import PlinthStore
@testable import PlinthSync

private struct Identity: SiteIdentifying {
    func key(for url: URL) -> SiteKey { SiteKey(url.host ?? "x") }
    func siteName(for key: SiteKey) -> String { key.host }
}
private struct Namer: PageNaming {
    func name(title: String, url: URL, siteName: String) -> String { title.isEmpty ? (url.host ?? "page") : title }
}
private struct NoFade: FadeEvaluating {
    func evaluate(sites: [Site], stats: [SiteKey: Usage], visible: Set<PageID>, now: Date) -> FadeVerdict { FadeVerdict() }
}

@MainActor private func makeStore(_ dir: URL?, _ clock: Clock) -> BrowserStore {
    BrowserStore(identity: Identity(), namer: Namer(), fader: NoFade(), storageDirectory: dir, now: { clock.t })
}

/// History synced from another Mac must shape the suggested pages and the typed suggestions here.
@MainActor @Suite struct SuggestedPagesAcrossDevicesTests {
    let clock = Clock()
    let server = InMemoryTransport()

    private func visits(_ s: String, count: Int, at: Date, spacing: TimeInterval = 60) -> [HistoryEntry] {
        (0..<count).map { makeHistory(s, at: at.addingTimeInterval(-Double($0) * spacing)) }
    }

    /// One sync round on Mac `mac`, applied to `store` the way the shell does.
    private func round(_ mac: Mac, _ store: BrowserStore) async throws {
        mac.local = store.syncPayload()
        try await mac.sync()
        store.applySynced(mac.local)
    }

    @Test func visitsOnAMakeAPageATopSuggestionOnB() async throws {
        let a = Mac("A", server: server, clock: clock)
        let b = Mac("B", server: server, clock: clock)
        let storeA = makeStore(nil, clock), storeB = makeStore(nil, clock)
        storeB.applySynced(SyncPayload(pins: [], shelf: [], history: [makeHistory("https://b-only.com/", at: clock.t.addingTimeInterval(-86_400 * 60))]))
        _ = storeB.suggestedPages() // B's index is already built before anything syncs in
        storeA.applySynced(SyncPayload(pins: [], shelf: [], history: visits("https://hot.example/", count: 6, at: clock.t)))

        try await round(a, storeA)
        try await round(b, storeB)

        #expect(storeB.suggestedPages().first?.key.host == "hot.example")
        #expect(storeB.suggestedPages().contains { $0.key.host == "b-only.com" })
        // And the typed suggestions see it too.
        #expect(storeB.suggestions(for: "hot").contains { $0.key.host == "hot.example" })
    }

    @Test func olderAndNewerRemoteEntriesBothCountAfterAnIncrementalUpdate() async throws {
        let a = Mac("A", server: server, clock: clock)
        let b = Mac("B", server: server, clock: clock)
        let storeA = makeStore(nil, clock), storeB = makeStore(nil, clock)
        // B's newest entry sits in the middle of A's.
        storeB.applySynced(SyncPayload(pins: [], shelf: [], history: [makeHistory("https://mid.com/", at: clock.t.addingTimeInterval(-3_600))]))
        _ = storeB.suggestedPages()
        let newer = visits("https://new.com/", count: 3, at: clock.t)
        let older = visits("https://old.com/", count: 5, at: clock.t.addingTimeInterval(-7_200))
        storeA.applySynced(SyncPayload(pins: [], shelf: [], history: newer + older))
        try await round(a, storeA)
        try await round(b, storeB)
        let hosts = Set(storeB.suggestedPages(limit: 10).map(\.key.host))
        #expect(hosts == ["new.com", "mid.com", "old.com"])
    }

    @Test func rankingSurvivesARestartFromTheSnapshot() async throws {
        let a = Mac("A", server: server, clock: clock)
        let storeA = makeStore(nil, clock)
        storeA.applySynced(SyncPayload(pins: [], shelf: [], history: visits("https://hot.example/", count: 6, at: clock.t)))
        try await round(a, storeA)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("plinth-sugg-\(UUID().uuidString)")
        let state = dir.appendingPathComponent("sync-state.json")
        var b = Mac("B", server: server, clock: clock, stateURL: state)
        var storeB = makeStore(dir, clock)
        try await round(b, storeB)
        storeB.flush()

        // Restart: a new store from disk and a new engine from its saved base.
        storeB = makeStore(dir, clock)
        b = Mac("B", server: server, clock: clock, stateURL: state)
        #expect(storeB.suggestedPages().first?.key.host == "hot.example")
        try await round(b, storeB)
        #expect(storeB.suggestedPages().first?.key.host == "hot.example")
        #expect(storeB.history.count == 6)
    }

    @Test func aSyncedClearRemovesItEverywhere() async throws {
        let a = Mac("A", server: server, clock: clock)
        let b = Mac("B", server: server, clock: clock)
        let storeA = makeStore(nil, clock), storeB = makeStore(nil, clock)
        storeA.applySynced(SyncPayload(pins: [], shelf: [], history: visits("https://hot.example/", count: 6, at: clock.t)))
        try await round(a, storeA)
        try await round(b, storeB)
        #expect(storeB.suggestedPages().first?.key.host == "hot.example")

        clock.advance()
        storeA.clearHistory(since: nil)
        a.local = storeA.syncPayload()
        a.engine.clearHistory()
        try await round(a, storeA)
        try await round(b, storeB)
        #expect(storeB.suggestedPages().isEmpty)
        #expect(storeB.suggestions(for: "hot").isEmpty)
        #expect(storeA.suggestedPages().isEmpty)
    }
}
