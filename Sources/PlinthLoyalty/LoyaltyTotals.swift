import Foundation

/// Everything derived from the ledgers of every device on the account.
public struct LoyaltyTotals: Equatable, Sendable {
    public var points: Int
    public var level: LoyaltyLevel
    /// Points into the current level and the size of the step to the next one (nil at the top).
    public var progress: (earned: Int, needed: Int)?
    /// Consecutive days of use ending today (or yesterday, if today has no use yet), on any device.
    public var streak: Int
    /// Days of use, counted on each device and added together.
    public var daysOfUse: Int
    public var shares: Int
    public var milestones: Set<LoyaltyMilestone>
    public var bothPlatforms: Bool

    public static func == (a: LoyaltyTotals, b: LoyaltyTotals) -> Bool {
        a.points == b.points && a.level == b.level && a.streak == b.streak && a.daysOfUse == b.daysOfUse
            && a.shares == b.shares && a.milestones == b.milestones && a.bothPlatforms == b.bothPlatforms
            && a.progress?.earned == b.progress?.earned && a.progress?.needed == b.progress?.needed
    }

    /// Adds up ledgers.
    ///
    /// A day of use and a share count once per **platform** per day: ledgers of the same platform
    /// (two Macs, or one Mac after a reinstall gave it a new device ID) are merged key by key first, so
    /// the same day is never paid twice. Mac and iPhone add together. Milestone keys count once across
    /// everything, and the both-platforms bonus applies once when a Mac and an iPhone have earned.
    /// `today` is a `yyyy-MM-dd` day; day keys more than `maxFutureDays` past it are ignored.
    public static func compute(ledgers: [LoyaltyLedger], today: String) -> LoyaltyTotals {
        let latest = LoyaltyDay.string(byAdding: LoyaltyRules.maxFutureDays, to: today) ?? today
        var perPlatform: [LoyaltyPlatform: [String: Int]] = [:]
        for ledger in ledgers {
            for (key, raw) in ledger.awards {
                let value = min(max(raw, 0), LoyaltyLedger.maxAward)
                if value > (perPlatform[ledger.platform]?[key] ?? 0) { perPlatform[ledger.platform, default: [:]][key] = value }
            }
        }
        var points = 0, days = 0, shares = 0
        var once: [LoyaltyMilestone: Int] = [:]
        var dayStrings = Set<String>()
        for awards in perPlatform.values {
            for (key, value) in awards {
                guard value > 0, let kind = LoyaltyLedger.parse(key) else { continue }
                switch kind {
                case .day(let d):
                    guard d <= latest else { continue }
                    points += value; days += 1; dayStrings.insert(d)
                case .share(let d):
                    guard d <= latest else { continue }
                    points += value; shares += 1
                case .once(let m):
                    once[m] = max(once[m] ?? 0, value)
                }
            }
        }
        points += once.values.reduce(0, +)
        let both = perPlatform.filter { $0.value.contains { LoyaltyLedger.parse($0.key) != nil && $0.value > 0 } }.count >= 2
        if both { points += LoyaltyRules.bothPlatformsPoints }
        let level = LoyaltyLevel.level(forPoints: points)
        var progress: (Int, Int)?
        if let next = level.next { progress = (points - level.threshold, next.threshold - level.threshold) }
        return LoyaltyTotals(points: points, level: level, progress: progress,
                             streak: streak(days: dayStrings, today: today),
                             daysOfUse: days, shares: shares, milestones: Set(once.keys), bothPlatforms: both)
    }

    static func streak(days: Set<String>, today: String) -> Int {
        var cursor = today
        if !days.contains(cursor), let y = LoyaltyDay.string(byAdding: -1, to: cursor) { cursor = y }
        var n = 0
        while days.contains(cursor) {
            n += 1
            guard let prev = LoyaltyDay.string(byAdding: -1, to: cursor) else { break }
            cursor = prev
        }
        return n
    }
}

/// Local calendar days as `yyyy-MM-dd` strings. They sort as dates. Always the Gregorian calendar,
/// whatever calendar the Mac displays, so keys look the same on every device.
public enum LoyaltyDay {
    static func calendar(_ zone: TimeZone) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = zone
        return c
    }

    public static func string(for date: Date, in zone: TimeZone = .current) -> String {
        let c = calendar(zone).dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    public static func string(byAdding days: Int, to day: String) -> String? {
        let p = day.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        guard let d = cal.date(from: DateComponents(year: p[0], month: p[1], day: p[2], hour: 12)),
              let n = cal.date(byAdding: .day, value: days, to: d) else { return nil }
        let c = cal.dateComponents([.year, .month, .day], from: n)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
