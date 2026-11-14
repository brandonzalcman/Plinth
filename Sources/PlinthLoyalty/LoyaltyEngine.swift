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

    public private(set) var own: LoyaltyLedger
    /// Other devices' ledgers as last received, by device ID.
    public private(set) var remote: [String: LoyaltyLedger] = [:]
    /// Points show and are earned only while this is true. Switching it off keeps the ledger.
    public var isEnabled: Bool { get { enabled } set { enabled = newValue; persist() } }

    private var enabled = true
    /// The newest day the clock has been trusted for, and a far-ahead day waiting to be confirmed.
    /// Local only; never synced. Not ledger keys, so one wrong clock reading cannot freeze earning.
    private var floorDay: String?
    private var pendingJump: String?
    private let fileURL: URL?
    private let now: @Sendable () -> Date
    private let timeZone: @Sendable () -> TimeZone

    struct File: Codable { var own: LoyaltyLedger; var remote: [String: LoyaltyLedger]; var enabled: Bool?; var floorDay: String?; var pendingJump: String? }

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
            } else if !f.own.awards.isEmpty {
                // This device got a new ID (a reinstall or restore): what the old ID earned still counts.
                remote[f.own.deviceID] = f.own
            }
            enabled = f.enabled ?? true
            floorDay = f.floorDay; pendingJump = f.pendingJump
        }
    }

    // MARK: Reading

    public var today: String { LoyaltyDay.string(for: now(), in: timeZone()) }

    private var allLedgers: [LoyaltyLedger] { [own] + remote.values.sorted { $0.deviceID < $1.deviceID } }

    public var totals: LoyaltyTotals { LoyaltyTotals.compute(ledgers: allLedgers, today: today) }

    /// The colourways this level has unlocked.
    public func unlockedColourways() -> [LoyaltyColourway] {
        let level = totals.level.number
        return LoyaltyColourway.all.filter { $0.unlockLevel <= level }
    }

    public func isUnlocked(_ colourway: LoyaltyColourway) -> Bool { colourway.unlockLevel <= totals.level.number }

    // MARK: Earning

    @discardableResult
    public func record(_ event: LoyaltyEvent) -> LoyaltyUpdate {
        let before = totals
        guard enabled else { return LoyaltyUpdate(pointsAdded: 0, leveledUpTo: nil, totals: before) }
        var changed = false
        let day = today
        // Days and shares earn only on a day the clock can be trusted for: not earlier than the newest
        // trusted day (winding the clock back mints nothing) and not far ahead of it (a clock set
        // forward writes nothing). See `trust(day:)`.
        let trusted = trust(day: day)
        switch event {
        case .dayOfUse:
            let key = LoyaltyLedger.dayKey(day)
            if trusted, !platformHas(key) {
                let streak = LoyaltyTotals.streak(days: knownDays(), today: day) // days up to yesterday
                let bonus = min(streak * LoyaltyRules.streakBonusPerDay, LoyaltyRules.streakBonusCap)
                own.awards[key] = LoyaltyRules.dailyPoints + bonus
                changed = true
            }
        case .share:
            if trusted {
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

    /// Decides whether `day` (today by the clock) can earn. The trusted floor moves forward day by day
    /// with use. A reading more than one day past it is not written anywhere: it is held as pending, and
    /// is trusted only when the next day's reading follows it (a real absence, then use on two days in a
    /// row). A reading earlier than the floor is the clock wound back and earns nothing. So one wrong
    /// clock costs nothing later, and stepping back never pays; stepping the clock forward one day at a
    /// time still can, which an offline app cannot prevent.
    private func trust(day: String) -> Bool {
        guard let floor = floorDay else { floorDay = day; persist(); return true }
        if day < floor { return false }
        if day == floor { return true }
        if day == LoyaltyDay.string(byAdding: 1, to: floor) {
            floorDay = day; pendingJump = nil; persist(); return true
        }
        // More than a day ahead of the floor.
        if let pending = pendingJump, day == LoyaltyDay.string(byAdding: 1, to: pending) {
            floorDay = day; pendingJump = nil; persist(); return true
        }
        if day != pendingJump && (pendingJump == nil || day > pendingJump!) { pendingJump = day; persist() }
        return false
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
            try enc.encode(File(own: own, remote: remote, enabled: enabled, floorDay: floorDay, pendingJump: pendingJump)).write(to: fileURL, options: .atomic)
        } catch {
            // Points are not worth failing anything over; the next change writes again.
        }
    }
}
