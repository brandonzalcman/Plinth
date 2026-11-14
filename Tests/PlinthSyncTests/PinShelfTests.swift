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

/// CloudKit keeps a key a save does not mention; `InMemoryTransport` replaces the whole record.
/// This wraps it so a save merges onto the stored record's fields, like CloudKit does.
struct KeyKeepingTransport: SyncTransport {
    let base: InMemoryTransport
    func fetchChanges(since token: Data?) async throws -> SyncChangeSet { try await base.fetchChanges(since: token) }
    func modify(saving: [SyncRecord], deleting: [SyncRecordID]) async throws -> SyncModifyResult {
        var merged = saving
        for i in merged.indices where !merged[i].isTombstone {
            if let current = await base.record(named: merged[i].recordName), !current.isTombstone {
                var kept = current.fields
                for key in (RecordMapper.fieldKeys[merged[i].recordType] ?? []) + (merged[i].clearKeys ?? []) where merged[i].fields[key] == nil { kept[key] = nil }
                merged[i].fields = kept.merging(merged[i].fields) { _, new in new }
            }
        }
        return try await base.modify(saving: merged, deleting: deleting)
    }
}

/// Lets a test make saves of one record type fail the way CloudKit reports a per-record failure.
final class FlakyTransport: SyncTransport, @unchecked Sendable {
    let base: any SyncTransport
    var failingType: String?
    init(base: any SyncTransport) { self.base = base }
    func fetchChanges(since token: Data?) async throws -> SyncChangeSet { try await base.fetchChanges(since: token) }
    func modify(saving: [SyncRecord], deleting: [SyncRecordID]) async throws -> SyncModifyResult {
        guard let failingType else { return try await base.modify(saving: saving, deleting: deleting) }
        var result = try await base.modify(saving: saving.filter { $0.recordType != failingType }, deleting: deleting)
        for r in saving where r.recordType == failingType { result.failed[r.id] = "injected" }
        return result
    }
}

/// A 0.2.0 client: its engine does not know the `PinFolder` record type, so it never reads or writes
/// it. (The engine itself is the current one; only what a 0.2.0 engine would never see is hidden.)
struct OldClientTransport: SyncTransport {
    let base: any SyncTransport
    func fetchChanges(since token: Data?) async throws -> SyncChangeSet {
        var cs = try await base.fetchChanges(since: token)
        cs.changed.removeAll { $0.recordType == RecordMapper.folderType }
        cs.deleted.removeAll { $0.recordType == RecordMapper.folderType }
        return cs
    }
    func modify(saving: [SyncRecord], deleting: [SyncRecordID]) async throws -> SyncModifyResult {
        try await base.modify(saving: saving, deleting: deleting)
    }
}

@MainActor @Suite struct PinFolderSyncTests {
    let clock = Clock()
    let server = InMemoryTransport()

    func pins(_ hosts: [String], folder f: PinFolder? = nil, in members: Set<String> = []) -> [PinnedSite] {
        hosts.map { h in var p = makePin(h); if members.contains(h) { p.folder = f }; return p }
    }
    func payload(_ p: [PinnedSite]) -> SyncPayload { SyncPayload(pins: p, shelf: [], history: []) }
    func folderLayout(_ m: Mac) -> [String] { m.local.pins.map { $0.key.host + ($0.folder.map { "@" + $0.name } ?? "") } }

    @Test func foldersAreTheirOwnRecordsAndPinRecordsStayAsInZeroTwoZero() {
        let f = PinFolder(name: "Work")
        let p = pins(["a.com", "b.com", "c.com"], folder: f, in: ["a.com", "c.com"])
        let pinRecords = RecordMapper.pinRecords(p)
        #expect(pinRecords.allSatisfy { Set($0.fields.keys) == ["key", "name", "homeURL", "order"] })
        let folders = RecordMapper.folderRecords(p)
        #expect(folders.count == 1)
        #expect(folders[0].recordName == "folder-" + f.id.uuidString)
        #expect(folders[0].fields["name"]?.stringValue == "Work")
        #expect(folders[0].fields["members"]?.stringsValue == ["a.com", "c.com"])
        let back = RecordMapper.pins(from: pinRecords + folders, local: [], now: Date())
        #expect(back.map(\.key.host) == ["a.com", "c.com", "b.com"])
        #expect(back.map(\.folder) == [f, f, nil])
    }

    @Test func folderSyncsBetweenMacsRenamesAndEmpties() async throws {
        let f = PinFolder(name: "Work")
        let a = Mac("A", server: server, clock: clock, local: payload(pins(["a.com", "b.com", "c.com"], folder: f, in: ["a.com", "c.com"])))
        let b = Mac("B", server: server, clock: clock)
        try await a.sync(); try await b.sync()
        #expect(folderLayout(b) == ["a.com@Work", "c.com@Work", "b.com"])
        b.edit { p in for i in p.pins.indices where p.pins[i].folder != nil { p.pins[i].folder?.name = "Reading" } }
        clock.advance()
        try await b.sync(); try await a.sync()
        #expect(folderLayout(a) == ["a.com@Reading", "c.com@Reading", "b.com"])
        a.edit { p in for i in p.pins.indices { p.pins[i].folder = nil } }
        clock.advance()
        try await a.sync(); try await b.sync()
        #expect(b.local.pins.allSatisfy { $0.folder == nil })
        let leftover = await server.allRecords.filter { $0.recordType == RecordMapper.folderType && !$0.isTombstone }
        #expect(leftover.isEmpty)
    }

    @Test func unrelatedPinEditDoesNotRevertAFolderMove() async throws {
        let hosts = ["a.com", "b.com", "c.com", "d.com", "e.com"]
        let a = Mac("A", server: server, clock: clock, local: payload(pins(hosts)))
        let b = Mac("B", server: server, clock: clock)
        try await a.sync(); try await b.sync()
        // A puts d and e in a new folder; B, not yet synced, unpins b (every later pin's order shifts).
        let f = PinFolder(name: "Work")
        a.edit { p in for i in p.pins.indices where ["d.com", "e.com"].contains(p.pins[i].key.host) { p.pins[i].folder = f } }
        clock.advance()
        b.edit { $0.pins.remove(at: 1) }
        clock.advance()
        try await a.sync(); try await b.sync(); try await a.sync(); try await b.sync()
        #expect(folderLayout(a) == ["a.com", "c.com", "d.com@Work", "e.com@Work"])
        #expect(folderLayout(b) == folderLayout(a))
    }

    @Test func renameSurvivesAnUnrelatedUnpinOnAnotherMac() async throws {
        let f = PinFolder(name: "Work")
        let a = Mac("A", server: server, clock: clock, local: payload(pins(["a.com", "b.com", "c.com", "d.com"], folder: f, in: ["c.com", "d.com"])))
        let b = Mac("B", server: server, clock: clock)
        try await a.sync(); try await b.sync()
        a.edit { p in for i in p.pins.indices where p.pins[i].folder != nil { p.pins[i].folder?.name = "Reading" } }
        clock.advance()
        b.edit { $0.pins.remove(at: 0) }
        clock.advance()
        try await a.sync(); try await b.sync(); try await a.sync(); try await b.sync()
        #expect(folderLayout(a) == ["b.com", "c.com@Reading", "d.com@Reading"])
        #expect(folderLayout(b) == folderLayout(a))
    }

    @Test func foldersCreatedOfflineOnTwoMacsBothSurvive() async throws {
        let base = pins(["a.com", "b.com", "c.com", "d.com"])
        let a = Mac("A", server: server, clock: clock, local: payload(base))
        let b = Mac("B", server: server, clock: clock)
        try await a.sync(); try await b.sync()
        let fa = PinFolder(name: "Folder"), fb = PinFolder(name: "Folder")
        a.edit { p in for i in [0, 1] { p.pins[i].folder = fa } }
        b.edit { p in for i in [2, 3] { p.pins[i].folder = fb } }
        clock.advance()
        try await a.sync(); try await b.sync(); try await a.sync()
        #expect(Set(a.local.pins.compactMap(\.folder?.id)).count == 2)
        #expect(folderLayout(a) == folderLayout(b))
        #expect(a.local.pins.allSatisfy { $0.folder != nil })
    }

    @Test func aPinInTwoFoldersGoesToTheLaterEdit() async throws {
        let base = pins(["a.com", "b.com", "c.com"])
        let a = Mac("A", server: server, clock: clock, local: payload(base))
        let b = Mac("B", server: server, clock: clock)
        try await a.sync(); try await b.sync()
        let fa = PinFolder(name: "FromA"), fb = PinFolder(name: "FromB")
        a.edit { p in p.pins[0].folder = fa; p.pins[1].folder = fa }
        clock.advance()
        b.edit { p in p.pins[1].folder = fb; p.pins[2].folder = fb }
        clock.advance()
        try await a.sync(); try await b.sync(); try await a.sync(); try await b.sync()
        #expect(folderLayout(a) == folderLayout(b))
        #expect(folderLayout(a) == ["a.com@FromA", "b.com@FromB", "c.com@FromB"])
    }

    // MARK: A 0.2.0 client alongside

    func oldClient(_ id: String) -> Mac {
        Mac(id, server: OldClientTransport(base: KeyKeepingTransport(base: server)), clock: clock)
    }

    @Test func oldClientSyncsFoldersWithoutChurn() async throws {
        let f = PinFolder(name: "Work")
        let new = Mac("N", server: server, clock: clock, local: payload(pins(["a.com", "b.com", "c.com", "d.com"], folder: f, in: ["b.com", "c.com"])))
        try await new.sync()
        let old = oldClient("O")
        try await old.sync()
        #expect(old.pinHosts.sorted() == ["a.com", "b.com", "c.com", "d.com"])
        #expect(old.local.pins.allSatisfy { $0.folder == nil })
        // With nothing changed, another sync on either Mac writes nothing to the pins or folders.
        await server.clearLogs()
        try await old.sync(); try await new.sync(); try await old.sync()
        #expect(await server.saveLog.filter { $0.recordType == RecordMapper.pinType || $0.recordType == RecordMapper.folderType }.isEmpty)
    }

    @Test func oldClientReorderAndUnpinDoNotChangeMembership() async throws {
        let f = PinFolder(name: "Work")
        let new = Mac("N", server: server, clock: clock, local: payload(pins(["a.com", "b.com", "c.com", "d.com", "e.com"], folder: f, in: ["d.com", "e.com"])))
        try await new.sync()
        let old = oldClient("O")
        try await old.sync()
        clock.advance()
        old.edit { p in p.pins.remove(at: 1); p.pins.reverse() }   // unpin b, reverse the rest
        clock.advance()
        try await old.sync(); try await new.sync(); try await old.sync(); try await new.sync()
        #expect(Set(new.local.pins.filter { $0.folder != nil }.map(\.key.host)) == ["d.com", "e.com"])
        #expect(new.local.pins.contains { $0.key.host == "b.com" } == false)
        #expect(new.local.pins.first { $0.folder != nil }?.folder == f)
    }

    // MARK: Per-member merge and leftovers

    /// What a 0.2.0 client compares: every key on the fetched record counts.
    func pinRecordsHaveExactlyTheFourFields() async -> Bool {
        await server.allRecords.filter { $0.recordType == RecordMapper.pinType && !$0.isTombstone }
            .allSatisfy { Set($0.fields.keys) == ["key", "name", "homeURL", "order"] }
    }

    @Test func leftoverFolderFieldsAreCleanedOnceThenQuiet() async throws {
        // A main build with the first folder PR wrote folderID/folderName on Pin records.
        let keeping = KeyKeepingTransport(base: server)
        let a = Mac("A", server: keeping, clock: clock, local: payload(pins(["a.com", "b.com"])))
        try await a.sync()
        for name in ["pin-a.com", "pin-b.com"] {
            var rec = try #require(await server.record(named: name))
            rec.fields["folderID"] = .string(UUID().uuidString)
            rec.fields["folderName"] = .string("Old")
            _ = try await server.modify(saving: [rec], deleting: [])
        }
        #expect(await !pinRecordsHaveExactlyTheFourFields())
        await server.clearLogs()
        try await a.sync()
        #expect(await server.saveLog.filter { $0.recordType == RecordMapper.pinType }.count == 2)
        #expect(await pinRecordsHaveExactlyTheFourFields())
        await server.clearLogs()
        for _ in 0..<4 { try await a.sync() }
        #expect(await server.saveLog.filter { $0.recordType == RecordMapper.pinType }.isEmpty)
        let b = Mac("B", server: keeping, clock: clock)
        try await b.sync()
        #expect(b.pinHosts == ["a.com", "b.com"] && b.local.pins.allSatisfy { $0.folder == nil })
        await server.clearLogs()
        for _ in 0..<3 { try await b.sync() }
        #expect(await server.saveLog.filter { $0.recordType == RecordMapper.pinType }.isEmpty)
    }

    @Test func engineStateSavedByTheFirstFolderBuildUploadsOncePerPinThenGoesQuiet() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("plinth-sync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let stateURL = dir.appendingPathComponent("sync.json")
        let keeping = KeyKeepingTransport(base: server)
        let first = Mac("A", server: keeping, clock: clock, stateURL: stateURL, local: payload(pins(["a.com", "b.com", "c.com"])))
        try await first.sync()
        // Rewrite the saved base the way that build left it: two extra fields on every Pin record.
        var root = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any])
        func addLegacy(_ table: Any?) -> [String: Any] {
            var out = (table as? [String: Any]) ?? [:]
            for (name, value) in out where name.hasPrefix("pin-") {
                var rec = value as! [String: Any]
                var fields = rec["fields"] as! [String: Any]
                fields["folderID"] = ["string": ["_0": UUID().uuidString]]
                fields["folderName"] = ["string": ["_0": "Old"]]
                rec["fields"] = fields
                out[name] = rec
            }
            return out
        }
        root["server"] = addLegacy(root["server"]); root["localRef"] = addLegacy(root["localRef"])
        try JSONSerialization.data(withJSONObject: root).write(to: stateURL)
        for name in ["pin-a.com", "pin-b.com", "pin-c.com"] {
            var rec = try #require(await server.record(named: name))
            rec.fields["folderID"] = .string(UUID().uuidString); rec.fields["folderName"] = .string("Old")
            _ = try await server.modify(saving: [rec], deleting: [])
        }
        let upgraded = Mac("A", server: keeping, clock: clock, stateURL: stateURL, local: first.local)
        await server.clearLogs()
        try await upgraded.sync()
        #expect(await server.saveLog.filter { $0.recordType == RecordMapper.pinType }.count == 3)
        #expect(await pinRecordsHaveExactlyTheFourFields())
        await server.clearLogs()
        for _ in 0..<3 { try await upgraded.sync() }
        let later = await server.saveLog.filter { $0.recordType != RecordMapper.deviceType }
        #expect(later.isEmpty)
    }

    @Test func concurrentAddAndRemoveOfDifferentMembersBothSurvive() async throws {
        let f = PinFolder(name: "Work")
        let a = Mac("A", server: server, clock: clock, local: payload(pins(["a.com", "b.com", "c.com", "d.com"], folder: f, in: ["a.com", "b.com"])))
        let b = Mac("B", server: server, clock: clock)
        try await a.sync(); try await b.sync()
        a.edit { p in p.pins[2].folder = f }                       // A adds c to Work
        clock.advance()
        b.edit { p in p.pins.remove(at: 0) }                       // B, offline, unpins a (a member)
        clock.advance()
        try await a.sync(); try await b.sync(); try await a.sync(); try await b.sync()
        #expect(folderLayout(a) == ["b.com@Work", "c.com@Work", "d.com"])
        #expect(folderLayout(b) == folderLayout(a))
    }

    @Test func ungroupAndAddMerge() async throws {
        let f = PinFolder(name: "Work")
        let a = Mac("A", server: server, clock: clock, local: payload(pins(["a.com", "b.com", "c.com"], folder: f, in: ["a.com", "b.com"])))
        let b = Mac("B", server: server, clock: clock)
        try await a.sync(); try await b.sync()
        a.edit { p in p.pins[2].folder = f }
        clock.advance()
        b.edit { p in for i in p.pins.indices { p.pins[i].folder = nil } }   // B ungroups
        clock.advance()
        try await a.sync(); try await b.sync(); try await a.sync(); try await b.sync()
        // Only the pin A added is still in a folder.
        #expect(folderLayout(a) == ["a.com", "b.com", "c.com@Work"])
        #expect(folderLayout(b) == folderLayout(a))
    }

    @Test func derivedRewriteDoesNotOverrideAnOlderRename() async throws {
        let f = PinFolder(name: "Work")
        let a = Mac("A", server: server, clock: clock, local: payload(pins(["a.com", "b.com", "c.com"], folder: f, in: ["a.com", "b.com", "c.com"])))
        try await a.sync()
        let b = Mac("B", server: server, clock: clock)
        try await b.sync()
        let old = oldClient("O")
        try await old.sync()
        a.edit { p in for i in p.pins.indices { p.pins[i].folder?.name = "Renamed" } }   // not synced yet
        clock.advance()
        old.edit { p in p.pins.removeAll { $0.key.host == "c.com" } }                    // a 0.2.0 unpin leaves c listed
        try await old.sync()
        clock.advance()
        try await b.sync()                                                              // B drops the dangling member
        clock.advance()
        try await a.sync(); try await b.sync(); try await a.sync()
        #expect(folderLayout(a) == ["a.com@Renamed", "b.com@Renamed"])
        #expect(folderLayout(b) == folderLayout(a))
    }

    @Test func oldClientReorderInsideAFolderSticks() async throws {
        let f = PinFolder(name: "Work")
        let new = Mac("N", server: server, clock: clock, local: payload(pins(["a.com", "b.com", "c.com"], folder: f, in: ["a.com", "b.com", "c.com"])))
        try await new.sync()
        let old = oldClient("O")
        try await old.sync()
        clock.advance()
        old.edit { $0.pins.reverse() }
        clock.advance()
        try await old.sync(); try await new.sync(); try await old.sync(); try await new.sync()
        #expect(new.pinHosts == ["c.com", "b.com", "a.com"])
    }

    @Test func laterRenameWinsEvenAfterAnotherMacEditsMembers() async throws {
        let f = PinFolder(name: "Work")
        let a = Mac("A", server: server, clock: clock, local: payload(pins(["a.com", "b.com", "c.com"], folder: f, in: ["a.com", "b.com"])))
        let b = Mac("B", server: server, clock: clock)
        try await a.sync(); try await b.sync()
        b.edit { p in for i in p.pins.indices where p.pins[i].folder != nil { p.pins[i].folder?.name = "B-name" } }
        try await b.sync()
        clock.advance()
        a.edit { p in for i in p.pins.indices where p.pins[i].folder != nil { p.pins[i].folder?.name = "A-name" } }   // later, offline
        clock.advance()
        b.edit { p in p.pins[2].folder = p.pins[0].folder }       // B adds c: bumps the record's own time
        try await b.sync()
        clock.advance()
        try await a.sync(); try await b.sync(); try await a.sync()
        #expect(folderLayout(a) == ["a.com@A-name", "b.com@A-name", "c.com@A-name"])
        #expect(folderLayout(b) == folderLayout(a))
    }

    @Test func retryAfterAConflictDoesNotBringBackARemovedMember() async throws {
        let f = PinFolder(name: "Work")
        let a = Mac("A", server: server, clock: clock, local: payload(pins(["a.com", "b.com", "c.com", "d.com"], folder: f, in: ["a.com", "b.com"])))
        let x = Mac("X", server: server, clock: clock)
        try await a.sync(); try await x.sync()
        x.edit { p in p.pins[2].folder = f }                      // X adds c
        clock.advance()
        try await x.sync()
        clock.advance()
        a.edit { p in p.pins[3].folder = f }                      // A adds d
        // Before A's merged save, another Mac removes c again: the save is refused and A merges again.
        var removed = try #require(await server.record(named: "folder-" + f.id.uuidString))
        removed.fields["members"] = .strings(["a.com", "b.com"])
        removed.modifiedAt = clock.t.addingTimeInterval(30); removed.modifiedBy = "Y"
        await server.injectBeforeNextModify(removed)
        try await a.sync(); try await x.sync(); try await a.sync()
        #expect(folderLayout(a) == ["a.com@Work", "b.com@Work", "d.com@Work", "c.com"])
        #expect(folderLayout(x) == folderLayout(a))
    }

    @Test func aFolderRecordAheadOfAMembersPinIsNotRewrittenWithoutIt() async throws {
        let f = PinFolder(name: "Work")
        let a = Mac("A", server: server, clock: clock, local: payload(pins(["a.com", "b.com"], folder: f, in: ["a.com", "b.com"])))
        try await a.sync()
        var ahead = try #require(await server.record(named: "folder-" + f.id.uuidString))
        ahead.fields["members"] = .strings(["a.com", "b.com", "z.com"])
        ahead.modifiedAt = clock.t.addingTimeInterval(5)
        _ = try await server.modify(saving: [ahead], deleting: [])
        let b = Mac("B", server: server, clock: clock)
        await server.clearLogs()
        try await b.sync(); try await b.sync()
        #expect(await server.saveLog.filter { $0.recordType == RecordMapper.folderType }.isEmpty)
        // z's pin arrives later and lands in the folder.
        a.edit { $0.pins.append(makePin("z.com")) }
        clock.advance()
        try await a.sync(); try await b.sync()
        #expect(folderLayout(b).contains("z.com@Work"))
    }

    // MARK: Unknown fields, early folders, failed merges

    @Test func unrelatedExtraKeysAreLeftAloneAndCauseNoUploads() async throws {
        let f = PinFolder(name: "Work")
        let keeping = KeyKeepingTransport(base: server)
        let a = Mac("A", server: keeping, clock: clock, local: payload(pins(["a.com", "b.com"], folder: f, in: ["a.com"])))
        try await a.sync()
        for name in ["pin-a.com", "folder-" + f.id.uuidString] {
            var rec = try #require(await server.record(named: name))
            rec.fields["fromAFutureRelease"] = .string("x")
            _ = try await server.modify(saving: [rec], deleting: [])
        }
        await server.clearLogs()
        for _ in 0..<4 { try await a.sync() }
        let b = Mac("B", server: keeping, clock: clock)
        for _ in 0..<3 { try await b.sync() }
        #expect(await server.saveLog.filter { $0.recordType != RecordMapper.deviceType }.isEmpty)
        #expect(await server.record(named: "pin-a.com")?.fields["fromAFutureRelease"] != nil)
        #expect(await server.record(named: "folder-" + f.id.uuidString)?.fields["fromAFutureRelease"] != nil)
    }

    @Test func ordinarySavesNeverMentionLegacyKeys() {
        let plain = RecordMapper.pinRecords(pins(["a.com"]))[0]
        #expect(CloudKitTransport.ckRecord(from: plain, zoneID: .default).changedKeys().filter { $0 == "folderID" || $0 == "folderName" }.isEmpty)
        var cleaning = plain
        cleaning.clearKeys = ["folderID", "folderName"]
        #expect(CloudKitTransport.ckRecord(from: cleaning, zoneID: .default).changedKeys().filter { $0 == "folderID" || $0 == "folderName" }.count == 2)
    }

    @Test func folderArrivingBeforeAnyOfItsPinsIsNotDeleted() async throws {
        let f = PinFolder(name: "Work")
        let a = Mac("A", server: server, clock: clock, local: payload(pins(["a.com", "b.com"], folder: f, in: ["a.com", "b.com"])))
        try await a.sync()
        // Only the folder record reaches B first: take the pins away from what B can see.
        let blind = Mac("B", server: PinsHiddenTransport(base: server), clock: clock)
        await server.clearLogs()
        try await blind.sync(); try await blind.sync()
        #expect(await server.deleteLog.isEmpty)
        #expect(await server.saveLog.filter { $0.recordType == RecordMapper.folderType }.isEmpty)
        #expect(await !(server.record(named: "folder-" + f.id.uuidString)?.isTombstone ?? true))
        let b = Mac("B2", server: server, clock: clock)
        try await b.sync()
        #expect(folderLayout(b) == ["a.com@Work", "b.com@Work"])
    }

    @Test func aMergedStampThatFailedToSaveIsMergedAgainFromItsBase() async throws {
        let f = PinFolder(name: "Work")
        let flaky = FlakyTransport(base: server)
        let a = Mac("A", server: flaky, clock: clock, local: payload(pins(["a.com", "b.com", "c.com", "d.com"], folder: f, in: ["a.com", "b.com"])))
        let x = Mac("X", server: server, clock: clock)
        try await a.sync(); try await x.sync()
        x.edit { p in p.pins[2].folder = f }                      // X adds c
        clock.advance()
        try await x.sync()
        clock.advance()
        a.edit { p in p.pins[3].folder = f }                      // A adds d; its merged save fails
        flaky.failingType = RecordMapper.folderType
        try await a.sync()
        flaky.failingType = nil
        // Meanwhile another Mac takes c out again.
        var removed = try #require(await server.record(named: "folder-" + f.id.uuidString))
        removed.fields["members"] = .strings(["a.com", "b.com"])
        removed.modifiedAt = clock.t.addingTimeInterval(30); removed.modifiedBy = "Y"
        _ = try await server.modify(saving: [removed], deleting: [])
        clock.advance()
        try await a.sync(); try await x.sync(); try await a.sync()
        #expect(Set(a.local.pins.filter { $0.folder != nil }.map(\.key.host)) == ["a.com", "b.com", "d.com"])
        #expect(folderLayout(x) == folderLayout(a))
    }
}

/// B before the pin records reach it: it sees every record except the pins.
struct PinsHiddenTransport: SyncTransport {
    let base: any SyncTransport
    func fetchChanges(since token: Data?) async throws -> SyncChangeSet {
        var cs = try await base.fetchChanges(since: token)
        cs.changed.removeAll { $0.recordType == RecordMapper.pinType }
        return cs
    }
    func modify(saving: [SyncRecord], deleting: [SyncRecordID]) async throws -> SyncModifyResult {
        try await base.modify(saving: saving, deleting: deleting)
    }
}
