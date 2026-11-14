import Foundation

/// The platform a device earns points on.
public enum LoyaltyPlatform: String, Codable, Sendable, CaseIterable {
    case mac, ios
}

/// One-off feature milestones. Each is worth points once per iCloud account, however many devices
/// reach it.
public enum LoyaltyMilestone: String, Codable, Sendable, CaseIterable {
    case firstPin, firstBookmark, firstSplitView, firstAsk, syncOn
}

/// What a device has earned, as counters that only ever grow.
///
/// A ledger holds *awards*: a key naming what was earned (never what was browsed) and the points
/// it was worth when earned. Each key is written once and never changes, so two copies of one
/// ledger merge by taking the larger value per key, and the ledgers of different devices simply
/// add up. Nothing in here names a page, a site or a search; keys carry only a kind and a date.
///
/// Key forms:
/// - `day:yyyy-MM-dd`: the first use of the day on this device (daily points plus streak bonus).
/// - `share:yyyy-MM-dd:n`: the n-th share of that day on this device.
/// - `once:<milestone>`: a one-off milestone (counted once across all devices).
public struct LoyaltyLedger: Codable, Equatable, Sendable {
    public var deviceID: String
    public var platform: LoyaltyPlatform
    public var awards: [String: Int]

    public init(deviceID: String, platform: LoyaltyPlatform, awards: [String: Int] = [:]) {
        self.deviceID = deviceID; self.platform = platform; self.awards = awards
    }

    /// The largest award a single key may carry, and the most keys one ledger may hold. Values from
    /// another device (which could be damaged or edited) beyond these are ignored.
    public static let maxAward = 100
    public static let maxKeys = 4_000

    /// Merges two copies of the same device's ledger: the larger value per key.
    public mutating func merge(_ other: LoyaltyLedger) {
        for (k, v) in other.awards where v > (awards[k] ?? 0) { awards[k] = v }
    }

    // MARK: Keys

    static func dayKey(_ day: String) -> String { "day:" + day }
    static func shareKey(_ day: String, _ n: Int) -> String { "share:\(day):\(n)" }
    static func onceKey(_ m: LoyaltyMilestone) -> String { "once:" + m.rawValue }

    enum KeyKind: Equatable {
        case day(String)
        case share(String)
        case once(LoyaltyMilestone)
    }

    static func parse(_ key: String) -> KeyKind? {
        if key.hasPrefix("day:") {
            let d = String(key.dropFirst(4))
            return isDay(d) ? .day(d) : nil
        }
        if key.hasPrefix("share:") {
            let rest = key.dropFirst(6).split(separator: ":")
            guard rest.count == 2, isDay(String(rest[0])), let n = Int(rest[1]), (1...LoyaltyRules.maxSharesPerDay).contains(n) else { return nil }
            return .share(String(rest[0]))
        }
        if key.hasPrefix("once:"), let m = LoyaltyMilestone(rawValue: String(key.dropFirst(5))) { return .once(m) }
        return nil
    }

    static func isDay(_ s: String) -> Bool {
        let p = s.split(separator: "-")
        guard p.count == 3, p[0].count == 4, p[1].count == 2, p[2].count == 2,
              let y = Int(p[0]), let m = Int(p[1]), let d = Int(p[2]) else { return false }
        return (2020...2200).contains(y) && (1...12).contains(m) && (1...31).contains(d)
    }

    // MARK: Encoding

    public func encoded() -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return (try? enc.encode(self)) ?? Data()
    }

    public static func decode(_ data: Data) -> LoyaltyLedger? {
        guard let l = try? JSONDecoder().decode(LoyaltyLedger.self, from: data), !l.deviceID.isEmpty else { return nil }
        return l
    }
}
