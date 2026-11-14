import Foundation

/// What a recorded event changed.
public struct LoyaltyUpdate: Equatable, Sendable {
    /// Points this event added (0 when it was a repeat, over a cap, or loyalty is off).
    public var pointsAdded: Int
    /// Set when the event moved the total into a higher level.
    public var leveledUpTo: LoyaltyLevel?
    public var totals: LoyaltyTotals
}

public enum LoyaltyEvent: Sendable, Equatable {
    /// The app was used today. Call it freely; only the first call of a day earns.
    case dayOfUse
    /// The user shared Plinth (completed a share). The first `maxSharesPerDay` of a day earn.
    case share
    case milestone(LoyaltyMilestone)
    /// Reserved for inviting friends, which needs a server to count invite opens. Awards nothing yet.
    case invite
}

/// The loyalty points for one device, plus what it knows of the others'.
///
/// No network, no account, no analytics: the ledger is a small JSON file next to the other stores.
/// When iCloud sync is on, `ownLedgerData` goes up as this device's own record, and the other
/// devices' ledgers come back through `ingest` (see `SyncEngine`); with sync off it still works,
/// it just counts this device alone.
@MainActor public final class LoyaltyEngine {
    public let deviceID: String
    public let platform: LoyaltyPlatform
    /// Called after the ledgers changed (own or remote).
    public var onChange: (() -> Void)?

    public private(set) var own: LoyaltyLedger { didSet { revision += 1 } }
    /// Other devices' ledgers as last received, by device ID.
    public private(set) var remote: [String: LoyaltyLedger] = [:] { didSet { revision += 1 } }
    private var revision = 0
    private var cache: (revision: Int, today: String, totals: LoyaltyTotals)?
    /// Points show and are earned only while this is true. Switching it off keeps the ledger.
    public var isEnabled: Bool { get { enabled } set { enabled = newValue; persist() } }

    private var enabled = true
    private var acknowledged = 1
    private let fileURL: URL?
    private let now: @Sendable () -> Date
    private let timeZone: @Sendable () -> TimeZone

    struct File: Codable { var own: LoyaltyLedger; var remote: [String: LoyaltyLedger]; var enabled: Bool?; var acknowledged: Int? }

    /// `timeZone` is read each time a day is needed, so travelling or changing the zone is followed.
    public init(deviceID: String, platform: LoyaltyPlatform, fileURL: URL?,
                timeZone: @escaping @Sendable () -> TimeZone = { .current }, now: @escaping @Sendable () -> Date = { Date() }) {
        self.deviceID = deviceID; self.platform = platform; self.fileURL = fileURL
        self.timeZone = timeZone; self.now = now
        own = LoyaltyLedger(deviceID: deviceID, platform: platform)
        if let fileURL, let data = try? Data(contentsOf: fileURL), let f = try? JSONDecoder().decode(File.self, from: data) {
            remote = f.remote.filter { $0.key != deviceID }
            if f.own.deviceID == deviceID {
                own = f.own
                own.platform = platform   // a damaged file must not make this device's ledger `other`
            } else if !f.own.awards.isEmpty {
                // This device got a new ID (a reinstall or restore): what the old ID earned still counts.
                remote[f.own.deviceID] = f.own
            }
            enabled = f.enabled ?? true
            acknowledged = f.acknowledged ?? 1
        }
    }

    // MARK: Reading

    public var today: String { LoyaltyDay.string(for: now(), in: timeZone()) }

    private var allLedgers: [LoyaltyLedger] { [own] + remote.values.sorted { $0.deviceID < $1.deviceID } }

    /// Cached until a ledger changes or the day does, so frequent reads are cheap.
    public var totals: LoyaltyTotals {
        let day = today
        if let c = cache, c.revision == revision, c.today == day { return c.totals }
        let t = LoyaltyTotals.compute(ledgers: allLedgers, today: day)
        cache = (revision, day, t)
        return t
    }

    /// The colourways this level has unlocked.
    public func unlockedColourways() -> [LoyaltyColourway] {
        let level = totals.level.number
        return LoyaltyColourway.all.filter { $0.unlockLevel <= level }
    }

    public func isUnlocked(_ colourway: LoyaltyColourway) -> Bool { colourway.unlockLevel <= totals.level.number }

    /// The level the user has reached but not yet been told about, once. Covers a level reached by
    /// points arriving from another device as well as by this device's own events.
    public func claimLevelUp() -> LoyaltyLevel? {
        let level = totals.level
        guard enabled, level.number > acknowledged else { return nil }
        acknowledged = level.number
        persist()
        return level
    }

    // MARK: Earning

    @discardableResult
    public func record(_ event: LoyaltyEvent) -> LoyaltyUpdate {
        let before = totals
        guard enabled else { return LoyaltyUpdate(pointsAdded: 0, leveledUpTo: nil, totals: before) }
        var changed = false
        let day = today
        switch event {
        case .dayOfUse:
            let key = LoyaltyLedger.dayKey(day)
            if !platformHas(key) {
                let streak = LoyaltyTotals.streak(days: knownDays(), today: day) // days up to yesterday
                let bonus = min(streak * LoyaltyRules.streakBonusPerDay, LoyaltyRules.streakBonusCap)
                own.awards[key] = LoyaltyRules.dailyPoints + bonus
                changed = true
            }
        case .share:
            do {
                for n in 1...LoyaltyRules.maxSharesPerDay where !platformHas(LoyaltyLedger.shareKey(day, n)) {
                    own.awards[LoyaltyLedger.shareKey(day, n)] = LoyaltyRules.sharePoints
                    changed = true
                    break
                }
            }
        case .milestone(let m):
            let key = LoyaltyLedger.onceKey(m)
            // Already earned on another device: nothing more to add here.
            if own.awards[key] == nil, !before.milestones.contains(m) {
                own.awards[key] = LoyaltyRules.milestonePoints
                changed = true
            }
        case .invite:
            break
        }
        guard changed else { return LoyaltyUpdate(pointsAdded: 0, leveledUpTo: nil, totals: before) }
        persist()
        let after = totals
        onChange?()
        return LoyaltyUpdate(pointsAdded: after.points - before.points,
                             leveledUpTo: after.level.number > before.level.number ? after.level : nil, totals: after)
    }

    /// Whether a day or share key is already paid on this platform, by this device or another of it.
    private func platformHas(_ key: String) -> Bool {
        allLedgers.contains { $0.platform == platform && ($0.awards[key] ?? 0) > 0 }
    }

    /// Days of use on any device (used for the streak bonus), not counting today.
    private func knownDays() -> Set<String> {
        var out = Set<String>()
        for l in allLedgers {
            for key in l.awards.keys { if case .day(let d)? = LoyaltyLedger.parse(key) { out.insert(d) } }
        }
        out.remove(today)
        return out
    }

    // MARK: Sync

    /// This device's ledger, ready to upload.
    public var ownLedgerData: Data { own.encoded() }

    /// Takes ledgers received from the account's other devices (and the server's copy of this
    /// device's own). Returns whether anything changed.
    @discardableResult
    public func ingest(_ blobs: [Data]) -> Bool {
        var changed = false
        for blob in blobs {
            guard let l = LoyaltyLedger.decode(blob) else { continue }
            if l.deviceID == deviceID {
                var merged = own
                merged.merge(l)
                if merged != own { own = merged; changed = true }
            } else {
                var merged = remote[l.deviceID] ?? LoyaltyLedger(deviceID: l.deviceID, platform: l.platform)
                let was = merged
                merged.merge(l)
                merged.platform = l.platform
                if merged != was { remote[l.deviceID] = merged; changed = true }
            }
        }
        if changed { persist(); onChange?() }
        return changed
    }

    private func persist() {
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys]
            try enc.encode(File(own: own, remote: remote, enabled: enabled, acknowledged: acknowledged)).write(to: fileURL, options: .atomic)
        } catch {
            // Points are not worth failing anything over; the next change writes again.
        }
    }
}
