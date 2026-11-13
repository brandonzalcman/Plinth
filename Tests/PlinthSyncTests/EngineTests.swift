import Foundation
import Testing
import PlinthModel
@testable import PlinthSync

@MainActor @Suite struct EngineTests {
    let clock = Clock()
    let server = InMemoryTransport()

    func fullPayload() -> SyncPayload {
        SyncPayload(pins: [makePin("a.com"), makePin("b.com")],
                    shelf: [makeEntry("c.com", [makeShelfPage("https://c.com/1", at: clock.t), makeShelfPage("https://c.com/2", at: clock.t)], at: clock.t)],
                    history: [makeHistory("https://d.com/1", at: clock.t)])
    }

    @Test func secondSyncWithNoChangesUploadsNothing() async throws {
        let a = Mac("A", server: server, clock: clock, local: fullPayload())
        a.openPages = [OpenPageSummary(url: url("https://a.com/"), name: "A", title: "A", key: SiteKey("a.com"))]
        let first = try await a.sync()
        #expect(first.merged == nil)   // nothing remote to merge in
        #expect(await server.saveLog.count == 2 + 2 + 1 + 1)
        await server.clearLogs()
        clock.advance()
        let second = try await a.sync()
        #expect(second.merged == nil)
        #expect(await server.modifyCalls == 0)
        // A second Mac that pulls everything is idempotent too.
        let b = Mac("B", server: server, clock: clock)
        try await b.sync()
        await server.clearLogs()
        let again = try await b.sync()
        #expect(again.merged == nil)
        #expect(await server.saveLog.isEmpty)
        #expect(b.local.pins.map(\.key) == a.local.pins.map(\.key))
        #expect(Set(b.shelfURLs) == Set(a.shelfURLs))
        #expect(b.local.history == a.local.history)
    }

    @Test func identicalDataOnTwoMacsDoesNotFight() async throws {
        let payload = fullPayload()
        let a = Mac("A", server: server, clock: clock, local: payload)
        let b = Mac("B", server: server, clock: clock, local: payload)
        try await a.sync()
        await server.clearLogs()
        let o = try await b.sync()
        #expect(o.merged == nil)
        #expect(await server.saveLog.map(\.recordType) == [RecordMapper.deviceType])
    }

    @Test func baseStatePersistsAcrossLaunches() async throws {
        let stateURL = tempStateURL()
        defer { try? FileManager.default.removeItem(at: stateURL.deletingLastPathComponent()) }
        let a = Mac("A", server: server, clock: clock, stateURL: stateURL, local: fullPayload())
        let b = Mac("B", server: server, clock: clock)
        try await a.sync(); try await b.sync()
        #expect(FileManager.default.fileExists(atPath: stateURL.path))

        // Relaunch A: nothing to upload, and a local deletion is still recognised as one.
        let relaunched = Mac("A", server: server, clock: clock, stateURL: stateURL, local: a.local)
        await server.clearLogs()
        let o = try await relaunched.sync()
        #expect(o.merged == nil)
        #expect(await server.saveLog.isEmpty)
        clock.advance()
        relaunched.edit { $0.pins.removeAll { $0.key.host == "a.com" } }
        try await relaunched.sync()
        try await b.sync()
        #expect(b.pinHosts == ["b.com"])

        // Without the saved base, the same deletion would look like a missing pin and come back.
        let amnesiac = Mac("A", server: server, clock: clock, local: SyncPayload(pins: [], shelf: [], history: []))
        try await amnesiac.sync()
        #expect(amnesiac.pinHosts == ["b.com"])
    }

    @Test func pendingEditsSurviveARelaunchBeforeSyncing() async throws {
        let stateURL = tempStateURL()
        defer { try? FileManager.default.removeItem(at: stateURL.deletingLastPathComponent()) }
        let a = Mac("A", server: server, clock: clock, stateURL: stateURL, local: fullPayload())
        let b = Mac("B", server: server, clock: clock)
        try await a.sync(); try await b.sync()
        a.edit { $0.pins[0].name = "Early edit" }   // stamped now, not synced
        clock.advance()
        b.edit { $0.pins[0].name = "Later edit" }
        try await b.sync()
        let relaunched = Mac("A", server: server, clock: clock, stateURL: stateURL, local: a.local)
        clock.advance()
        try await relaunched.sync()
        #expect(relaunched.pinNames.first == "Later edit")   // A's edit kept its original, older time
    }

    @Test func failedSyncChangesNothingAndTheNextOneCatchesUp() async throws {
        let a = Mac("A", server: server, clock: clock, local: fullPayload())
        let b = Mac("B", server: server, clock: clock)
        try await a.sync(); try await b.sync()
        a.edit { $0.pins[0].name = "Renamed" }
        await server.failNext(1)
        await #expect(throws: SyncError.self) { try await a.sync() }
        #expect(a.pinNames.first == "Renamed")
        try await a.sync()
        try await b.sync()
        #expect(b.pinNames.first == "Renamed")
    }

    @Test func failureAfterFetchDoesNotLoseRemoteChanges() async throws {
        let stateURL = tempStateURL()
        defer { try? FileManager.default.removeItem(at: stateURL.deletingLastPathComponent()) }
        let a = Mac("A", server: server, clock: clock, stateURL: stateURL, local: fullPayload())
        let b = Mac("B", server: server, clock: clock)
        try await a.sync(); try await b.sync()
        b.edit { $0.pins.append(makePin("z.com")) }
        try await b.sync()
        a.edit { $0.pins[0].name = "Local" }
        // Same Mac, but this time the fetch works and the save fails.
        let flaky = SyncEngine(transport: FailingSave(inner: server), deviceID: "A", deviceName: "Mac A",
                               stateURL: stateURL, now: { clock.t })
        await #expect(throws: SyncError.self) { try await flaky.sync(local: a.local, openPages: []) }
        let retry = Mac("A", server: server, clock: clock, stateURL: stateURL, local: a.local)
        try await retry.sync()
        #expect(retry.pinHosts == ["a.com", "b.com", "z.com"])
        #expect(retry.pinNames.first == "Local")
        try await b.sync()
        #expect(b.pinNames.first == "Local")
    }

    @Test func expiredTokenRefetchesEverything() async throws {
        let a = Mac("A", server: server, clock: clock, local: fullPayload())
        let b = Mac("B", server: server, clock: clock)
        try await a.sync(); try await b.sync()
        a.edit { $0.pins.append(makePin("new.com")) }
        try await a.sync()
        await server.expireTokenOnNextFetch()
        await server.clearLogs()
        try await b.sync()
        #expect(b.pinHosts.contains("new.com"))
        #expect(await server.saveLog.isEmpty)
    }

    @Test func serverResetReuploadsEverything() async throws {
        let a = Mac("A", server: server, clock: clock, local: fullPayload())
        try await a.sync()
        await server.reset()
        let o = try await a.sync()
        #expect(o.merged == nil)
        let types = await server.allRecords.map(\.recordType)
        #expect(types.filter { $0 == RecordMapper.pinType }.count == 2)
        #expect(types.filter { $0 == RecordMapper.shelfType }.count == 2)
        #expect(types.filter { $0 == RecordMapper.historyType }.count == 1)
        let b = Mac("B", server: server, clock: clock)
        try await b.sync()
        #expect(b.pinHosts == ["a.com", "b.com"])
    }

    @Test func pagedFetchesAreFollowed() async throws {
        await server.setPageSize(2)
        let a = Mac("A", server: server, clock: clock, local: fullPayload())
        let b = Mac("B", server: server, clock: clock)
        try await a.sync(); try await b.sync()
        #expect(b.pinHosts == ["a.com", "b.com"])
        #expect(b.shelfURLs.count == 2)
        #expect(b.local.history.count == 1)
    }

    @Test func mergeNotAppliedKeepsRemoteChangesAndNewLocalEdits() async throws {
        let a = Mac("A", server: server, clock: clock, local: fullPayload())
        let b = Mac("B", server: server, clock: clock)
        try await a.sync(); try await b.sync()
        b.edit { $0.pins.append(makePin("remote.com")); $0.history.insert(makeHistory("https://r.com/", at: clock.t + 5), at: 0) }
        try await b.sync()
        // A syncs but the user changed something during the sync, so the result is not applied.
        let o = try await a.engine.sync(local: a.local, openPages: [])
        #expect(o.merged?.pins.contains { $0.key.host == "remote.com" } == true)
        a.engine.mergeNotApplied()
        clock.advance()
        a.local.pins[0].name = "Edited during sync"
        try await a.sync()
        #expect(a.pinHosts.contains("remote.com"))
        #expect(a.pinNames.first == "Edited during sync")
        #expect(a.local.history.contains { $0.url.host == "r.com" })
        try await b.sync()
        #expect(b.pinNames.first == "Edited during sync")
        #expect(b.pinHosts.contains("remote.com"))
    }

    @Test func concurrentSyncIsRefused() async throws {
        let a = Mac("A", server: server, clock: clock, local: fullPayload())
        func attempt() async -> Result<SyncOutcome, Error> {
            do { return .success(try await a.engine.sync(local: a.local, openPages: [])) } catch { return .failure(error) }
        }
        async let first = attempt()
        async let second = attempt()
        let results = await [first, second]
        let busy = results.filter { if case .failure(let e) = $0 { return (e as? SyncError) == .busy }; return false }
        #expect(busy.count == 1)
    }
}

/// A transport whose saves always fail (fetches pass through).
actor FailingSave: SyncTransport {
    let inner: InMemoryTransport
    init(inner: InMemoryTransport) { self.inner = inner }
    func fetchChanges(since token: Data?) async throws -> SyncChangeSet { try await inner.fetchChanges(since: token) }
    func modify(saving: [SyncRecord], deleting: [SyncRecordID]) async throws -> SyncModifyResult {
        throw SyncError.transport("save failed")
    }
}
