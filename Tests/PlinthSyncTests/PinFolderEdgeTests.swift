import Foundation
import Testing
import PlinthModel
@testable import PlinthSync

/// Saves of the named records fail the way CloudKit reports a per-record failure.
final class NameFailingTransport: SyncTransport, @unchecked Sendable {
    let base: any SyncTransport
    var failing: Set<String> = []
    init(base: any SyncTransport) { self.base = base }
    func fetchChanges(since token: Data?) async throws -> SyncChangeSet { try await base.fetchChanges(since: token) }
    func modify(saving: [SyncRecord], deleting: [SyncRecordID]) async throws -> SyncModifyResult {
        var result = try await base.modify(saving: saving.filter { !failing.contains($0.recordName) }, deleting: deleting)
        for r in saving where failing.contains(r.recordName) { result.failed[r.id] = "injected" }
        return result
    }
}

/// Rare folder sync sequences (PLI-41).
@MainActor @Suite struct PinFolderEdgeTests {
    let clock = Clock()
    let server = InMemoryTransport()

    func pins(_ hosts: [String], folder f: PinFolder? = nil, in members: Set<String> = []) -> [PinnedSite] {
        hosts.map { h in var p = makePin(h); if members.contains(h) { p.folder = f }; return p }
    }
    func payload(_ p: [PinnedSite]) -> SyncPayload { SyncPayload(pins: p, shelf: [], history: []) }
    func layout(_ m: Mac) -> [String] { m.local.pins.map { $0.key.host + ($0.folder.map { "@" + $0.name } ?? "") } }
    func liveFolders() async -> [SyncRecord] {
        await server.allRecords.filter { $0.recordType == RecordMapper.folderType && !$0.isTombstone }
    }

    @Test func aFolderKeepsAMemberWhosePinNeverReachedICloudWhenAnotherMacUnpinsTheOther() async throws {
        let flaky = NameFailingTransport(base: server)
        flaky.failing = ["pin-x.com"]
        let f = PinFolder(name: "Work")
        let a = Mac("A", server: flaky, clock: clock, local: payload(pins(["x.com", "y.com", "z.com"], folder: f, in: ["x.com", "y.com"])))
        try await a.sync()
        #expect(await server.record(named: "pin-x.com") == nil)
        #expect(await server.record(named: "pin-y.com") != nil)
        let b = Mac("B", server: server, clock: clock)
        try await b.sync()
        #expect(b.pinHosts.contains("x.com") == false)
        clock.advance()
        b.edit { $0.pins.removeAll { $0.key.host == "y.com" } }
        clock.advance()
        try await b.sync()
        // B did not delete the folder: x is still listed in it.
        #expect(await liveFolders().compactMap { $0.fields["members"]?.stringsValue } == [["x.com"]])
        flaky.failing = []
        clock.advance()
        try await a.sync(); try await b.sync(); try await a.sync()
        let c = Mac("C", server: server, clock: clock)
        try await c.sync()
        #expect(layout(a) == ["x.com@Work", "z.com"])
        #expect(layout(b) == layout(a))
        #expect(layout(c) == layout(a))
    }

    @Test func aFolderWhoseOnlyMemberWasUnpinnedBeforeItsPinWasSavedIsRemoved() async throws {
        let flaky = NameFailingTransport(base: server)
        flaky.failing = ["pin-x.com"]
        let f = PinFolder(name: "Solo")
        let a = Mac("A", server: flaky, clock: clock, local: payload(pins(["x.com", "y.com"], folder: f, in: ["x.com"])))
        try await a.sync()
        #expect(await liveFolders().count == 1)
        clock.advance()
        a.edit { $0.pins.removeAll { $0.key.host == "x.com" } }
        clock.advance()
        try await a.sync()
        #expect(await liveFolders().isEmpty)
        let b = Mac("B", server: server, clock: clock)
        try await b.sync()
        #expect(layout(b) == ["y.com"])
        // Quiet afterwards.
        await server.clearLogs()
        try await a.sync(); try await b.sync(); try await a.sync()
        #expect(await server.saveLog.filter { $0.recordType != RecordMapper.deviceType }.isEmpty)
    }

    @Test func aFolderStillWaitsForAPinThatWasNotDropped() async throws {
        let flaky = NameFailingTransport(base: server)
        flaky.failing = ["pin-x.com"]
        let f = PinFolder(name: "Solo")
        let a = Mac("A", server: flaky, clock: clock, local: payload(pins(["x.com", "y.com"], folder: f, in: ["x.com"])))
        try await a.sync()
        flaky.failing = []
        clock.advance()
        try await a.sync()
        #expect(await liveFolders().count == 1)
        #expect(await server.record(named: "pin-x.com") != nil)
    }

    @Test func leftoverFolderFieldsUnderADeletedPinAreCleaned() async throws {
        let keeping = KeyKeepingTransport(base: server)
        let a = Mac("A", server: keeping, clock: clock, local: payload(pins(["a.com", "b.com"])))
        try await a.sync()
        // b was pinned by a build that wrote folder fields, then unpinned by another Mac: a tombstone
        // that still carries the old fields.
        var rec = try #require(await server.record(named: "pin-b.com"))
        rec = rec.tombstone(at: clock.t, by: "Z")
        rec.fields = ["folderID": .string(UUID().uuidString), "folderName": .string("Old")]
        _ = try await server.modify(saving: [rec], deleting: [])
        await server.clearLogs()
        clock.advance()
        try await a.sync()
        let after = try #require(await server.record(named: "pin-b.com"))
        #expect(after.isTombstone && after.fields.isEmpty)
        #expect(a.pinHosts == ["a.com"])
        await server.clearLogs()
        for _ in 0..<3 { try await a.sync() }
        #expect(await server.saveLog.filter { $0.recordType != RecordMapper.deviceType }.isEmpty)
    }
}
