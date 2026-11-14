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

    /// Adds up ledgers. Per-device awards sum; milestone keys count once however many devices hold
    /// them; the both-platforms bonus applies once when ledgers from a Mac and an iPhone exist.
    /// `today` is a `yyyy-MM-dd` day; day keys too far past it are ignored.
    public static func compute(ledgers: [LoyaltyLedger], today: String, calendar: Calendar) -> LoyaltyTotals {
        let latest = LoyaltyDay.string(byAdding: LoyaltyRules.maxFutureDays, to: today, calendar: calendar) ?? today
        var points = 0, days = 0, shares = 0
        var once: [LoyaltyMilestone: Int] = [:]
        var dayStrings = Set<String>()
        var platforms = Set<LoyaltyPlatform>()
        for ledger in ledgers {
            var earnedAnything = false
            for (key, raw) in ledger.awards.prefix(LoyaltyLedger.maxKeys) {
                let value = min(max(raw, 0), LoyaltyLedger.maxAward)
                guard value > 0, let kind = LoyaltyLedger.parse(key) else { continue }
                switch kind {
                case .day(let d):
                    guard d <= latest else { continue }
                    points += value; days += 1; dayStrings.insert(d); earnedAnything = true
                case .share(let d):
                    guard d <= latest else { continue }
                    points += value; shares += 1; earnedAnything = true
                case .once(let m):
                    once[m] = max(once[m] ?? 0, value); earnedAnything = true
                }
            }
            if earnedAnything { platforms.insert(ledger.platform) }
        }
        points += once.values.reduce(0, +)
        let both = platforms.count >= 2
        if both { points += LoyaltyRules.bothPlatformsPoints }
        let level = LoyaltyLevel.level(forPoints: points)
        var progress: (Int, Int)?
        if let next = level.next { progress = (points - level.threshold, next.threshold - level.threshold) }
        return LoyaltyTotals(points: points, level: level, progress: progress,
                             streak: streak(days: dayStrings, today: today, calendar: calendar),
                             daysOfUse: days, shares: shares, milestones: Set(once.keys), bothPlatforms: both)
    }

    static func streak(days: Set<String>, today: String, calendar: Calendar) -> Int {
        var cursor = today
        if !days.contains(cursor), let y = LoyaltyDay.string(byAdding: -1, to: cursor, calendar: calendar) { cursor = y }
        var n = 0
        while days.contains(cursor) {
            n += 1
            guard let prev = LoyaltyDay.string(byAdding: -1, to: cursor, calendar: calendar) else { break }
            cursor = prev
        }
        return n
    }
}

/// Local calendar days as `yyyy-MM-dd` strings. They sort as dates.
public enum LoyaltyDay {
    public static func string(for date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    public static func date(from day: String, calendar: Calendar) -> Date? {
        let p = day.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2], hour: 12))
    }

    public static func string(byAdding days: Int, to day: String, calendar: Calendar) -> String? {
        guard let d = date(from: day, calendar: calendar), let n = calendar.date(byAdding: .day, value: days, to: d) else { return nil }
        return string(for: n, calendar: calendar)
    }
}
