import Foundation
import Testing
import PlinthModel
@testable import PlinthSync

@MainActor @Suite struct HistoryTests {
    let clock = Clock()
    let server = InMemoryTransport()

    @Test func historyIsAUnionByID() async throws {
        let ha = makeHistory("https://a.com/1", at: clock.t)
        clock.advance()
        let hb = makeHistory("https://b.com/1", at: clock.t)
        let a = Mac("A", server: server, clock: clock, local: SyncPayload(pins: [], shelf: [], history: [ha]))
        let b = Mac("B", server: server, clock: clock, local: SyncPayload(pins: [], shelf: [], history: [hb]))
        try await a.sync(); try await b.sync(); try await a.sync()
        #expect(a.local.history == [hb, ha])
        #expect(b.local.history == [hb, ha])
    }

    @Test func syncNeverDeletesHistory() async throws {
        let h1 = makeHistory("https://a.com/1", at: clock.t)
        let a = Mac("A", server: server, clock: clock, local: SyncPayload(pins: [], shelf: [], history: [h1]))
        let b = Mac("B", server: server, clock: clock)
        try await a.sync(); try await b.sync()
        a.edit { $0.history = [] }   // e.g. trimmed locally
        try await a.sync(); try await b.sync()
        #expect(b.local.history == [h1])
        #expect(a.local.history.isEmpty)   // and it is not pushed back onto A either
    }

    @Test func entryUpdatesFromItsOwnMacSync() async throws {
        let h1 = makeHistory("https://a.com/1", at: clock.t)
        let a = Mac("A", server: server, clock: clock, local: SyncPayload(pins: [], shelf: [], history: [h1]))
        let b = Mac("B", server: server, clock: clock)
        try await a.sync(); try await b.sync()
        a.edit { $0.history[0].title = "Real title"; $0.history[0].dwell = 120 }
        try await a.sync(); try await b.sync()
        #expect(b.local.history[0].title == "Real title")
        #expect(b.local.history[0].dwell == 120)
    }

    @Test func clearHistoryRemovesEverythingUpToTheMarkerEverywhere() async throws {
        let old1 = makeHistory("https://a.com/1", at: clock.t)
        let old2 = makeHistory("https://b.com/1", at: clock.t + 1)
        let a = Mac("A", server: server, clock: clock, local: SyncPayload(pins: [], shelf: [], history: [old1]))
        let b = Mac("B", server: server, clock: clock, local: SyncPayload(pins: [], shelf: [], history: [old2]))
        try await a.sync(); try await b.sync(); try await a.sync()
        #expect(a.local.history.count == 2)
        clock.advance()
        a.local.history = []
        a.engine.clearHistory()
        try await a.sync()
        #expect(await server.allRecords.filter { $0.recordType == RecordMapper.historyType }.isEmpty)
        #expect(await server.record(named: RecordMapper.clearName) != nil)
        // B visits something after the clear, then syncs: old entries go, the new one stays.
        clock.advance()
        let fresh = makeHistory("https://c.com/1", at: clock.t)
        b.edit { $0.history.insert(fresh, at: 0) }
        try await b.sync()
        #expect(b.local.history == [fresh])
        try await a.sync()
        #expect(a.local.history == [fresh])
    }

    @Test func historyIsCappedAtTheNewest() async throws {
        var entries: [HistoryEntry] = []
        for i in 0..<8 { entries.insert(makeHistory("https://a.com/\(i)", at: clock.t + Double(i)), at: 0) }
        let a = Mac("A", server: server, clock: clock, local: SyncPayload(pins: [], shelf: [], history: entries))
        let b = Mac("B", server: server, clock: clock)
        a.engine.historyCap = 5
        b.engine.historyCap = 5
        try await a.sync()
        #expect(a.local.history.count == 5)
        #expect(a.local.history.map(\.url.lastPathComponent) == ["7", "6", "5", "4", "3"])
        #expect(await server.allRecords.filter { $0.recordType == RecordMapper.historyType }.count == 5)
        try await b.sync()
        #expect(b.local.history == a.local.history)
        #expect(SyncEngine(transport: server, deviceID: "Z", deviceName: "Z", stateURL: nil).historyCap == 20_000)
    }
}

@MainActor @Suite struct DevicePagesTests {
    let clock = Clock()
    let server = InMemoryTransport()
    let pageA = OpenPageSummary(url: url("https://a.com/"), name: "A", title: "A", key: SiteKey("a.com"))
    let pageB = OpenPageSummary(url: url("https://b.com/"), name: "B", title: "B", key: SiteKey("b.com"))

    @Test func eachMacSeesTheOthersOpenPages() async throws {
        let a = Mac("A", server: server, clock: clock)
        let b = Mac("B", server: server, clock: clock)
        let c = Mac("C", server: server, clock: clock)
        a.openPages = [pageA]
        b.openPages = [pageB]
        try await a.sync()
        clock.advance()
        try await b.sync()
        let o = try await c.sync()
        #expect(o.otherDevices.map(\.deviceID) == ["B", "A"])
        #expect(o.otherDevices.map(\.deviceName) == ["Mac B", "Mac A"])
        #expect(o.otherDevices[0].pages == [pageB])
        let oa = try await a.sync()
        #expect(oa.otherDevices.map(\.deviceID) == ["B", "C"])
        #expect(oa.merged == nil)   // device pages never change the local payload
        #expect(a.engine.otherDevices().map(\.deviceID) == ["B", "C"])
    }

    @Test func otherDevicesRecordsAreReadOnly() async throws {
        let a = Mac("A", server: server, clock: clock)
        let b = Mac("B", server: server, clock: clock)
        b.openPages = [pageB]
        try await b.sync()
        await server.clearLogs()
        a.openPages = [pageA]
        for _ in 0..<3 { clock.advance(SyncEngine.deviceRefreshInterval + 1); try await a.sync() }
        let saved = await server.saveLog.filter { $0.recordType == RecordMapper.deviceType }.map(\.recordName)
        #expect(Set(saved) == ["device-A"])
    }

    @Test func ownRecordUploadsOnlyWhenChangedOrDueForRefresh() async throws {
        let a = Mac("A", server: server, clock: clock)
        a.openPages = [pageA]
        try await a.sync()
        await server.clearLogs()
        clock.advance()
        try await a.sync()
        #expect(await server.saveLog.isEmpty)
        a.openPages = [pageA, pageB]
        try await a.sync()
        #expect(await server.saveLog.map(\.recordName) == ["device-A"])
        clock.advance(SyncEngine.deviceRefreshInterval + 1)
        try await a.sync()
        #expect(await server.saveLog.count == 2)
    }

    @Test func recordsOlderThanThirtyDaysAreIgnored() async throws {
        let a = Mac("A", server: server, clock: clock)
        let b = Mac("B", server: server, clock: clock)
        b.openPages = [pageB]
        try await b.sync()
        #expect(try await a.sync().otherDevices.count == 1)
        clock.advance(SyncEngine.deviceRecordMaxAge + 60)
        #expect(try await a.sync().otherDevices.isEmpty)
        try await b.sync()   // B comes back
        #expect(try await a.sync().otherDevices.map(\.deviceID) == ["B"])
    }
}
