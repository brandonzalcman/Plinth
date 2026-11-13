import Foundation
import Testing
import PlinthModel
@testable import PlinthSync

@MainActor final class FakeStore {
    var payload = SyncPayload(pins: [], shelf: [], history: [])
    var applied = 0
}

/// Counts fetches and can run a hook during a fetch (to change the store mid-sync).
actor CountingTransport: SyncTransport {
    let inner: InMemoryTransport
    private(set) var fetches = 0
    private var hook: (@Sendable () async -> Void)?
    init(inner: InMemoryTransport) { self.inner = inner }
    func setHook(_ h: (@Sendable () async -> Void)?) { hook = h }
    func fetchChanges(since token: Data?) async throws -> SyncChangeSet {
        fetches += 1
        if let h = hook { hook = nil; await h() }
        return try await inner.fetchChanges(since: token)
    }
    func modify(saving: [SyncRecord], deleting: [SyncRecordID]) async throws -> SyncModifyResult {
        try await inner.modify(saving: saving, deleting: deleting)
    }
}

@MainActor @Suite struct CoordinatorTests {
    let clock = Clock()
    let server = InMemoryTransport()

    @Test func syncNowAppliesMergedState() async throws {
        let other = Mac("B", server: server, clock: clock, local: SyncPayload(pins: [makePin("b.com")], shelf: [], history: []))
        other.openPages = [OpenPageSummary(url: url("https://b.com/"), name: "B", title: "B", key: SiteKey("b.com"))]
        try await other.sync()
        let store = FakeStore()
        let c = SyncCoordinator(engine: SyncEngine(transport: server, deviceID: "A", deviceName: "A", stateURL: nil, now: { clock.t }))
        let r = await c.syncNow(local: { store.payload }, openPages: { [] }, apply: { store.payload = $0; store.applied += 1 })
        #expect(try r.get().map(\.deviceID) == ["B"])
        #expect(store.payload.pins.map(\.key.host) == ["b.com"])
        #expect(store.applied == 1)
        #expect(c.otherDevices.map(\.deviceID) == ["B"])
        await c.syncNow(local: { store.payload }, openPages: { [] }, apply: { store.payload = $0; store.applied += 1 })
        #expect(store.applied == 1)   // nothing changed: apply not called
    }

    @Test func editDuringSyncIsNotOverwritten() async throws {
        let other = Mac("B", server: server, clock: clock, local: SyncPayload(pins: [makePin("b.com")], shelf: [], history: []))
        try await other.sync()
        let store = FakeStore()
        store.payload.pins = [makePin("a.com")]
        let transport = CountingTransport(inner: server)
        await transport.setHook { @MainActor in store.payload.pins[0].name = "Typed during sync" }
        let c = SyncCoordinator(engine: SyncEngine(transport: transport, deviceID: "A", deviceName: "A", stateURL: nil, now: { clock.t }))
        await c.syncNow(local: { store.payload }, openPages: { [] }, apply: { store.payload = $0 })
        #expect(await transport.fetches == 2)
        #expect(store.payload.pins.map(\.name).sorted() == ["Typed during sync", "b.com"])
        try await other.sync()
        #expect(other.pinNames.sorted() == ["Typed during sync", "b.com"])
    }

    @Test func scheduledSyncsAreDebounced() async throws {
        let store = FakeStore()
        let transport = CountingTransport(inner: server)
        let c = SyncCoordinator(engine: SyncEngine(transport: transport, deviceID: "A", deviceName: "A", stateURL: nil, now: { clock.t }),
                                debounce: .milliseconds(30))
        var finished = 0
        c.onSyncFinished = { _ in finished += 1 }
        for i in 0..<5 {
            store.payload.pins.append(makePin("s\(i).com"))
            c.scheduleSync(local: { store.payload }, openPages: { [] }, apply: { store.payload = $0 })
        }
        for _ in 0..<100 where finished == 0 { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(60))
        #expect(finished == 1)
        #expect(await transport.fetches == 1)
        #expect(await server.allRecords.filter { $0.recordType == RecordMapper.pinType }.count == 5)
    }

    @Test func errorsAreReported() async throws {
        await server.failNext(1, with: .notSignedIn)
        let c = SyncCoordinator(engine: SyncEngine(transport: server, deviceID: "A", deviceName: "A", stateURL: nil, now: { clock.t }))
        let r = await c.syncNow(local: { SyncPayload(pins: [], shelf: [], history: []) }, openPages: { [] }, apply: { _ in })
        #expect(throws: SyncError.notSignedIn) { try r.get() }
        #expect((c.lastError as? SyncError) == .notSignedIn)
    }
}

@Suite struct SettingsTests {
    func defaults() -> UserDefaults {
        let name = "plinth-sync-tests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test func syncIsOffByDefault() {
        let s = SyncSettings(defaults: defaults())
        #expect(!s.isEnabled)
        #expect(s.availability == .off)
    }

    @Test func unsignedBuildNeedsADeveloperTeam() async {
        let s = SyncSettings(defaults: defaults())
        s.isEnabled = true
        // The test runner has no iCloud entitlement, like the ad-hoc signed app.
        #expect(!SyncSettings.isCloudKitConfigured)
        #expect(s.availability == .needsDeveloperTeam)
        #expect(await MainActor.run { s.makeCloudKitEngine(stateURL: nil) == nil })
    }

    @Test func deviceIDIsStable() {
        let d = defaults()
        let id = SyncSettings(defaults: d).deviceID
        #expect(!id.isEmpty)
        #expect(SyncSettings(defaults: d).deviceID == id)
        #expect(!SyncSettings.deviceName.isEmpty)
    }
}
