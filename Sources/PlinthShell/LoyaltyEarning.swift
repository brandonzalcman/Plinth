import PlinthLoyalty
import PlinthSettings

/// What the app looks like at a loyalty tick, reduced to what earns points. Nothing here names a page.
public struct LoyaltySnapshot: Equatable, Sendable {
    /// The active window is a private window: a day of use is not counted from one.
    public var keyWindowIsPrivate = false
    public var hasPins = false
    /// An ordinary (not private) window has a split view on.
    public var hasSplitInOrdinaryWindow = false
    public var hasBookmarks = false
    public var syncIsOn = false

    public init(keyWindowIsPrivate: Bool = false, hasPins: Bool = false, hasSplitInOrdinaryWindow: Bool = false,
                hasBookmarks: Bool = false, syncIsOn: Bool = false) {
        self.keyWindowIsPrivate = keyWindowIsPrivate; self.hasPins = hasPins
        self.hasSplitInOrdinaryWindow = hasSplitInOrdinaryWindow; self.hasBookmarks = hasBookmarks; self.syncIsOn = syncIsOn
    }
}

/// Maps the app's state to the loyalty events it earns, as the Mac app does. The first-Ask milestone
/// is earned when an answer comes back.
public enum LoyaltyEarning {
    /// The events for one tick (at launch, on activation and every few seconds while Plinth is active).
    /// Repeats are free: the engine pays a day once and a milestone once.
    public static func tickEvents(_ s: LoyaltySnapshot) -> [LoyaltyEvent] {
        var events: [LoyaltyEvent] = []
        if !s.keyWindowIsPrivate { events.append(.dayOfUse) }
        if s.hasPins { events.append(.milestone(.firstPin)) }
        if s.hasSplitInOrdinaryWindow { events.append(.milestone(.firstSplitView)) }
        if s.hasBookmarks { events.append(.milestone(.firstBookmark)) }
        if s.syncIsOn { events.append(.milestone(.syncOn)) }
        return events
    }

    /// The colourway a level unlocks, if any (level 1's Sunrise is always there, so it is not an unlock).
    public static func unlock(for level: LoyaltyLevel) -> LoyaltyColourway? {
        LoyaltyColourway.all.first { $0.unlockLevel == level.number && $0.unlockLevel > 1 }
    }
}

extension AccentChoice {
    /// The level that unlocks this accent: the colourway accents unlock with their level, the rest are free.
    public var unlockLevel: Int { LoyaltyColourway.named(rawValue)?.unlockLevel ?? 1 }

    /// The accent actually in use at `level`. A brand colour the level has not unlocked falls back to
    /// the default blue. With no level known yet, the choice stands.
    public func effective(atLevel level: Int?) -> AccentChoice {
        guard unlockLevel > 1, let level, unlockLevel > level else { return self }
        return .blue
    }
}
