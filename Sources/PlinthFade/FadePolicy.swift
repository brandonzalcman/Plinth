import Foundation
import PlinthModel

/// The tunable constants behind fading. Every duration is in seconds.
///
/// ## The site clock (adaptive)
///
/// A site's *lifetime* is how long it stays on the bar after any of its pages was last used:
///
///     dayPart    = siteBaseLifetime + siteLifetimePerExtraDay × (activeDays − 1)
///     visitBoost = min(maxVisitBoost, 1 + visitBoostPerDoubling × log2(visitCount))
///     lifetime   = min(siteMaxLifetime, dayPart × visitBoost)
///
/// `activeDays` and `visitCount` come from the site key's lifetime `Usage` record, which
/// survives the site leaving the bar. With the standard constants:
///
/// | Site                                   | Lifetime          |
/// |----------------------------------------|-------------------|
/// | opened once (1 day, 1 visit)           | 20 h              |
/// | one day, 4 visits                      | 30 h              |
/// | 2 days, 4 visits                       | 75 h (~3 days)    |
/// | 3 days, 8 visits                       | 140 h (~6 days)   |
/// | 5 days, 16+ visits                     | 280 h (~11.7 days)|
/// | 7+ days, 16+ visits                    | 14 days (the cap) |
///
/// Any use of any page in the site restarts the clock, so a site used daily never gets close.
///
/// ## The page clock (short, nearly fixed)
///
/// Inside a site with two or more pages, every page except the most recently used one has
/// its own lifetime, measured from when that page was last used:
///
///     pageLifetime = min(pageMaxLifetime, pageBaseLifetime × visitBoost(page.visitCount))
///
/// which is 12 h for a page opened once and at most 24 h.
///
/// ## The dashed stage
///
/// On both clocks the item is `.fading` for the last part of its lifetime:
///
///     dashed = min(lifetime, max(fadingFraction × lifetime, minFadingDuration))
///
/// so a one-off site is solid for 15 h, dashed for 5 h, then shelved.
public struct FadePolicy: Sendable, Equatable {
    /// Lifetime of a site used on one day, once. Standard: 20 hours.
    public var siteBaseLifetime: TimeInterval
    /// Added for each further distinct day the site was used. Standard: 30 hours.
    public var siteLifetimePerExtraDay: TimeInterval
    /// No site outlives this without being used. Standard: 14 days.
    public var siteMaxLifetime: TimeInterval
    /// Lifetime of a page opened once, inside a site with other pages. Standard: 12 hours.
    public var pageBaseLifetime: TimeInterval
    /// No page outlives this on the page clock. Standard: 24 hours.
    public var pageMaxLifetime: TimeInterval
    /// Extra lifetime per doubling of the visit count, as a share of the unboosted lifetime. Standard: 0.25.
    public var visitBoostPerDoubling: Double
    /// Ceiling on the visit multiplier. Standard: 2 (reached at 16 visits).
    public var maxVisitBoost: Double
    /// Share of a lifetime spent dashed, at its end. Standard: 0.25.
    public var fadingFraction: Double
    /// The dashed stage is never shorter than this (unless the whole lifetime is). Standard: 1 hour.
    public var minFadingDuration: TimeInterval
    /// When true nothing fades by itself: every site and page stays live until put away by hand.
    public var neverFades: Bool

    public init(siteBaseLifetime: TimeInterval = 20 * 3600,
                siteLifetimePerExtraDay: TimeInterval = 30 * 3600,
                siteMaxLifetime: TimeInterval = 14 * 86400,
                pageBaseLifetime: TimeInterval = 12 * 3600,
                pageMaxLifetime: TimeInterval = 24 * 3600,
                visitBoostPerDoubling: Double = 0.25,
                maxVisitBoost: Double = 2,
                fadingFraction: Double = 0.25,
                minFadingDuration: TimeInterval = 3600,
                neverFades: Bool = false) {
        self.siteBaseLifetime = siteBaseLifetime
        self.siteLifetimePerExtraDay = siteLifetimePerExtraDay
        self.siteMaxLifetime = siteMaxLifetime
        self.pageBaseLifetime = pageBaseLifetime
        self.pageMaxLifetime = pageMaxLifetime
        self.visitBoostPerDoubling = visitBoostPerDoubling
        self.maxVisitBoost = maxVisitBoost
        self.fadingFraction = fadingFraction
        self.minFadingDuration = minFadingDuration
        self.neverFades = neverFades
    }

    public static let standard = FadePolicy()

    /// The same policy with every lifetime multiplied by `factor` (the visit boost and dashed share are
    /// unchanged). A factor of 1 returns the policy as is, and an infinite factor sets `neverFades`.
    /// Other factors are kept finite and positive (at least 0.01).
    public func scaled(by factor: Double) -> FadePolicy {
        var policy = self
        if factor == .infinity { policy.neverFades = true; return policy }
        let f = factor.isFinite ? max(0.01, factor) : 1
        policy.siteBaseLifetime *= f
        policy.siteLifetimePerExtraDay *= f
        policy.siteMaxLifetime *= f
        policy.pageBaseLifetime *= f
        policy.pageMaxLifetime *= f
        policy.neverFades = false
        return policy
    }

    // MARK: Formula

    /// `min(maxVisitBoost, 1 + visitBoostPerDoubling × log2(visitCount))`, never below 1.
    public func visitBoost(visitCount: Int) -> Double {
        let visits = Double(max(1, visitCount))
        let boost = 1 + max(0, visitBoostPerDoubling) * log2(visits)
        return max(1, min(max(1, maxVisitBoost), boost))
    }

    /// How long a site stays on the bar after its last use. A site with no record counts as a one-off.
    public func siteLifetime(for stats: Usage?) -> TimeInterval {
        let extraDays = Double(max(1, stats?.activeDays ?? 1) - 1)
        let dayPart = max(0, siteBaseLifetime) + max(0, siteLifetimePerExtraDay) * extraDays
        return min(max(0, siteMaxLifetime), dayPart * visitBoost(visitCount: stats?.visitCount ?? 1))
    }

    /// How long a page that is not its site's most recent stays on the bar after its last use.
    public func pageLifetime(for usage: Usage) -> TimeInterval {
        min(max(0, pageMaxLifetime), max(0, pageBaseLifetime) * visitBoost(visitCount: usage.visitCount))
    }

    /// Length of the dashed stage at the end of a lifetime.
    public func fadingDuration(forLifetime lifetime: TimeInterval) -> TimeInterval {
        min(lifetime, max(min(1, max(0, fadingFraction)) * lifetime, minFadingDuration))
    }
}
