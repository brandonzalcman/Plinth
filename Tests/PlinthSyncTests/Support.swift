import Foundation
import Testing
import PlinthModel
@testable import PlinthSync

final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var _t = Date(timeIntervalSinceReferenceDate: 800_000_000)
    var t: Date { lock.withLock { _t } }
    func advance(_ seconds: TimeInterval = 60) { lock.withLock { _t += seconds } }
}

/// One simulated Mac: an engine plus the local store's synced state.
@MainActor final class Mac {
    let engine: SyncEngine
    let clock: Clock
    var local: SyncPayload
    var openPages: [OpenPageSummary] = []

    init(_ id: String, server: InMemoryTransport, clock: Clock, stateURL: URL? = nil,
         local: SyncPayload = SyncPayload(pins: [], shelf: [], history: [])) {
        self.clock = clock
        self.local = local
        engine = SyncEngine(transport: server, deviceID: id, deviceName: "Mac \(id)", stateURL: stateURL, now: { clock.t })
    }

    /// Syncs and applies the merged result, like the shell does.
    @discardableResult
    func sync() async throws -> SyncOutcome {
        let o = try await engine.sync(local: local, openPages: openPages)
        if let m = o.merged { local = m }
        return o
    }

    /// Edits the local store and tells the engine, as the coordinator's scheduleSync does.
    func edit(_ change: (inout SyncPayload) -> Void) {
        change(&local)
        engine.recordLocalChanges(local)
    }

    var pinHosts: [String] { local.pins.map(\.key.host) }
    var pinNames: [String] { local.pins.map(\.name) }
    var shelfURLs: [String] { local.shelf.flatMap { $0.pages.map(\.url.absoluteString) } }
}

func url(_ s: String) -> URL { URL(string: s)! }

func makePin(_ host: String, name: String? = nil, at t: Date = Date(timeIntervalSinceReferenceDate: 800_000_000)) -> PinnedSite {
    let home = url("https://\(host)/")
    let page = Page(url: home, name: name ?? host, usage: Usage(at: t))
    return PinnedSite(key: SiteKey(host), name: name ?? host, homeURL: home, page: page)
}

func makeShelfPage(_ s: String, name: String = "Page", at t: Date) -> Page {
    Page(url: url(s), rawTitle: name, name: name, usage: Usage(at: t))
}

func makeEntry(_ host: String, _ pages: [Page], at t: Date) -> ShelfEntry {
    ShelfEntry(key: SiteKey(host), name: host, pages: pages, shelvedAt: t)
}

func makeHistory(_ s: String, at t: Date, dwell: TimeInterval = 0) -> HistoryEntry {
    let u = url(s)
    return HistoryEntry(url: u, title: s, name: s, key: SiteKey(u.host ?? "x"), visitedAt: t, dwell: dwell)
}

func tempStateURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("plinth-sync-tests-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("sync-state.json")
}
