import Foundation

/// Point values, caps and levels. One place, so Mac and iOS agree.
public enum LoyaltyRules {
    /// Points for the first use of a day on a platform.
    public static let dailyPoints = 10
    /// Extra points per consecutive day already in the streak, capped.
    public static let streakBonusPerDay = 2
    public static let streakBonusCap = 10
    public static let sharePoints = 15
    /// Shares that earn points, per platform per day.
    public static let maxSharesPerDay = 3
    public static let milestonePoints = 25
    /// Once, when the same iCloud account has earned on both a Mac and an iPhone.
    public static let bothPlatformsPoints = 50
    /// Day keys further than this many days past today are ignored (a wrong clock's key does not count until its date).
    public static let maxFutureDays = 2
}

public struct LoyaltyLevel: Equatable, Sendable, Identifiable {
    /// 1-based.
    public let number: Int
    public let name: String
    /// Points needed to reach it.
    public let threshold: Int
    public var id: Int { number }
}

public extension LoyaltyLevel {
    /// The six levels, named for the parts of a building the logo is made of.
    static let all: [LoyaltyLevel] = [
        LoyaltyLevel(number: 1, name: "Footing", threshold: 0),
        LoyaltyLevel(number: 2, name: "Step", threshold: 100),
        LoyaltyLevel(number: 3, name: "Column", threshold: 300),
        LoyaltyLevel(number: 4, name: "Arch", threshold: 700),
        LoyaltyLevel(number: 5, name: "Keystone", threshold: 1_500),
        LoyaltyLevel(number: 6, name: "Cornerstone", threshold: 3_000),
    ]

    static func level(forPoints points: Int) -> LoyaltyLevel {
        all.last { points >= $0.threshold } ?? all[0]
    }

    static func level(number: Int) -> LoyaltyLevel { all[max(0, min(all.count, number) - 1)] }

    var next: LoyaltyLevel? { Self.all.first { $0.number == number + 1 } }
}

/// The brand colourways (docs/brand-guide.md): app icon, bar accent theme and share card all use these.
public struct LoyaltyColourway: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    /// The level that unlocks it. Sunrise is level 1, so always available.
    public let unlockLevel: Int
    public let tile: String
    /// Sky gradient, top to bottom (hex, no alpha).
    public let sky: [String]
    public let sun: String
    public let frame: String

    public static let sunrise = LoyaltyColourway(id: "sunrise", name: "Sunrise", unlockLevel: 1, tile: "#F6F1E7", sky: ["#2F5BEA", "#93AAFF", "#FFC9A3"], sun: "#FFF1DA", frame: "#1C1C1A")
    public static let dusk = LoyaltyColourway(id: "dusk", name: "Dusk", unlockLevel: 2, tile: "#1B1A2E", sky: ["#3A2A7A", "#B0509A", "#FF9E7A"], sun: "#FFE0B8", frame: "#F4EEE6")
    public static let meadow = LoyaltyColourway(id: "meadow", name: "Meadow", unlockLevel: 3, tile: "#EEF3E8", sky: ["#0F6B5B", "#7CC8A6", "#F4E7A1"], sun: "#FFFBE0", frame: "#14231F")
    public static let ember = LoyaltyColourway(id: "ember", name: "Ember", unlockLevel: 4, tile: "#FBEDE3", sky: ["#B8361E", "#F08A4B", "#FFD9A0"], sun: "#FFF3D6", frame: "#2A1712")
    public static let midnight = LoyaltyColourway(id: "midnight", name: "Midnight", unlockLevel: 5, tile: "#0E1220", sky: ["#0B1E5B", "#2F5BEA", "#8FD3FF"], sun: "#EAF6FF", frame: "#E9ECF5")
    public static let mono = LoyaltyColourway(id: "mono", name: "Mono", unlockLevel: 6, tile: "#FFFFFF", sky: ["#1C1C1A"], sun: "#FFFFFF", frame: "#1C1C1A")

    public static let all: [LoyaltyColourway] = [sunrise, dusk, meadow, ember, midnight, mono]

    public static func named(_ id: String) -> LoyaltyColourway? { all.first { $0.id == id } }
}
