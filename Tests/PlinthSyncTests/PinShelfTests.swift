import Foundation
import Testing
import PlinthModel
@testable import PlinthSync

@MainActor @Suite struct PinTests {
    let clock = Clock()
    let server = InMemoryTransport()

    @Test func pinAddedOnOneMacAppearsOnTheOther() async throws {
        let a = Mac("A", server: server, clock: clock, local: SyncPayload(pins: [makePin("a.com")], shelf: [], history: []))
        let b = Mac("B", server: server, clock: clock)
        try await a.sync()
        let o = try await b.sync()
        #expect(o.merged != nil)
        #expect(b.pinHosts == ["a.com"])
        #expect(b.local.pins[0].page.url.absoluteString == "https://a.com/")
    }

    @Test func pinLiveStateIsNotSynced() async throws {
        let a = Mac("A", server: server, clock: clock, local: SyncPayload(pins: [makePin("a.com")], shelf: [], history: []))
        let b = Mac("B", server: server, clock: clock)
        try await a.sync(); try await b.sync()
        await server.clearLogs()
        a.edit { $0.pins[0].page.scrollY = 800; $0.pins[0].page.url = url("https://a.com/deep"); $0.pins[0].page.dwell = 99 }
        let o = try await a.sync()
        #expect(o.merged == nil)
        #expect(await server.saveLog.filter { $0.recordType == RecordMapper.pinType }.isEmpty)
        // And a remote rename does not touch the local pin page.
        b.edit { $0.pins[0].name = "Renamed" }
        try await b.sync()
        try await a.sync()
        #expect(a.pinNames == ["Renamed"])
        #expect(a.local.pins[0].page.url.absoluteString == "https://a.com/deep")
        #expect(a.local.pins[0].page.scrollY == 800)
    }

    @Test func lastWriterWinsByEditTimeNotSyncOrder() async throws {
        for bSyncsFirst in [false, true] {
            let server = InMemoryTransport()
            let a = Mac("A", server: server, clock: clock, local: SyncPayload(pins: [makePin("a.com")], shelf: [], history: []))
            let b = Mac("B", server: server, clock: clock)
            try await a.sync(); try await b.sync()
            a.edit { $0.pins[0].name = "From A" }
            clock.advance()
            b.edit { $0.pins[0].name = "From B" }   // later edit
            clock.advance()
            if bSyncsFirst { try await b.sync(); try await a.sync() } else { try await a.sync(); try await b.sync() }
            try await a.sync(); try await b.sync()
            #expect(a.pinNames == ["From B"])
            #expect(b.pinNames == ["From B"])
        }
    }

    @Test func deletionTombstoneBeatsOlderEdit() async throws {
        let a = Mac("A", server: server, clock: clock, local: SyncPayload(pins: [makePin("a.com"), makePin("b.com")], shelf: [], history: []))
        let b = Mac("B", server: server, clock: clock)
        try await a.sync(); try await b.sync()
        b.edit { $0.pins[0].name = "Edited" }
        clock.advance()
        a.edit { $0.pins.removeAll { $0.key.host == "a.com" } }   // newer deletion
        try await b.sync()
        try await a.sync()
        try await b.sync()
        #expect(a.pinHosts == ["b.com"])
        #expect(b.pinHosts == ["b.com"])
        #expect(await server.record(named: "pin-a.com")?.isTombstone == true)
    }

    @Test func newerEditBeatsOlderTombstone() async throws {
        let a = Mac("A", server: server, clock: clock, local: SyncPayload(pins: [makePin("a.com")], shelf: [], history: []))
        let b = Mac("B", server: server, clock: clock)
        try await a.sync(); try await b.sync()
        a.edit { $0.pins = [] }
        clock.advance()
        b.edit { $0.pins[0].name = "Kept" }
        try await a.sync()
        try await b.sync()
        try await a.sync()
        #expect(a.pinNames == ["Kept"])
        #expect(b.pinNames == ["Kept"])
    }

    @Test func deletedPinStaysDeletedAndCanBeReAdded() async throws {
        let a = Mac("A", server: server, clock: clock, local: SyncPayload(pins: [makePin("a.com")], shelf: [], history: []))
        let b = Mac("B", server: server, clock: clock)
        try await a.sync(); try await b.sync()
        a.edit { $0.pins = [] }
        try await a.sync(); try await b.sync()
        #expect(b.local.pins.isEmpty)
        clock.advance()
        b.edit { $0.pins = [makePin("a.com", name: "Back")] }
        try await b.sync(); try await a.sync()
        #expect(a.pinNames == ["Back"])
    }

    @Test func orderFollowsWinningOrderField() async throws {
        let a = Mac("A", server: server, clock: clock,
                    local: SyncPayload(pins: [makePin("a.com"), makePin("b.com"), makePin("c.com")], shelf: [], history: []))
        let b = Mac("B", server: server, clock: clock)
        try await a.sync(); try await b.sync()
        #expect(b.pinHosts == ["a.com", "b.com", "c.com"])
        a.edit { $0.pins = [$0.pins[2], $0.pins[0], $0.pins[1]] }
        try await a.sync(); try await b.sync()
        #expect(b.pinHosts == ["c.com", "a.com", "b.com"])
    }

    @Test func concurrentAddsConvergeToOneOrder() async throws {
        let a = Mac("A", server: server, clock: clock, local: SyncPayload(pins: [makePin("a.com")], shelf: [], history: []))
        let b = Mac("B", server: server, clock: clock)
        try await a.sync(); try await b.sync()
        a.edit { $0.pins.append(makePin("x.com")) }
        b.edit { $0.pins.append(makePin("y.com")) }
        try await a.sync(); try await b.sync(); try await a.sync(); try await b.sync()
        #expect(a.pinHosts == b.pinHosts)
        #expect(Set(a.pinHosts) == ["a.com", "x.com", "y.com"])
        await server.clearLogs()
        try await a.sync(); try await b.sync()
        #expect(await server.saveLog.isEmpty)
    }

    @Test func tieBreakIsDeterministicByDeviceID() async throws {
        let a = Mac("A", server: server, clock: clock, local: SyncPayload(pins: [makePin("a.com")], shelf: [], history: []))
        let b = Mac("B", server: server, clock: clock)
        try await a.sync(); try await b.sync()
        // Same clock reading on both Macs: "B" > "A", so B's edit wins whichever syncs first.
        a.edit { $0.pins[0].name = "A says" }
        b.edit { $0.pins[0].name = "B says" }
        try await a.sync(); try await b.sync(); try await a.sync()
        #expect(a.pinNames == ["B says"])
        #expect(b.pinNames == ["B says"])
    }

    @Test func serverConflictIsReMerged() async throws {
        let a = Mac("A", server: server, clock: clock, local: SyncPayload(pins: [makePin("a.com")], shelf: [], history: []))
        try await a.sync()
        a.edit { $0.pins[0].name = "Local edit" }
        clock.advance()
        // Another Mac saves a newer version between A's fetch and A's save.
        var newer = await server.record(named: "pin-a.com")!
        newer.fields["name"] = .string("Remote newer")
        newer.modifiedAt = clock.t; newer.modifiedBy = "C"
        await server.injectBeforeNextModify(newer)
        let o = try await a.sync()
        #expect(o.merged?.pins.map(\.name) == ["Remote newer"])
        #expect(await server.record(named: "pin-a.com")?["name"]?.stringValue == "Remote newer")

        // An older injected version loses: the local edit is saved over it.
        clock.advance()
        a.edit { $0.pins[0].name = "Newest local" }
        var older = await server.record(named: "pin-a.com")!
        older.fields["name"] = .string("Stale remote")
        older.modifiedAt = clock.t - 3600; older.modifiedBy = "C"
        await server.injectBeforeNextModify(older)
        try await a.sync()
        #expect(a.pinNames == ["Newest local"])
        #expect(await server.record(named: "pin-a.com")?["name"]?.stringValue == "Newest local")
    }
}

@MainActor @Suite struct ShelfTests {
    let clock = Clock()
    let server = InMemoryTransport()

    @Test func shelvedPageAppearsAndRestoreBecomesTombstone() async throws {
        let p = makeShelfPage("https://a.com/1", name: "One", at: clock.t)
        let a = Mac("A", server: server, clock: clock, local: SyncPayload(pins: [], shelf: [makeEntry("a.com", [p], at: clock.t)], history: []))
        let b = Mac("B", server: server, clock: clock)
        try await a.sync(); try await b.sync()
        #expect(b.shelfURLs == ["https://a.com/1"])
        #expect(b.local.shelf[0].pages[0].id == p.id)
        // B restores it to its bar: it leaves the shelf on every Mac.
        clock.advance()
        b.edit { $0.shelf = [] }
        try await b.sync(); try await a.sync()
        #expect(a.local.shelf.isEmpty)
        #expect(await server.record(named: RecordMapper.shelfName(p.id))?.isTombstone == true)
    }

    @Test func sameKeyShelvedOnTwoMacsIsOneEntry() async throws {
        let a = Mac("A", server: server, clock: clock,
                    local: SyncPayload(pins: [], shelf: [makeEntry("a.com", [makeShelfPage("https://a.com/1", at: clock.t)], at: clock.t)], history: []))
        clock.advance()
        let b = Mac("B", server: server, clock: clock,
                    local: SyncPayload(pins: [], shelf: [makeEntry("a.com", [makeShelfPage("https://a.com/2", at: clock.t)], at: clock.t)], history: []))
        try await a.sync(); try await b.sync(); try await a.sync()
        for mac in [a, b] {
            #expect(mac.local.shelf.count == 1)
            #expect(mac.shelfURLs == ["https://a.com/2", "https://a.com/1"])
        }
        #expect(a.local.shelf[0].shelvedAt == b.local.shelf[0].shelvedAt)
        await server.clearLogs()
        try await a.sync(); try await b.sync()
        #expect(await server.saveLog.isEmpty)
    }

    @Test func pageEditsAreLastWriterWinsPerPage() async throws {
        let p = makeShelfPage("https://a.com/1", name: "One", at: clock.t)
        let a = Mac("A", server: server, clock: clock, local: SyncPayload(pins: [], shelf: [makeEntry("a.com", [p], at: clock.t)], history: []))
        let b = Mac("B", server: server, clock: clock)
        try await a.sync(); try await b.sync()
        b.edit { $0.shelf[0].pages[0].customName = "Old rename" }
        clock.advance()
        a.edit { $0.shelf[0].pages[0].customName = "New rename"; $0.shelf[0].pages[0].name = "New rename" }
        try await a.sync(); try await b.sync(); try await a.sync()
        #expect(b.local.shelf[0].pages[0].customName == "New rename")
        #expect(a.local.shelf[0].pages[0].customName == "New rename")
    }

    @Test func duplicateURLsInOneEntryAreShownOnce() async throws {
        let a = Mac("A", server: server, clock: clock,
                    local: SyncPayload(pins: [], shelf: [makeEntry("a.com", [makeShelfPage("https://a.com/same", at: clock.t)], at: clock.t)], history: []))
        clock.advance()
        let b = Mac("B", server: server, clock: clock,
                    local: SyncPayload(pins: [], shelf: [makeEntry("a.com", [makeShelfPage("https://a.com/same", at: clock.t)], at: clock.t)], history: []))
        try await a.sync(); try await b.sync(); try await a.sync()
        #expect(a.shelfURLs == ["https://a.com/same"])
        #expect(b.shelfURLs == ["https://a.com/same"])
        #expect(a.local.shelf[0].pages[0].id == b.local.shelf[0].pages[0].id)
        await server.clearLogs()
        try await a.sync(); try await b.sync()
        #expect(await server.saveLog.isEmpty)
    }
}
