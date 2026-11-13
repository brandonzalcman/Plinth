import Foundation
import PlinthModel

public struct SyncOutcome: Sendable, Equatable {
    /// The new local state to apply. nil = nothing to change locally.
    public var merged: SyncPayload?
    /// The open pages of the other Macs on this account (read-only), newest first.
    public var otherDevices: [DeviceOpenPages]

    public init(merged: SyncPayload?, otherDevices: [DeviceOpenPages]) {
        self.merged = merged; self.otherDevices = otherDevices
    }
}

/// Merges this Mac's synced state with the server's.
///
/// The engine keeps a persisted base: the server records it last saw (with their server tags),
/// the records the local store was last known to reflect, and the server change token. Comparing
/// the local payload with that base tells a local edit or deletion apart from a remote one.
///
/// Merge rules:
/// - **Pins** (one record per site key): last writer wins per key, by the time the edit was first
///   seen on its Mac (`modifiedAt`); a deletion is a tombstone with its own time, so it beats older
///   edits and loses to newer ones. Pins are ordered by the winning `order` field (ties by host),
///   then renumbered. A pin page's live state never syncs.
/// - **Shelf** (one record per shelved page id): last writer wins per page id. A page that leaves
///   the shelf locally (restored or removed) becomes a tombstone. Pages are regrouped into one
///   entry per site key, so the same site shelved on two Macs is one entry; two pages of one entry
///   with the same URL keep only the most recently used.
/// - **History** (one record per entry id): union by id, never deleted by sync. The only removal is
///   the "clear history" marker: every entry visited at or before it is dropped on every Mac.
///   Capped at the newest `historyCap` (20,000). An entry's own Mac may update its title/dwell.
/// - **Open pages** (one record per device): each Mac writes only its own record; others are
///   read-only and ignored once older than 30 days.
/// - **Ties**: equal times go to the tombstone, then to the larger device ID. Every Mac computes the
///   same winner.
/// - Syncing again with no changes uploads nothing.
@MainActor public final class SyncEngine {
    public let deviceID: String
    public let deviceName: String
    /// History entries kept after a merge (newest first).
    public var historyCap = 20_000
    /// Other Macs' open-pages records older than this are ignored.
    public static let deviceRecordMaxAge: TimeInterval = 30 * 86_400
    /// This Mac's open-pages record is re-saved at least this often so it never goes stale.
    public static let deviceRefreshInterval: TimeInterval = 86_400
    /// Conflict re-merge rounds per sync before leaving the rest for next time.
    static let maxPushRounds = 4

    public private(set) var isSyncing = false
    /// When the last sync finished successfully.
    public var lastSyncedAt: Date? { state.lastSyncedAt }

    private let transport: any SyncTransport
    private let stateURL: URL?
    private let now: @Sendable () -> Date
    private var state: State
    private var lastInput: LastInput?

    struct State: Codable, Equatable {
        var version = 1
        var token: Data?
        /// Last known server copy of Pin, ShelfPage, Device and HistoryClear records.
        var server: [String: SyncRecord] = [:]
        /// Live Pin/ShelfPage records the local store was last known to reflect.
        var localRef: [String: SyncRecord] = [:]
        /// Local edits and deletions not yet settled, stamped with when they were first seen.
        var stamps: [String: SyncRecord] = [:]
        /// History entry id -> fingerprint of the version the server has.
        var historySynced: [UUID: UInt64] = [:]
        /// Remote history fetched by a sync whose result the shell did not apply.
        var pendingRemoteHistory: [HistoryEntry] = []
        /// "Clear history" requested locally, not yet on the server.
        var pendingClear: Date?
        var lastSyncedAt: Date?
    }

    private struct LastInput {
        var localRecords: [String: SyncRecord]
        var adoptedHistory: [HistoryEntry]
    }

    public init(transport: any SyncTransport, deviceID: String, deviceName: String, stateURL: URL?,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.transport = transport
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.stateURL = stateURL
        self.now = now
        if let stateURL, let data = try? Data(contentsOf: stateURL),
           let s = try? JSONDecoder().decode(State.self, from: data), s.version == 1 {
            state = s
        } else {
            state = State()
        }
    }

    // MARK: Public API

    /// Notes local edits as they happen, so last-writer-wins uses the time of the edit rather than
    /// the time of the next sync. Cheap; no network. Ignored while a sync is running.
    public func recordLocalChanges(_ local: SyncPayload) {
        guard !isSyncing else { return }
        var s = state
        stamp(&s, RecordMapper.records(for: local, previous: previousRecords(s)), at: now())
        if s != state { state = s; persist() }
    }

    /// Clears history on every Mac: entries visited up to now are dropped everywhere at the next
    /// sync. The caller clears its own store's history as usual.
    public func clearHistory() {
        state.pendingClear = now()
        persist()
    }

    /// Call when the shell could not apply the last `merged` payload (the user changed something
    /// while the sync was running). The next sync then merges again from what the shell really has.
    public func mergeNotApplied() {
        guard let li = lastInput else { return }
        state.localRef = li.localRecords.filter { !$0.value.isTombstone }
        state.pendingRemoteHistory = li.adoptedHistory
        // Not applied, so not yet "known" here: let the next merge add them again.
        for e in li.adoptedHistory { state.historySynced[e.id] = nil }
        lastInput = nil
        persist()
    }

    /// Forgets everything known about the server (for example when sync is turned off). Local data
    /// is untouched; the next sync merges it with the server from scratch.
    public func forgetServerState() {
        state = State()
        lastInput = nil
        persist()
    }

    /// Other Macs' open pages as of the last sync, without touching the network.
    public func otherDevices() -> [DeviceOpenPages] { otherDevices(state, at: now()) }

    public func sync(local: SyncPayload, openPages: [OpenPageSummary]) async throws -> SyncOutcome {
        guard !isSyncing else { throw SyncError.busy }
        isSyncing = true
        defer { isSyncing = false }
        let t = now()
        var s = state

        // 1. Local edits since the base.
        let localRecords = RecordMapper.records(for: local, previous: previousRecords(s))
        stamp(&s, localRecords, at: t)

        // 2. Remote changes.
        var fetched = try await fetch(&s, localRecords: localRecords, at: t)
        for e in s.pendingRemoteHistory where fetched[e.id] == nil { fetched[e.id] = e }

        // 3. History, open pages, clear marker.
        let hist = mergeHistory(local: local.history, fetched: fetched, state: &s)
        var extra: [String: SyncRecord] = [:]
        for r in hist.uploads { extra[r.recordName] = r }
        if let r = ownDeviceRecord(s, openPages: openPages, at: t) { extra[r.recordName] = r }
        if let p = s.pendingClear {
            let current = s.server[RecordMapper.clearName]
            if let d = current?["clearedAt"]?.dateValue, d >= p {
                s.pendingClear = nil
            } else {
                var r = RecordMapper.clearRecord(clearedAt: p)
                r.modifiedAt = t; r.modifiedBy = deviceID; r.serverTag = current?.serverTag
                extra[r.recordName] = r
            }
        }

        // 4. Resolve and upload; re-merge on conflicts.
        try await push(&s, names: Set(s.stamps.keys), extra: extra, deletes: hist.deletes)
        settle(&s)
        var built = build(s, local: local, history: hist.merged)

        // 5. Renumbered pin order, regrouped shelf times and hidden duplicates are written back
        //    now, so the next sync with no changes uploads nothing.
        let before = s.stamps
        stamp(&s, RecordMapper.records(for: built, previous: previousRecords(s)), at: t)
        let changed = Set(s.stamps.keys).union(before.keys).filter { s.stamps[$0] != before[$0] && s.stamps[$0] != nil }
        if !changed.isEmpty {
            try await push(&s, names: changed, extra: [:], deletes: [])
            settle(&s)
            built = build(s, local: local, history: hist.merged)
        }

        s.pendingRemoteHistory = []
        s.lastSyncedAt = t
        state = s
        persist()
        lastInput = LastInput(localRecords: localRecords, adoptedHistory: hist.adopted)
        return SyncOutcome(merged: built == local ? nil : built, otherDevices: otherDevices(s, at: t))
    }

    // MARK: Local changes

    /// Records that already exist for a name (so shelved pages keep their first `shelvedAt`).
    private func previousRecords(_ s: State) -> [String: SyncRecord] {
        var out = s.server.filter { !$0.value.isTombstone }
        for (k, v) in s.localRef { out[k] = v }
        for (k, v) in s.stamps where !v.isTombstone { out[k] = v }
        return out
    }

    /// Compares local records with the base and keeps one stamped record per changed name.
    /// A stamp keeps its time while its content stays the same.
    private func stamp(_ s: inout State, _ local: [String: SyncRecord], at t: Date) {
        for name in Set(local.keys).union(s.localRef.keys).union(s.stamps.keys) {
            let l = local[name], ref = s.localRef[name]
            if Self.sameState(l, ref) { s.stamps[name] = nil; continue }
            let candidate: SyncRecord
            if let l { candidate = l } else if let ref { candidate = ref.tombstone(at: t, by: deviceID) } else {
                s.stamps[name] = nil; continue
            }
            if let existing = s.stamps[name], existing.sameContent(as: candidate) { continue }
            var c = candidate
            c.modifiedAt = t; c.modifiedBy = deviceID; c.serverTag = nil
            s.stamps[name] = c
        }
    }

    // MARK: Fetch

    /// Pulls every change since the token into `s.server`; returns fetched history entries.
    private func fetch(_ s: inout State, localRecords: [String: SyncRecord], at t: Date) async throws -> [UUID: HistoryEntry] {
        var token = s.token
        var server = s.server
        var history: [UUID: HistoryEntry] = [:]
        var restarts = 0
        while true {
            let cs: SyncChangeSet
            do {
                cs = try await transport.fetchChanges(since: token)
            } catch SyncError.changeTokenExpired where restarts < 2 {
                restarts += 1
                token = nil; server = [:]; history = [:]
                continue
            } catch SyncError.serverReset where restarts < 2 {
                // The server forgot everything: forget what we knew, so all local data is new again.
                restarts += 1
                let clear = s.pendingClear
                s = State()
                s.pendingClear = clear
                stamp(&s, localRecords, at: t)
                token = nil; server = [:]; history = [:]
                continue
            }
            for r in cs.changed {
                if r.recordType == RecordMapper.historyType {
                    if let e = RecordMapper.historyEntry(from: r) { history[e.id] = e }
                } else {
                    server[r.recordName] = r
                }
            }
            for id in cs.deleted {
                if id.recordType == RecordMapper.historyType {
                    if let u = UUID(uuidString: String(id.recordName.dropFirst("history-".count))) {
                        history[u] = nil
                        s.historySynced[u] = nil
                    }
                } else {
                    server[id.recordName] = nil
                }
            }
            token = cs.token
            if !cs.moreComing { break }
        }
        s.server = server
        s.token = token
        return history
    }

    // MARK: History

    private struct HistoryMerge {
        var merged: [HistoryEntry]
        var uploads: [SyncRecord]
        var deletes: [SyncRecordID]
        var adopted: [HistoryEntry]
    }

    private func mergeHistory(local: [HistoryEntry], fetched: [UUID: HistoryEntry], state s: inout State) -> HistoryMerge {
        let clearedAt = [s.server[RecordMapper.clearName]?["clearedAt"]?.dateValue, s.pendingClear].compactMap { $0 }.max()
        var merged: [HistoryEntry] = []
        var fromRemote = Set<UUID>()
        var localIDs = Set<UUID>()
        var reordered = false
        for e in local where localIDs.insert(e.id).inserted {
            // Take the server's version of an entry only if ours is unchanged since we last synced it.
            if let r = fetched[e.id], let synced = s.historySynced[e.id],
               RecordMapper.fingerprint(e) == synced, RecordMapper.fingerprint(r) != synced {
                merged.append(r); fromRemote.insert(r.id)
                reordered = reordered || r.visitedAt != e.visitedAt
            } else {
                merged.append(e)
            }
        }
        // A fetched version we already know (our own upload coming back, or one applied before)
        // adds nothing; this is what keeps an entry removed locally from coming back.
        let extras = fetched.values.filter {
            !localIDs.contains($0.id) && s.historySynced[$0.id] != RecordMapper.fingerprint($0)
        }
        if !extras.isEmpty {
            merged += extras
            fromRemote.formUnion(extras.map(\.id))
            reordered = true
        }
        var deletes: [SyncRecordID] = []
        if let clearedAt {
            merged.removeAll { $0.visitedAt <= clearedAt }
            // Anyone who sees a cleared entry on the server removes it.
            for e in fetched.values where e.visitedAt <= clearedAt {
                deletes.append(SyncRecordID(recordType: RecordMapper.historyType, recordName: RecordMapper.historyName(e.id)))
            }
        }
        if reordered {
            merged = merged.enumerated().sorted {
                $0.element.visitedAt != $1.element.visitedAt ? $0.element.visitedAt > $1.element.visitedAt : $0.offset < $1.offset
            }.map(\.element)
        }
        if merged.count > historyCap { merged.removeLast(merged.count - historyCap) }
        let kept = Set(merged.map(\.id))

        if s.pendingClear != nil {
            for id in s.historySynced.keys where !kept.contains(id) {
                deletes.append(SyncRecordID(recordType: RecordMapper.historyType, recordName: RecordMapper.historyName(id)))
            }
        }
        // Fetched versions we already match count as synced.
        for (id, r) in fetched where kept.contains(id) {
            if fromRemote.contains(id) { s.historySynced[id] = RecordMapper.fingerprint(r) }
            else if let l = merged.first(where: { $0.id == id }), RecordMapper.fingerprint(l) == RecordMapper.fingerprint(r) {
                s.historySynced[id] = RecordMapper.fingerprint(r)
            }
        }
        s.historySynced = s.historySynced.filter { kept.contains($0.key) }
        var uploads: [SyncRecord] = []
        for e in merged where !fromRemote.contains(e.id) && s.historySynced[e.id] != RecordMapper.fingerprint(e) {
            var r = RecordMapper.historyRecord(e)
            r.modifiedAt = now(); r.modifiedBy = deviceID
            uploads.append(r)
        }
        var uniqueDeletes: [SyncRecordID] = []
        var seen = Set<String>()
        for d in deletes where seen.insert(d.recordName).inserted { uniqueDeletes.append(d) }
        return HistoryMerge(merged: merged, uploads: uploads, deletes: uniqueDeletes,
                            adopted: merged.filter { fromRemote.contains($0.id) })
    }

    // MARK: Open pages

    private func ownDeviceRecord(_ s: State, openPages: [OpenPageSummary], at t: Date) -> SyncRecord? {
        var r = RecordMapper.deviceRecord(deviceID: deviceID, deviceName: deviceName, pages: openPages)
        let existing = s.server[r.recordName]
        if let existing, existing.sameContent(as: r), t.timeIntervalSince(existing.modifiedAt) < Self.deviceRefreshInterval {
            return nil
        }
        r.modifiedAt = t; r.modifiedBy = deviceID; r.serverTag = existing?.serverTag
        return r
    }

    private func otherDevices(_ s: State, at t: Date) -> [DeviceOpenPages] {
        let own = RecordMapper.deviceName(deviceID)
        return s.server.values
            .filter { $0.recordType == RecordMapper.deviceType && $0.recordName != own }
            .filter { t.timeIntervalSince($0.modifiedAt) <= Self.deviceRecordMaxAge }
            .compactMap(RecordMapper.devicePages(from:))
            .filter { $0.deviceID != deviceID }
            .sorted { $0.updatedAt != $1.updatedAt ? $0.updatedAt > $1.updatedAt : $0.deviceID < $1.deviceID }
    }

    // MARK: Resolve and push

    /// Decides each stamped name (local wins if the server is unchanged since the base, otherwise
    /// last writer wins), uploads the winners, and re-merges anything the server reports as a conflict.
    private func push(_ s: inout State, names: Set<String>, extra: [String: SyncRecord], deletes: [SyncRecordID]) async throws {
        var names = names, extra = extra, deletes = deletes
        let ownDevice = RecordMapper.deviceName(deviceID)
        for _ in 0..<Self.maxPushRounds {
            var saves: [SyncRecord] = []
            for name in names.sorted() {
                guard let st = s.stamps[name] else { continue }
                let srv = s.server[name]
                if Self.sameState(st, srv) {
                    // The server already says what we say.
                    s.stamps[name] = nil
                    continue
                }
                let localWins: Bool
                if Self.sameState(srv, s.localRef[name]) { localWins = true }
                else if let srv { localWins = Self.wins(st, over: srv) }
                else { localWins = true }
                if localWins {
                    var up = st
                    up.serverTag = srv?.serverTag
                    saves.append(up)
                } else {
                    s.stamps[name] = nil
                }
            }
            // Never write another Mac's open-pages record.
            saves += extra.values
                .filter { $0.recordType != RecordMapper.deviceType || $0.recordName == ownDevice }
                .sorted { $0.recordName < $1.recordName }
            if saves.isEmpty && deletes.isEmpty { return }

            let result = try await transport.modify(saving: saves, deleting: deletes)
            let sent = Dictionary(saves.map { ($0.recordName, $0) }, uniquingKeysWith: { a, _ in a })
            names = []; extra = [:]; deletes = []

            for r in result.saved { applySaved(&s, r) }
            for id in result.deleted where id.recordType == RecordMapper.historyType {
                if let u = UUID(uuidString: String(id.recordName.dropFirst("history-".count))) { s.historySynced[u] = nil }
            }
            for c in result.conflicts {
                guard let mine = sent[c.recordName] else { continue }
                switch c.recordType {
                case RecordMapper.pinType, RecordMapper.shelfType:
                    s.server[c.recordName] = c
                    names.insert(c.recordName)
                case RecordMapper.historyType:
                    if c.sameContent(as: mine) {
                        if let e = RecordMapper.historyEntry(from: c) { s.historySynced[e.id] = RecordMapper.fingerprint(e) }
                    } else {
                        var m = mine; m.serverTag = c.serverTag; extra[m.recordName] = m
                    }
                case RecordMapper.clearType:
                    s.server[c.recordName] = c
                    let theirs = c["clearedAt"]?.dateValue ?? .distantPast
                    let ours = mine["clearedAt"]?.dateValue ?? .distantPast
                    if theirs >= ours {
                        if let p = s.pendingClear, p <= theirs { s.pendingClear = nil }
                    } else {
                        var m = mine; m.serverTag = c.serverTag; extra[m.recordName] = m
                    }
                case RecordMapper.deviceType where c.recordName == ownDevice:
                    var m = mine; m.serverTag = c.serverTag; extra[m.recordName] = m
                default:
                    break
                }
            }
            if names.isEmpty && extra.isEmpty { return }
        }
    }

    private func applySaved(_ s: inout State, _ r: SyncRecord) {
        switch r.recordType {
        case RecordMapper.historyType:
            if let e = RecordMapper.historyEntry(from: r) { s.historySynced[e.id] = RecordMapper.fingerprint(e) }
        case RecordMapper.pinType, RecordMapper.shelfType:
            s.server[r.recordName] = r
            if let st = s.stamps[r.recordName], st.sameContent(as: r) { s.stamps[r.recordName] = nil }
        case RecordMapper.clearType:
            s.server[r.recordName] = r
            if let p = s.pendingClear, let d = r["clearedAt"]?.dateValue, p <= d { s.pendingClear = nil }
        default:
            s.server[r.recordName] = r
        }
    }

    /// After a merge the local store will reflect the server for every settled name.
    private func settle(_ s: inout State) {
        let names = Set(s.server.keys).union(s.localRef.keys)
        for name in names where s.stamps[name] == nil {
            let type = s.server[name]?.recordType ?? s.localRef[name]?.recordType
            guard type == RecordMapper.pinType || type == RecordMapper.shelfType else { continue }
            if let r = s.server[name], !r.isTombstone { s.localRef[name] = r } else { s.localRef[name] = nil }
        }
    }

    /// The merged payload: server records overlaid with unsettled local ones.
    private func build(_ s: State, local: SyncPayload, history: [HistoryEntry]) -> SyncPayload {
        var effective = s.server.filter {
            $0.value.recordType == RecordMapper.pinType || $0.value.recordType == RecordMapper.shelfType
        }
        for (k, v) in s.stamps { effective[k] = v }
        let live = effective.values.filter { !$0.isTombstone }.sorted { $0.recordName < $1.recordName }
        let pins = RecordMapper.pins(from: live, local: local.pins, now: now())
        let shelf = RecordMapper.shelf(from: live, local: local.shelf).shelf
        return SyncPayload(pins: pins, shelf: shelf, history: history)
    }

    // MARK: Rules

    /// Both absent (or tombstones), or both live with the same content.
    static func sameState(_ a: SyncRecord?, _ b: SyncRecord?) -> Bool {
        let la = a.flatMap { $0.isTombstone ? nil : $0 }
        let lb = b.flatMap { $0.isTombstone ? nil : $0 }
        switch (la, lb) {
        case (nil, nil): return true
        case (let x?, let y?): return x.sameContent(as: y)
        default: return false
        }
    }

    /// Last writer wins; equal times go to the tombstone, then to the larger device ID.
    static func wins(_ a: SyncRecord, over b: SyncRecord) -> Bool {
        if abs(a.modifiedAt.timeIntervalSince(b.modifiedAt)) >= 0.001 { return a.modifiedAt > b.modifiedAt }
        if a.isTombstone != b.isTombstone { return a.isTombstone }
        return a.modifiedBy >= b.modifiedBy
    }

    // MARK: Persistence

    private func persist() {
        guard let stateURL else { return }
        do {
            try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
        } catch {
            // Losing the base only costs a fuller merge next time; never fail a sync over it.
        }
    }
}
