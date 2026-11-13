import Foundation

/// What changed on the server since a change token.
public struct SyncChangeSet: Sendable {
    public var changed: [SyncRecord]
    public var deleted: [SyncRecordID]
    /// Pass this to the next fetch. Opaque.
    public var token: Data?
    /// More changes are waiting; fetch again with `token`.
    public var moreComing: Bool

    public init(changed: [SyncRecord], deleted: [SyncRecordID], token: Data?, moreComing: Bool = false) {
        self.changed = changed; self.deleted = deleted; self.token = token; self.moreComing = moreComing
    }
}

/// The outcome of one save/delete batch. Records are saved individually (not atomically).
public struct SyncModifyResult: Sendable {
    /// Saved records as the server now has them (with their new `serverTag`).
    public var saved: [SyncRecord]
    public var deleted: [SyncRecordID]
    /// The server's current version of each record whose save was refused because the server
    /// copy changed since the `serverTag` we sent. The engine re-merges and tries again.
    public var conflicts: [SyncRecord]
    /// Records that could not be saved or deleted for another reason. Retried on the next sync.
    public var failed: [SyncRecordID: String]

    public init(saved: [SyncRecord] = [], deleted: [SyncRecordID] = [], conflicts: [SyncRecord] = [],
                failed: [SyncRecordID: String] = [:]) {
        self.saved = saved; self.deleted = deleted; self.conflicts = conflicts; self.failed = failed
    }
}

public enum SyncError: Error, Equatable, Sendable {
    /// A sync is already running on this engine.
    case busy
    /// The change token is no longer valid; the engine refetches everything.
    case changeTokenExpired
    /// The server lost the zone (the user reset iCloud data, or it was never created). The engine
    /// forgets what it knew about the server and uploads everything again.
    case serverReset
    /// No iCloud account, or it is restricted.
    case notSignedIn
    /// The app has no iCloud container entitlement (unsigned / ad-hoc build).
    case notConfigured
    case transport(String)
}

/// A place records live. `InMemoryTransport` for tests and previews; `CloudKitTransport` for real.
public protocol SyncTransport: Sendable {
    /// Changes since `token` (nil = everything). Includes changes this device made itself.
    func fetchChanges(since token: Data?) async throws -> SyncChangeSet
    /// Saves records only if the server copy still has the `serverTag` sent (nil = must not exist
    /// yet); otherwise the record is reported in `conflicts`. Deletes are unconditional.
    func modify(saving: [SyncRecord], deleting: [SyncRecordID]) async throws -> SyncModifyResult
}

/// A server in memory. Share one instance between several engines to simulate several Macs.
public actor InMemoryTransport: SyncTransport {
    private struct Stored { var record: SyncRecord; var version: Int; var seq: Int }
    private var records: [String: Stored] = [:]
    private var deletions: [(seq: Int, id: SyncRecordID)] = []
    private var seq = 0
    private var failuresLeft = 0
    private var failureError: SyncError = .transport("injected failure")
    private var pendingInjections: [SyncRecord] = []
    private var tokenExpiresNext = false

    /// Fetches return at most this many changes per call (to exercise `moreComing`).
    public var pageSize: Int?

    /// Every record saved successfully, in order. For tests.
    public private(set) var saveLog: [SyncRecord] = []
    public private(set) var deleteLog: [SyncRecordID] = []
    public private(set) var modifyCalls = 0

    public init(pageSize: Int? = nil) { self.pageSize = pageSize }

    // MARK: Test controls

    /// The next `count` calls (fetch or modify) throw `error`.
    public func failNext(_ count: Int = 1, with error: SyncError = .transport("injected failure")) {
        failuresLeft = count; failureError = error
    }

    /// Writes `record` straight into the server just before the next modify runs, as if another
    /// Mac saved it between this engine's fetch and its save. Produces a conflict if the engine
    /// saves the same record.
    public func injectBeforeNextModify(_ record: SyncRecord) { pendingInjections.append(record) }

    /// The next fetch with a non-nil token throws `changeTokenExpired`.
    public func expireTokenOnNextFetch() { tokenExpiresNext = true }

    /// Wipes everything, as if the zone was deleted. The next fetch with a token throws `serverReset`.
    public func reset() {
        records = [:]; deletions = []; seq += 1; resetPending = true
    }
    private var resetPending = false

    public func setPageSize(_ n: Int?) { pageSize = n }
    public func clearLogs() { saveLog = []; deleteLog = []; modifyCalls = 0 }

    public func record(named name: String) -> SyncRecord? { records[name]?.record }
    public var allRecords: [SyncRecord] { records.values.map(\.record).sorted { $0.recordName < $1.recordName } }

    // MARK: SyncTransport

    public func fetchChanges(since token: Data?) async throws -> SyncChangeSet {
        try consumeFailure()
        let since = token.map(Self.decode) ?? 0
        if token != nil, resetPending { resetPending = false; throw SyncError.serverReset }
        if token != nil, tokenExpiresNext { tokenExpiresNext = false; throw SyncError.changeTokenExpired }
        if token == nil { resetPending = false }
        // Changes ordered by sequence: live records and deletions after `since`.
        var events: [(seq: Int, change: Either)] = []
        for s in records.values where s.seq > since { events.append((s.seq, .changed(s.record))) }
        for d in deletions where d.seq > since && (records[d.id.recordName]?.seq ?? 0) < d.seq {
            events.append((d.seq, .deleted(d.id)))
        }
        events.sort { $0.seq < $1.seq }
        var moreComing = false
        if let pageSize, events.count > pageSize { events = Array(events.prefix(pageSize)); moreComing = true }
        let upTo = moreComing ? (events.last?.seq ?? since) : seq
        var changed: [SyncRecord] = []
        var deleted: [SyncRecordID] = []
        for e in events {
            switch e.change {
            case .changed(let r): changed.append(r)
            case .deleted(let id): deleted.append(id)
            }
        }
        return SyncChangeSet(changed: changed, deleted: deleted, token: Self.encode(upTo), moreComing: moreComing)
    }

    public func modify(saving: [SyncRecord], deleting: [SyncRecordID]) async throws -> SyncModifyResult {
        try consumeFailure()
        modifyCalls += 1
        for r in pendingInjections { put(r) }
        pendingInjections = []
        var result = SyncModifyResult()
        for r in saving {
            let current = records[r.recordName]
            if let current, current.record.serverTag != r.serverTag {
                result.conflicts.append(current.record)
                continue
            }
            let saved = put(r)
            saveLog.append(saved)
            result.saved.append(saved)
        }
        for id in deleting {
            seq += 1
            records[id.recordName] = nil
            deletions.append((seq, id))
            deleteLog.append(id)
            result.deleted.append(id)
        }
        return result
    }

    // MARK: Internals

    private enum Either { case changed(SyncRecord), deleted(SyncRecordID) }

    @discardableResult
    private func put(_ r: SyncRecord) -> SyncRecord {
        seq += 1
        let version = (records[r.recordName]?.version ?? 0) + 1
        var stored = r
        stored.serverTag = Data("v\(version)".utf8)
        records[r.recordName] = Stored(record: stored, version: version, seq: seq)
        return stored
    }

    private func consumeFailure() throws {
        if failuresLeft > 0 { failuresLeft -= 1; throw failureError }
    }

    private static func encode(_ n: Int) -> Data { Data(String(n).utf8) }
    private static func decode(_ d: Data) -> Int { Int(String(decoding: d, as: UTF8.self)) ?? 0 }
}
