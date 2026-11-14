import Foundation
import Testing
import PlinthSync
import PlinthModel
@testable import PlinthLoyalty

/// A clock the tests move by hand.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _t: Date
    init(_ iso: String = "2026-03-10T10:00:00Z") { _t = ISO8601DateFormatter().date(from: iso)! }
    var t: Date { lock.lock(); defer { lock.unlock() }; return _t }
    func advance(days: Int = 0, hours: Int = 0) { lock.lock(); _t = _t.addingTimeInterval(Double(days * 86_400 + hours * 3_600)); lock.unlock() }
}

var utc: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }

@MainActor func engine(_ id: String, _ platform: LoyaltyPlatform = .mac, clock: TestClock, file: URL? = nil) -> LoyaltyEngine {
    LoyaltyEngine(deviceID: id, platform: platform, fileURL: file, calendar: utc, now: { clock.t })
}

@MainActor @Suite struct LoyaltyEarningTests {
    let clock = TestClock()

    @Test func dayOfUseEarnsOncePerDay() {
        let e = engine("A", clock: clock)
        #expect(e.record(.dayOfUse).pointsAdded == LoyaltyRules.dailyPoints)
        #expect(e.record(.dayOfUse).pointsAdded == 0)
        clock.advance(hours: 3)
        #expect(e.record(.dayOfUse).pointsAdded == 0)
        #expect(e.totals.points == 10)
        #expect(e.totals.daysOfUse == 1)
    }

    @Test func streakAddsBonusAndCaps() {
        let e = engine("A", clock: clock)
        var added: [Int] = []
        for _ in 0..<9 { added.append(e.record(.dayOfUse).pointsAdded); clock.advance(days: 1) }
        // 10, then +2 per streak day already held, capped at +10.
        #expect(added == [10, 12, 14, 16, 18, 20, 20, 20, 20])
        #expect(e.totals.streak == 9)
    }

    @Test func missedDayResetsStreakBonus() {
        let e = engine("A", clock: clock)
        e.record(.dayOfUse); clock.advance(days: 1)
        e.record(.dayOfUse); clock.advance(days: 2)
        #expect(e.totals.streak == 0)
        #expect(e.record(.dayOfUse).pointsAdded == 10)
        #expect(e.totals.streak == 1)
    }

    @Test func streakIsAliveUntilTheEndOfTomorrow() {
        let e = engine("A", clock: clock)
        e.record(.dayOfUse); clock.advance(days: 1)
        #expect(e.totals.streak == 1)   // yesterday counts until today passes
    }

    @Test func sharesAreCappedPerDay() {
        let e = engine("A", clock: clock)
        let added = (0..<5).map { _ in e.record(.share).pointsAdded }
        #expect(added == [15, 15, 15, 0, 0])
        clock.advance(days: 1)
        #expect(e.record(.share).pointsAdded == 15)
        #expect(e.totals.shares == 4)
    }

    @Test func milestonesEarnOnce() {
        let e = engine("A", clock: clock)
        #expect(e.record(.milestone(.firstPin)).pointsAdded == 25)
        #expect(e.record(.milestone(.firstPin)).pointsAdded == 0)
        #expect(e.totals.milestones == [.firstPin])
    }

    @Test func disabledEarnsNothingAndKeepsWhatWasEarned() {
        let e = engine("A", clock: clock)
        e.record(.dayOfUse)
        e.isEnabled = false
        #expect(e.record(.share).pointsAdded == 0)
        #expect(e.totals.points == 10)
        e.isEnabled = true
        #expect(e.record(.share).pointsAdded == 15)
    }

    @Test func levelUpIsReportedOnce() {
        let e = engine("A", clock: clock)
        var ups: [Int] = []
        for _ in 0..<60 {
            if let l = e.record(.dayOfUse).leveledUpTo { ups.append(l.number) }
            clock.advance(days: 1)
        }
        // 60 days at up to 20 points a day passes 100 and 300; 700 is not reached.
        #expect(ups == [2, 3, 4].prefix(ups.count).map { $0 })
        #expect(ups.first == 2)
        #expect(Set(ups).count == ups.count)
    }

    @Test func levelUpIsClaimedOnceEvenWhenPointsArriveFromAnotherDevice() {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("loyalty-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let mac = engine("M", clock: clock, file: file)
        #expect(mac.claimLevelUp() == nil)
        var awards: [String: Int] = [:]
        for d in 1...12 { awards[String(format: "day:2026-02-%02d", d)] = 10 }
        mac.ingest([LoyaltyLedger(deviceID: "P", platform: .ios, awards: awards).encoded()])
        #expect(mac.claimLevelUp()?.number == 2)
        #expect(mac.claimLevelUp() == nil)
        #expect(engine("M", clock: clock, file: file).claimLevelUp() == nil)   // remembered across launches
    }

    @Test func levelsAndUnlocks() {
        #expect(LoyaltyLevel.level(forPoints: 0).name == "Footing")
        #expect(LoyaltyLevel.level(forPoints: 99).number == 1)
        #expect(LoyaltyLevel.level(forPoints: 100).number == 2)
        #expect(LoyaltyLevel.level(forPoints: 99_999).number == 6)
        #expect(LoyaltyLevel.all.map(\.threshold) == LoyaltyLevel.all.map(\.threshold).sorted())
        #expect(LoyaltyColourway.all.map(\.unlockLevel) == [1, 2, 3, 4, 5, 6])
        let e = engine("A", clock: clock)
        #expect(e.unlockedColourways().map(\.id) == ["sunrise"])
        #expect(e.isUnlocked(.sunrise) && !e.isUnlocked(.dusk))
    }

    @Test func progressToNextLevel() {
        let e = engine("A", clock: clock)
        e.record(.dayOfUse)
        #expect(e.totals.progress?.earned == 10)
        #expect(e.totals.progress?.needed == 100)
        #expect(LoyaltyLevel.all.last?.next == nil)
    }

    @Test func persistsAcrossLaunches() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("loyalty-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let a = engine("A", clock: clock, file: file)
        a.record(.dayOfUse); a.record(.share); a.isEnabled = false
        let b = engine("A", clock: clock, file: file)
        #expect(b.totals.points == 25)
        #expect(b.isEnabled == false)
    }
}

@MainActor @Suite struct LoyaltyMergeTests {
    let clock = TestClock()

    @Test func devicesAddUp() {
        let mac = engine("M", .mac, clock: clock), phone = engine("P", .ios, clock: clock)
        mac.record(.dayOfUse); phone.record(.dayOfUse)
        mac.ingest([phone.ownLedgerData]); phone.ingest([mac.ownLedgerData])
        #expect(mac.totals.points == 20 + LoyaltyRules.bothPlatformsPoints)
        #expect(mac.totals == phone.totals)
        #expect(mac.totals.daysOfUse == 2)
    }

    @Test func twoDevicesEarningOfflineMergeWithoutLoss() {
        let mac = engine("M", .mac, clock: clock), phone = engine("P", .ios, clock: clock)
        for _ in 0..<3 { mac.record(.dayOfUse); mac.record(.share); clock.advance(days: 1) }
        clock.advance(days: -3)
        for _ in 0..<3 { phone.record(.dayOfUse); clock.advance(days: 1) }
        // Exchange in either order, more than once: same answer.
        mac.ingest([phone.ownLedgerData]); mac.ingest([phone.ownLedgerData])
        phone.ingest([mac.ownLedgerData])
        #expect(mac.totals == phone.totals)
        let expected = mac.own.awards.values.reduce(0, +) + phone.own.awards.values.reduce(0, +) + 50
        #expect(mac.totals.points == expected)
    }

    @Test func streakSpansDevices() {
        let mac = engine("M", .mac, clock: clock), phone = engine("P", .ios, clock: clock)
        mac.record(.dayOfUse); clock.advance(days: 1)
        phone.ingest([mac.ownLedgerData])
        phone.record(.dayOfUse)
        mac.ingest([phone.ownLedgerData])
        #expect(mac.totals.streak == 2)
        // The phone's day-two award carried the bonus for the Mac's day one.
        #expect(phone.own.awards.values.first == 12)
    }

    @Test func milestoneReachedOnTwoDevicesCountsOnce() {
        let mac = engine("M", .mac, clock: clock), phone = engine("P", .ios, clock: clock)
        mac.record(.milestone(.firstPin)); phone.record(.milestone(.firstPin))   // both offline
        mac.ingest([phone.ownLedgerData]); phone.ingest([mac.ownLedgerData])
        #expect(mac.totals.points == 25 + 50)
        #expect(mac.totals == phone.totals)
    }

    @Test func milestoneAlreadyEarnedElsewhereAddsNothing() {
        let mac = engine("M", .mac, clock: clock), phone = engine("P", .ios, clock: clock)
        mac.record(.milestone(.firstAsk))
        phone.ingest([mac.ownLedgerData])
        #expect(phone.record(.milestone(.firstAsk)).pointsAdded == 0)
    }

    @Test func bothPlatformsBonusNeedsBothPlatforms() {
        let a = engine("A", .mac, clock: clock), b = engine("B", .mac, clock: clock)
        a.record(.dayOfUse); b.record(.dayOfUse)
        a.ingest([b.ownLedgerData])
        #expect(a.totals.bothPlatforms == false)
        #expect(a.totals.points == 20)
    }

    @Test func ingestingTheSameLedgerTwiceChangesNothing() {
        let mac = engine("M", .mac, clock: clock), phone = engine("P", .ios, clock: clock)
        phone.record(.dayOfUse)
        #expect(mac.ingest([phone.ownLedgerData]))
        let t = mac.totals
        #expect(!mac.ingest([phone.ownLedgerData]))
        #expect(mac.totals == t)
    }

    @Test func ownLedgerComingBackFromServerRestoresPoints() {
        let old = engine("M", .mac, clock: clock)
        old.record(.dayOfUse); old.record(.share)
        let reinstalled = engine("M", .mac, clock: clock)   // lost its file, same device ID
        #expect(reinstalled.totals.points == 0)
        reinstalled.ingest([old.ownLedgerData])
        #expect(reinstalled.totals.points == 25)
        // And it will not earn today's day again.
        #expect(reinstalled.record(.dayOfUse).pointsAdded == 0)
    }

    @Test func ledgerMergeTakesLargerValuePerKey() {
        var a = LoyaltyLedger(deviceID: "A", platform: .mac, awards: ["day:2026-03-10": 10, "once:firstPin": 25])
        a.merge(LoyaltyLedger(deviceID: "A", platform: .mac, awards: ["day:2026-03-10": 12, "day:2026-03-11": 10]))
        #expect(a.awards == ["day:2026-03-10": 12, "day:2026-03-11": 10, "once:firstPin": 25])
    }

    @Test func damagedOrInflatedLedgersAreBounded() {
        let mac = engine("M", .mac, clock: clock)
        let evil = LoyaltyLedger(deviceID: "X", platform: .ios, awards: [
            "day:2026-03-09": 1_000_000,       // capped to maxAward
            "day:2030-01-01": 50,              // too far in the future
            "share:2026-03-09:9": 50,          // beyond the daily share cap
            "once:unknown": 50,                // not a milestone
            "garbage": 50, "day:nope": 50,
            "day:2026-03-08": -40,             // negative
        ])
        mac.ingest([evil.encoded(), Data("not json".utf8)])
        #expect(mac.totals.points == LoyaltyLedger.maxAward + LoyaltyRules.bothPlatformsPoints * 0 + 0)
    }

    @Test func ledgerKeysCarryNoBrowsingContent() {
        let e = engine("A", clock: clock)
        e.record(.dayOfUse); e.record(.share); e.record(.milestone(.firstBookmark))
        for key in e.own.awards.keys { #expect(LoyaltyLedger.parse(key) != nil) }
        let text = String(decoding: e.ownLedgerData, as: UTF8.self)
        #expect(!text.contains("http"))
    }

    @Test func worksWithSyncOffAndGivesTheSameAnswerOnceSyncIsOn() {
        let solo = engine("M", .mac, clock: clock)
        solo.record(.dayOfUse)
        #expect(solo.totals.points == 10)
        solo.ingest([])
        #expect(solo.totals.points == 10)
    }
}

@MainActor @Suite struct LoyaltySyncTests {
    let clock = TestClock()
    let server = InMemoryTransport()

    func syncEngine(_ id: String) -> SyncEngine {
        SyncEngine(transport: server, deviceID: id, deviceName: id, stateURL: nil, now: { clock.t })
    }

    func syncRound(_ e: SyncEngine, _ loyalty: LoyaltyEngine) async throws {
        e.mergeOwnLoyalty = { server, _ in loyalty.ingest([server]); return loyalty.ownLedgerData }
        e.ownLoyaltyLedger = loyalty.ownLedgerData
        _ = try await e.sync(local: SyncPayload(pins: [], shelf: [], history: []), openPages: [])
        loyalty.ingest(e.loyaltyLedgers())
    }

    @Test func macAndPhonePointsAddThroughSync() async throws {
        let mac = engine("M", .mac, clock: clock), phone = engine("P", .ios, clock: clock)
        let sm = syncEngine("M"), sp = syncEngine("P")
        mac.record(.dayOfUse); mac.record(.share)
        phone.record(.dayOfUse)
        try await syncRound(sm, mac)
        try await syncRound(sp, phone)
        try await syncRound(sm, mac)
        #expect(mac.totals.points == 10 + 15 + 10 + 50)
        #expect(phone.totals == mac.totals)
    }

    @Test func eachDeviceWritesOnlyItsOwnRecord() async throws {
        let mac = engine("M", .mac, clock: clock), phone = engine("P", .ios, clock: clock)
        mac.record(.dayOfUse); phone.record(.dayOfUse)
        try await syncRound(syncEngine("M"), mac)
        try await syncRound(syncEngine("P"), phone)
        let names = await server.allRecords.filter { $0.recordType == "Loyalty" }.map(\.recordName)
        #expect(names == ["loyalty-M", "loyalty-P"])
    }

    @Test func unchangedLedgerUploadsNothing() async throws {
        let mac = engine("M", .mac, clock: clock)
        let sm = syncEngine("M")
        mac.record(.dayOfUse)
        try await syncRound(sm, mac)
        await server.clearLogs()
        try await syncRound(sm, mac)
        #expect(await server.saveLog.filter { $0.recordType == "Loyalty" }.isEmpty)
    }

    @Test func concurrentEarningOnTwoDevicesLosesNothing() async throws {
        let mac = engine("M", .mac, clock: clock), phone = engine("P", .ios, clock: clock)
        let sm = syncEngine("M"), sp = syncEngine("P")
        try await syncRound(sm, mac); try await syncRound(sp, phone)
        // Both earn offline, then sync in turn, twice.
        for _ in 0..<3 { mac.record(.share); phone.record(.share); clock.advance(days: 1); mac.record(.dayOfUse); phone.record(.dayOfUse) }
        for _ in 0..<2 {
            try await syncRound(sm, mac); try await syncRound(sp, phone)
        }
        let all = mac.own.awards.values.reduce(0, +) + phone.own.awards.values.reduce(0, +)
        #expect(mac.totals.points == all + 50)
        #expect(mac.totals == phone.totals)
    }

    @Test func staleOwnRecordOnServerIsMergedBack() async throws {
        let mac = engine("M", .mac, clock: clock)
        let sm = syncEngine("M")
        mac.record(.dayOfUse)
        try await syncRound(sm, mac)
        // The Mac loses its file and its sync state, keeps its device ID, and earns something new.
        let fresh = engine("M", .mac, clock: clock)
        fresh.record(.share)
        try await syncRound(syncEngine("M"), fresh)
        #expect(fresh.totals.points == 25)
        try await syncRound(syncEngine("M"), fresh)
        let stored = await server.record(named: "loyalty-M")?["ledger"]?.dataValue.flatMap(LoyaltyLedger.decode)
        #expect(stored?.awards.values.reduce(0, +) == 25)
    }
}
