import Foundation
import Testing
import PlinthModel
@testable import PlinthFade

private let hour: TimeInterval = 3600
private let day: TimeInterval = 86400
/// A fixed origin; every test measures from here.
private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

private func page(_ name: String = "Page", used: Date = t0, visits: Int = 1) -> Page {
    Page(url: URL(string: "https://example.com/\(name)")!, name: name,
         usage: Usage(visitCount: visits, activeDays: 1, firstUsed: used, lastUsed: used))
}

private func site(_ host: String, _ pages: [Page], kept: Bool = false, current: PageID? = nil) -> Site {
    Site(key: SiteKey(host), name: host, pages: pages, currentPageID: current, isKept: kept)
}

private func site(_ pages: [Page], kept: Bool = false, current: PageID? = nil) -> Site {
    site("example.com", pages, kept: kept, current: current)
}

private func usage(visits: Int = 1, days: Int = 1, last: Date = t0) -> Usage {
    Usage(visitCount: visits, activeDays: days, firstUsed: t0.addingTimeInterval(-30 * day), lastUsed: last)
}

/// What the store does with a verdict.
private func apply(_ verdict: FadeVerdict, to sites: [Site]) -> [Site] {
    sites.compactMap { original in
        guard !verdict.sitesToShelve.contains(original.id) else { return nil }
        var site = original
        site.pages.removeAll { verdict.pagesToShelve.contains($0.id) }
        guard !site.pages.isEmpty else { return nil }
        if let stage = verdict.siteStages[site.id] { site.fade = stage }
        for i in site.pages.indices {
            if let stage = verdict.pageStages[site.pages[i].id] { site.pages[i].fade = stage }
        }
        return site
    }
}

private let engine = FadeEngine()

@Suite struct PolicyFormula {
    let policy = FadePolicy.standard

    @Test func oneOffSiteLivesTwentyHours() {
        #expect(policy.siteLifetime(for: usage()) == 20 * hour)
    }

    @Test func missingStatsCountAsOneOff() {
        #expect(policy.siteLifetime(for: nil) == 20 * hour)
    }

    @Test func documentedExamples() {
        #expect(policy.siteLifetime(for: usage(visits: 4, days: 1)) == 30 * hour)
        #expect(policy.siteLifetime(for: usage(visits: 4, days: 2)) == 75 * hour)
        #expect(policy.siteLifetime(for: usage(visits: 8, days: 3)) == 140 * hour)
        #expect(policy.siteLifetime(for: usage(visits: 16, days: 5)) == 280 * hour)
    }

    @Test func lifetimeIsCappedAtFourteenDays() {
        #expect(policy.siteLifetime(for: usage(visits: 5000, days: 400)) == 14 * day)
        #expect(policy.siteLifetime(for: usage(visits: 16, days: 7)) == 14 * day)
    }

    @Test func visitBoostIsCappedAtTwo() {
        #expect(policy.visitBoost(visitCount: 1) == 1)
        #expect(policy.visitBoost(visitCount: 16) == 2)
        #expect(policy.visitBoost(visitCount: 1_000_000) == 2)
    }

    @Test func nonsenseCountsAreTreatedAsOne() {
        #expect(policy.visitBoost(visitCount: 0) == 1)
        #expect(policy.visitBoost(visitCount: -5) == 1)
        #expect(policy.siteLifetime(for: usage(visits: 0, days: -3)) == 20 * hour)
    }

    @Test func siteLifetimeNeverShrinksWithMoreUse() {
        var previousByDays = 0.0
        for days in 1...40 {
            var previousByVisits = 0.0
            for visits in 1...60 {
                let life = policy.siteLifetime(for: usage(visits: visits, days: days))
                #expect(life >= previousByVisits)
                previousByVisits = life
            }
            let life = policy.siteLifetime(for: usage(visits: 3, days: days))
            #expect(life >= previousByDays)
            previousByDays = life
        }
    }

    @Test func pageLifetimeIsShortAndBounded() {
        #expect(policy.pageLifetime(for: usage()) == 12 * hour)
        #expect(policy.pageLifetime(for: usage(visits: 4)) == 18 * hour)
        #expect(policy.pageLifetime(for: usage(visits: 9999, days: 300)) == 24 * hour)
    }

    @Test func dashedStageIsLastQuarterButAtLeastAnHour() {
        #expect(policy.fadingDuration(forLifetime: 20 * hour) == 5 * hour)
        #expect(policy.fadingDuration(forLifetime: 2 * hour) == hour)
        #expect(policy.fadingDuration(forLifetime: 0.5 * hour) == 0.5 * hour)
    }

    @Test func fadeStartNeverMovesEarlierAsLifetimeGrows() {
        var previous = -1.0
        for minutes in stride(from: 0, through: 60 * 24 * 15, by: 7) {
            let life = Double(minutes) * 60
            let start = life - policy.fadingDuration(forLifetime: life)
            #expect(start >= previous)
            previous = start
        }
    }

    @Test func customPolicyIsHonoured() {
        let quick = FadeEngine(policy: FadePolicy(siteBaseLifetime: 2 * hour, minFadingDuration: 600))
        let s = site([page()])
        let outlook = quick.outlook(for: s, stats: nil, now: t0)
        #expect(outlook?.shelvesAt == t0.addingTimeInterval(2 * hour))
        #expect(outlook?.fadesAt == t0.addingTimeInterval(1.5 * hour))
        #expect(quick.policy != .standard)
    }
}

@Suite struct SiteClock {
    @Test func freshSiteIsLive() {
        let s = site([page()])
        let v = engine.evaluate(sites: [s], stats: [s.key: usage()], visible: [], now: t0.addingTimeInterval(hour))
        #expect(v.siteStages == [s.id: .live])
        #expect(v.pageStages == [s.pages[0].id: .live])
        #expect(v.pagesToShelve.isEmpty && v.sitesToShelve.isEmpty)
    }

    @Test func oneOffSiteGoesDashedAfterFifteenHours() {
        let s = site([page()])
        let before = engine.evaluate(sites: [s], stats: [s.key: usage()], visible: [], now: t0.addingTimeInterval(15 * hour - 1))
        let after = engine.evaluate(sites: [s], stats: [s.key: usage()], visible: [], now: t0.addingTimeInterval(15 * hour))
        #expect(before.siteStages[s.id] == .live)
        #expect(after.siteStages[s.id] == .fading)
        #expect(after.pageStages[s.pages[0].id] == .fading)
        #expect(after.sitesToShelve.isEmpty)
    }

    @Test func oneOffSiteIsShelvedWithinADay() {
        let s = site([page()])
        let v = engine.evaluate(sites: [s], stats: [s.key: usage()], visible: [], now: t0.addingTimeInterval(day))
        #expect(v.sitesToShelve == [s.id])
        #expect(v.siteStages.isEmpty && v.pageStages.isEmpty && v.pagesToShelve.isEmpty)
        #expect(v.nextCheck == nil)
    }

    @Test func oneOffSiteIsStillOnTheBarJustBeforeTwentyHours() {
        let s = site([page()])
        let v = engine.evaluate(sites: [s], stats: [s.key: usage()], visible: [], now: t0.addingTimeInterval(20 * hour - 1))
        #expect(v.sitesToShelve.isEmpty)
        #expect(v.siteStages[s.id] == .fading)
    }

    @Test func siteWithoutStatsFadesLikeAOneOff() {
        let s = site([page()])
        let v = engine.evaluate(sites: [s], stats: [:], visible: [], now: t0.addingTimeInterval(20 * hour))
        #expect(v.sitesToShelve == [s.id])
    }

    @Test func dailySiteSurvivesALongWeekend() {
        // Used every weekday for two weeks, last touched Friday evening; Tuesday morning is 3.6 days on.
        let s = site([page()])
        let stats = [s.key: usage(visits: 40, days: 10)]
        let tuesday = engine.evaluate(sites: [s], stats: stats, visible: [], now: t0.addingTimeInterval(3.6 * day))
        #expect(tuesday.siteStages[s.id] == .live)
        #expect(tuesday.sitesToShelve.isEmpty)
    }

    @Test func dailySiteSurvivesAWeekAwayButNotForever() {
        let s = site([page()])
        let stats = [s.key: usage(visits: 40, days: 10)]
        let week = engine.evaluate(sites: [s], stats: stats, visible: [], now: t0.addingTimeInterval(7 * day))
        #expect(week.siteStages[s.id] == .live)
        let dashed = engine.evaluate(sites: [s], stats: stats, visible: [], now: t0.addingTimeInterval(11 * day))
        #expect(dashed.siteStages[s.id] == .fading)
        let gone = engine.evaluate(sites: [s], stats: stats, visible: [], now: t0.addingTimeInterval(14 * day))
        #expect(gone.sitesToShelve == [s.id])
    }

    @Test func usingASiteAgainReturnsItToLive() {
        var s = site([page()])
        let stats = [s.key: usage()]
        let dashed = engine.evaluate(sites: [s], stats: stats, visible: [], now: t0.addingTimeInterval(16 * hour))
        #expect(dashed.siteStages[s.id] == .fading)
        s = apply(dashed, to: [s])[0]
        #expect(s.fade == .fading)

        let again = t0.addingTimeInterval(17 * hour)
        s.pages[0].usage.recordVisit(at: again)
        let v = engine.evaluate(sites: [s], stats: [s.key: usage(visits: 2, last: again)], visible: [], now: again)
        #expect(v.siteStages[s.id] == .live)
        #expect(v.pageStages[s.pages[0].id] == .live)
    }

    @Test func siteClockRunsFromItsMostRecentPage() {
        let old = page("old", used: t0)
        let recent = page("recent", used: t0.addingTimeInterval(10 * hour))
        let s = site([old, recent])
        let v = engine.evaluate(sites: [s], stats: [s.key: usage()], visible: [], now: t0.addingTimeInterval(22 * hour))
        #expect(v.sitesToShelve.isEmpty)
        #expect(v.siteStages[s.id] == .live)
    }

    @Test func shelvedSiteTakesItsPagesWithoutListingThem() {
        let s = site([page("a"), page("b"), page("c")])
        let v = engine.evaluate(sites: [s], stats: [s.key: usage()], visible: [], now: t0.addingTimeInterval(3 * day))
        #expect(v.sitesToShelve == [s.id])
        #expect(v.pagesToShelve.isEmpty)
        #expect(v.pageStages.isEmpty)
    }

    @Test func fadingSiteDrawsEveryPageDashed() {
        // The older page has many visits, so its own clock (24 h) would still call it live at 16 h.
        let busy = page("busy", used: t0, visits: 64)
        let latest = page("latest", used: t0.addingTimeInterval(60))
        let s = site([busy, latest])
        let v = engine.evaluate(sites: [s], stats: [s.key: usage()], visible: [], now: t0.addingTimeInterval(16 * hour))
        #expect(v.siteStages[s.id] == .fading)
        #expect(v.pageStages == [busy.id: .fading, latest.id: .fading])
    }

    @Test func clockSkewLeavesFutureDatedSitesLive() {
        let s = site([page(used: t0.addingTimeInterval(5 * hour))])
        let v = engine.evaluate(sites: [s], stats: [:], visible: [], now: t0)
        #expect(v.siteStages[s.id] == .live)
        #expect(v.nextCheck == t0.addingTimeInterval(20 * hour))
    }

    @Test func emptyWindow() {
        #expect(engine.evaluate(sites: [], stats: [:], visible: [], now: t0) == FadeVerdict())
    }
}

@Suite struct PageClock {
    /// A heavily used site whose own clock is far off, holding one stale and one fresh page.
    private func activeSite(staleUsed: Date = t0, freshUsed: Date) -> (Site, Page, Page, [SiteKey: Usage]) {
        let stale = page("stale", used: staleUsed)
        let fresh = page("fresh", used: freshUsed)
        let s = site([stale, fresh])
        return (s, stale, fresh, [s.key: usage(visits: 50, days: 12, last: freshUsed)])
    }

    @Test func stalePageGoesDashedWhileSiteStaysLive() {
        let now = t0.addingTimeInterval(10 * hour)
        let (s, stale, fresh, stats) = activeSite(freshUsed: now)
        let v = engine.evaluate(sites: [s], stats: stats, visible: [], now: now)
        #expect(v.siteStages[s.id] == .live)
        #expect(v.pageStages == [stale.id: .fading, fresh.id: .live])
        #expect(v.pagesToShelve.isEmpty)
    }

    @Test func pageIsLiveForItsFirstNineHours() {
        let now = t0.addingTimeInterval(9 * hour - 1)
        let (s, stale, _, stats) = activeSite(freshUsed: now)
        #expect(engine.evaluate(sites: [s], stats: stats, visible: [], now: now).pageStages[stale.id] == .live)
    }

    @Test func stalePageIsShelvedAloneWhileSiteStays() {
        let now = t0.addingTimeInterval(13 * hour)
        let (s, stale, fresh, stats) = activeSite(freshUsed: now)
        let v = engine.evaluate(sites: [s], stats: stats, visible: [], now: now)
        #expect(v.pagesToShelve == [stale.id])
        #expect(v.sitesToShelve.isEmpty)
        #expect(v.siteStages == [s.id: .live])
        #expect(v.pageStages == [fresh.id: .live])
    }

    @Test func lastPageIsNeverShelvedByThePageClock() {
        // Both pages are well past the 12 h page lifetime; only the older one goes.
        let (s, stale, fresh, stats) = activeSite(freshUsed: t0.addingTimeInterval(hour))
        let v = engine.evaluate(sites: [s], stats: stats, visible: [], now: t0.addingTimeInterval(3 * day))
        #expect(v.pagesToShelve == [stale.id])
        #expect(v.sitesToShelve.isEmpty)
        #expect(v.pageStages == [fresh.id: .live])
        #expect(engine.lastPage(of: s) == fresh.id)
    }

    @Test func singlePageSiteIgnoresThePageClock() {
        let only = page()
        let s = site([only])
        let v = engine.evaluate(sites: [s], stats: [s.key: usage(visits: 50, days: 12)], visible: [], now: t0.addingTimeInterval(3 * day))
        #expect(v.pagesToShelve.isEmpty && v.sitesToShelve.isEmpty)
        #expect(v.pageStages[only.id] == .live)
    }

    @Test func tieGoesToTheCurrentPage() {
        let a = page("a"), b = page("b"), c = page("c")
        let s = site([a, b, c], current: b.id)
        #expect(engine.lastPage(of: s) == b.id)
        let v = engine.evaluate(sites: [s], stats: [s.key: usage(visits: 50, days: 12)], visible: [], now: t0.addingTimeInterval(2 * day))
        #expect(v.pagesToShelve == [a.id, c.id])
        #expect(v.pageStages == [b.id: .live])
    }

    @Test func tieWithoutCurrentAmongThemGoesToTheLeftmost() {
        let a = page("a", used: t0.addingTimeInterval(hour)), b = page("b", used: t0.addingTimeInterval(hour))
        let c = page("c", used: t0)
        let s = site([a, b, c], current: c.id)
        #expect(engine.lastPage(of: s) == a.id)
    }

    @Test func pagesShelveInBarOrder() {
        let a = page("a", used: t0), b = page("b", used: t0.addingTimeInterval(-hour))
        let fresh = page("fresh", used: t0.addingTimeInterval(20 * hour))
        let first = site("one.example", [a, fresh])
        let second = site("two.example", [b, page("fresh2", used: t0.addingTimeInterval(20 * hour))])
        let stats = [first.key: usage(visits: 50, days: 12), second.key: usage(visits: 50, days: 12)]
        let v = engine.evaluate(sites: [first, second], stats: stats, visible: [], now: t0.addingTimeInterval(20 * hour))
        #expect(v.pagesToShelve == [a.id, b.id])
    }

    @Test func wellUsedPageLastsLongerThanAOneOffPage() {
        let once = page("once", used: t0, visits: 1)
        let often = page("often", used: t0, visits: 16)
        let fresh = page("fresh", used: t0.addingTimeInterval(13 * hour))
        let s = site([once, often, fresh])
        let v = engine.evaluate(sites: [s], stats: [s.key: usage(visits: 50, days: 12)], visible: [], now: t0.addingTimeInterval(13 * hour))
        #expect(v.pagesToShelve == [once.id])
        #expect(v.pageStages[often.id] == .live)
    }

    @Test func revisitedPageReturnsToLive() {
        let now = t0.addingTimeInterval(10 * hour)
        var (s, stale, _, stats) = activeSite(freshUsed: now.addingTimeInterval(-hour))
        #expect(engine.evaluate(sites: [s], stats: stats, visible: [], now: now).pageStages[stale.id] == .fading)
        s.pages[0].usage.recordVisit(at: now)
        stats[s.key]?.recordVisit(at: now)
        #expect(engine.evaluate(sites: [s], stats: stats, visible: [], now: now).pageStages[stale.id] == .live)
    }

    @Test func oneOffSiteLosesItsStalePageBeforeTheSiteGoes() {
        let (s, stale, fresh, _) = activeSite(freshUsed: t0.addingTimeInterval(2 * hour))
        let v = engine.evaluate(sites: [s], stats: [s.key: usage()], visible: [], now: t0.addingTimeInterval(12 * hour))
        #expect(v.pagesToShelve == [stale.id])
        #expect(v.siteStages[s.id] == .live)
        #expect(v.pageStages == [fresh.id: .live])
    }
}

@Suite struct Exemptions {
    @Test func keptSiteNeverFades() {
        let s = site([page("a"), page("b", used: t0.addingTimeInterval(hour))], kept: true)
        let v = engine.evaluate(sites: [s], stats: [s.key: usage()], visible: [], now: t0.addingTimeInterval(365 * day))
        #expect(v.siteStages == [s.id: .live])
        #expect(v.pageStages == [s.pages[0].id: .live, s.pages[1].id: .live])
        #expect(v.pagesToShelve.isEmpty && v.sitesToShelve.isEmpty)
        #expect(v.nextCheck == nil)
    }

    @Test func keptSiteHasNoOutlook() {
        let s = site([page("a"), page("b")], kept: true)
        #expect(engine.outlook(for: s, stats: usage(), now: t0) == nil)
        #expect(engine.pageOutlook(for: s.pages[0].id, in: s) == nil)
    }

    @Test func visibleSinglePageSiteNeverFades() {
        let only = page()
        let s = site([only])
        let v = engine.evaluate(sites: [s], stats: [s.key: usage()], visible: [only.id], now: t0.addingTimeInterval(30 * day))
        #expect(v.siteStages == [s.id: .live])
        #expect(v.pageStages == [only.id: .live])
        #expect(v.sitesToShelve.isEmpty)
        #expect(v.nextCheck == nil)
    }

    @Test func visibleStalePageIsNotShelvedAndHoldsItsSite() {
        // The visible page is the older one (a split partner, say).
        let shown = page("shown", used: t0)
        let latest = page("latest", used: t0.addingTimeInterval(hour))
        let s = site([shown, latest])
        let v = engine.evaluate(sites: [s], stats: [s.key: usage()], visible: [shown.id], now: t0.addingTimeInterval(30 * day))
        #expect(v.pagesToShelve.isEmpty && v.sitesToShelve.isEmpty)
        #expect(v.siteStages == [s.id: .live])
        #expect(v.pageStages == [shown.id: .live, latest.id: .live])
    }

    @Test func otherPagesOfAVisibleSiteStillRunThePageClock() {
        let stale = page("stale", used: t0)
        let middle = page("middle", used: t0.addingTimeInterval(4 * hour))
        let shown = page("shown", used: t0.addingTimeInterval(13 * hour))
        let s = site([stale, middle, shown])
        let v = engine.evaluate(sites: [s], stats: [s.key: usage()], visible: [shown.id], now: t0.addingTimeInterval(13.5 * hour))
        #expect(v.pagesToShelve == [stale.id])
        #expect(v.pageStages == [middle.id: .fading, shown.id: .live])
        #expect(v.siteStages == [s.id: .live])
    }

    @Test func visibilityInOneSiteDoesNotProtectAnother() {
        let shown = page("shown")
        let a = site("a.example", [shown])
        let b = site("b.example", [page("other")])
        let v = engine.evaluate(sites: [a, b], stats: [:], visible: [shown.id], now: t0.addingTimeInterval(day))
        #expect(v.sitesToShelve == [b.id])
        #expect(v.siteStages == [a.id: .live])
    }

    @Test func unknownVisibleIDsAreIgnored() {
        let s = site([page()])
        let v = engine.evaluate(sites: [s], stats: [:], visible: [PageID()], now: t0.addingTimeInterval(day))
        #expect(v.sitesToShelve == [s.id])
    }
}

@Suite struct NextCheck {
    /// A varied window: one-off, daily, a capsule with a stale page, a kept site, a visible site.
    private func window() -> (sites: [Site], stats: [SiteKey: Usage], visible: Set<PageID>) {
        let oneOff = site("search.example", [page("result", used: t0.addingTimeInterval(-2 * hour))])
        let daily = site("mail.example", [page("inbox", used: t0.addingTimeInterval(-hour), visits: 30)])
        let capsule = site("docs.example", [
            page("spec", used: t0.addingTimeInterval(-7 * hour)),
            page("notes", used: t0.addingTimeInterval(-3 * hour), visits: 5),
            page("plan", used: t0.addingTimeInterval(-600)),
        ])
        let kept = site("music.example", [page("player", used: t0.addingTimeInterval(-90 * day))], kept: true)
        let shown = page("now", used: t0)
        let front = site("news.example", [page("older", used: t0.addingTimeInterval(-5 * hour)), shown])
        let stats: [SiteKey: Usage] = [
            oneOff.key: usage(),
            daily.key: usage(visits: 60, days: 15),
            capsule.key: usage(visits: 9, days: 3),
            kept.key: usage(),
            front.key: usage(visits: 3, days: 2),
        ]
        return ([oneOff, daily, capsule, kept, front], stats, [shown.id])
    }

    @Test func liveOneOffSiteNextChecksWhenItGoesDashed() {
        let s = site([page()])
        let v = engine.evaluate(sites: [s], stats: [s.key: usage()], visible: [], now: t0)
        #expect(v.nextCheck == t0.addingTimeInterval(15 * hour))
    }

    @Test func dashedSiteNextChecksWhenItIsShelved() {
        let s = site([page()])
        let v = engine.evaluate(sites: [s], stats: [s.key: usage()], visible: [], now: t0.addingTimeInterval(15 * hour))
        #expect(v.nextCheck == t0.addingTimeInterval(20 * hour))
    }

    @Test func nextCheckIsNilWhenNothingCanChange() {
        let shown = page()
        let sites = [site("a.example", [shown]), site("b.example", [page()], kept: true)]
        #expect(engine.evaluate(sites: sites, stats: [:], visible: [shown.id], now: t0.addingTimeInterval(9 * day)).nextCheck == nil)
    }

    @Test func nextCheckPicksTheEarliestClock() {
        let stale = page("stale", used: t0)
        let fresh = page("fresh", used: t0.addingTimeInterval(hour))
        let capsule = site("a.example", [stale, fresh])
        let single = site("b.example", [page("single", used: t0.addingTimeInterval(-10 * hour))])
        let v = engine.evaluate(sites: [capsule, single], stats: [:], visible: [], now: t0.addingTimeInterval(2 * hour))
        // b.example goes dashed 15 h after its use, i.e. at t0 + 5 h; the stale page not until t0 + 9 h.
        #expect(v.nextCheck == t0.addingTimeInterval(5 * hour))
    }

    @Test func nextCheckSkipsPageStepsHiddenByADashedSite() {
        // Site dashed from 15 h; the busy page's own clock would step at 18 h, but it is already
        // drawn dashed with its site, so the next visible change is the site shelving at 20 h + 60 s.
        let busy = page("busy", used: t0, visits: 64)
        let latest = page("latest", used: t0.addingTimeInterval(60))
        let s = site([busy, latest])
        let v = engine.evaluate(sites: [s], stats: [s.key: usage()], visible: [], now: t0.addingTimeInterval(16 * hour))
        #expect(v.nextCheck == t0.addingTimeInterval(20 * hour + 60))
    }

    @Test func nextCheckIgnoresWhatThisVerdictAlreadyShelves() {
        let gone = site("a.example", [page("gone", used: t0.addingTimeInterval(-5 * day))])
        let stays = site("b.example", [page("stays", used: t0)])
        let v = engine.evaluate(sites: [gone, stays], stats: [:], visible: [], now: t0)
        #expect(v.sitesToShelve == [gone.id])
        #expect(v.nextCheck == t0.addingTimeInterval(15 * hour))
    }

    @Test func nextCheckIsAlwaysInTheFuture() {
        let w = window()
        for step in 0..<400 {
            let now = t0.addingTimeInterval(Double(step) * 1800)
            if let next = engine.evaluate(sites: w.sites, stats: w.stats, visible: w.visible, now: now).nextCheck {
                #expect(next > now)
            }
        }
    }

    /// Follows the timer from check to check until nothing is left to change. At each stop:
    /// just before the instant nothing differs from the previous verdict; at the instant something does.
    @Test func everyNextCheckChangesSomethingAndNothingChangesBefore() {
        let w = window()
        var sites = w.sites
        var now = t0
        var verdict = engine.evaluate(sites: sites, stats: w.stats, visible: w.visible, now: now)
        sites = apply(verdict, to: sites)
        var hops = 0
        while let next = verdict.nextCheck {
            hops += 1
            #expect(next > now)

            let settled = engine.evaluate(sites: sites, stats: w.stats, visible: w.visible, now: now)
            let justBefore = engine.evaluate(sites: sites, stats: w.stats, visible: w.visible, now: next.addingTimeInterval(-1))
            #expect(justBefore.pageStages == settled.pageStages)
            #expect(justBefore.siteStages == settled.siteStages)
            #expect(justBefore.pagesToShelve.isEmpty && justBefore.sitesToShelve.isEmpty)
            #expect(justBefore.nextCheck == next)

            let at = engine.evaluate(sites: sites, stats: w.stats, visible: w.visible, now: next)
            let changed = at.pageStages != settled.pageStages || at.siteStages != settled.siteStages
                || !at.pagesToShelve.isEmpty || !at.sitesToShelve.isEmpty
            #expect(changed)

            now = next
            verdict = at
            sites = apply(at, to: sites)
            if hops > 100 { Issue.record("nextCheck never settled"); break }
        }
        #expect(hops >= 8)
        // What is left can never change: the kept site and the visible site with its last page.
        #expect(sites.map(\.key.host) == ["music.example", "news.example"])
        #expect(sites[1].pages.count == 1)
    }

    @Test func nothingChangesBetweenChecksOnAFineGrid() {
        let w = window()
        let first = engine.evaluate(sites: w.sites, stats: w.stats, visible: w.visible, now: t0)
        let next = try! #require(first.nextCheck)
        var t = t0
        while t < next {
            let v = engine.evaluate(sites: w.sites, stats: w.stats, visible: w.visible, now: t)
            #expect(v == first)
            t = t.addingTimeInterval(61)
        }
    }
}

@Suite struct Hygiene {
    private func crowd() -> (sites: [Site], stats: [SiteKey: Usage]) {
        var sites: [Site] = []
        var stats: [SiteKey: Usage] = [:]
        for i in 0..<12 {
            let pages = (0...(i % 4)).map { j in
                page("p\(i)-\(j)", used: t0.addingTimeInterval(-Double((i * 7 + j * 11) % 40) * hour), visits: 1 + (i + j) % 6)
            }
            let s = site("site\(i).example", pages, kept: i == 5)
            sites.append(s)
            if i % 3 != 0 { stats[s.key] = usage(visits: 1 + i * 3, days: 1 + i % 5) }
        }
        return (sites, stats)
    }

    @Test func evaluatingTwiceGivesTheSameAnswer() {
        let c = crowd()
        for step in 0..<60 {
            let now = t0.addingTimeInterval(Double(step) * 2.5 * hour)
            let a = engine.evaluate(sites: c.sites, stats: c.stats, visible: [], now: now)
            let b = engine.evaluate(sites: c.sites, stats: c.stats, visible: [], now: now)
            #expect(a == b)
        }
    }

    @Test func applyingTheVerdictLeavesNothingMoreToShelve() {
        let c = crowd()
        for step in 0..<80 {
            let now = t0.addingTimeInterval(Double(step) * 1.7 * hour)
            let first = engine.evaluate(sites: c.sites, stats: c.stats, visible: [], now: now)
            let after = apply(first, to: c.sites)
            let second = engine.evaluate(sites: after, stats: c.stats, visible: [], now: now)
            #expect(second.pagesToShelve.isEmpty)
            #expect(second.sitesToShelve.isEmpty)
            #expect(second.pageStages == first.pageStages)
            #expect(second.siteStages == first.siteStages)
            #expect(second.nextCheck == first.nextCheck)
        }
    }

    @Test func everyItemIsEitherStagedOrShelvedExactlyOnce() {
        let c = crowd()
        for step in 0..<80 {
            let now = t0.addingTimeInterval(Double(step) * 1.3 * hour)
            let v = engine.evaluate(sites: c.sites, stats: c.stats, visible: [], now: now)
            #expect(Set(v.sitesToShelve).count == v.sitesToShelve.count)
            #expect(Set(v.pagesToShelve).count == v.pagesToShelve.count)
            for s in c.sites {
                let shelved = v.sitesToShelve.contains(s.id)
                #expect(shelved != (v.siteStages[s.id] != nil))
                var staying = 0
                for p in s.pages {
                    let alone = v.pagesToShelve.contains(p.id)
                    let staged = v.pageStages[p.id] != nil
                    if shelved {
                        #expect(!alone && !staged)
                    } else {
                        #expect(alone != staged)
                    }
                    if staged { staying += 1 }
                }
                // A site that stays always keeps at least one page.
                if !shelved { #expect(staying >= 1) }
                if s.isKept { #expect(!shelved && staying == s.pages.count) }
            }
        }
    }

    @Test func dashedSiteHasOnlyDashedPages() {
        let c = crowd()
        for step in 0..<80 {
            let v = engine.evaluate(sites: c.sites, stats: c.stats, visible: [], now: t0.addingTimeInterval(Double(step) * hour))
            for s in c.sites where v.siteStages[s.id] == .fading {
                for p in s.pages { #expect(v.pageStages[p.id] != .live) }
            }
        }
    }

    @Test func verdictDoesNotDependOnStoredFadeFlags() {
        let c = crowd()
        var flagged = c.sites
        for i in flagged.indices {
            flagged[i].fade = .fading
            for j in flagged[i].pages.indices { flagged[i].pages[j].fade = .fading }
        }
        let now = t0.addingTimeInterval(6 * hour)
        #expect(engine.evaluate(sites: c.sites, stats: c.stats, visible: [], now: now)
            == engine.evaluate(sites: flagged, stats: c.stats, visible: [], now: now))
    }
}

@Suite struct Monotonicity {
    private func rank(_ verdict: FadeVerdict, _ s: Site) -> Int {
        if verdict.sitesToShelve.contains(s.id) { return 2 }
        return verdict.siteStages[s.id] == .fading ? 1 : 0
    }

    @Test func moreActiveDaysNeverFadesASiteSooner() {
        let s = site([page()])
        for step in 0..<120 {
            let now = t0.addingTimeInterval(Double(step) * 3 * hour)
            var previous = Int.max
            for days in 1...12 {
                let r = rank(engine.evaluate(sites: [s], stats: [s.key: usage(visits: 4, days: days)], visible: [], now: now), s)
                #expect(r <= previous)
                previous = r
            }
        }
    }

    @Test func moreVisitsNeverFadesASiteSooner() {
        let s = site([page()])
        for step in 0..<120 {
            let now = t0.addingTimeInterval(Double(step) * 3 * hour)
            var previous = Int.max
            for visits in [1, 2, 3, 5, 8, 13, 21, 100] {
                let r = rank(engine.evaluate(sites: [s], stats: [s.key: usage(visits: visits, days: 2)], visible: [], now: now), s)
                #expect(r <= previous)
                previous = r
            }
        }
    }

    @Test func moreRecentUseNeverFadesASiteSooner() {
        let now = t0.addingTimeInterval(4 * day)
        var previous = Int.max
        for hoursAgo in stride(from: 96.0, through: 0, by: -2) {
            let s = site([page(used: now.addingTimeInterval(-hoursAgo * hour))])
            let r = rank(engine.evaluate(sites: [s], stats: [s.key: usage(visits: 3, days: 2)], visible: [], now: now), s)
            #expect(r <= previous)
            previous = r
        }
    }

    /// Compared one axis at a time: more days at the same visits, more visits at the same days.
    @Test func moreUseNeverMovesTheOutlookEarlier() throws {
        let s = site([page()])
        let floor = try #require(engine.outlook(for: s, stats: nil, now: t0))
        let visitSteps = [1, 2, 3, 6, 12, 40, 500]
        for visits in visitSteps {
            var previous = floor
            for days in 1...20 {
                let o = try #require(engine.outlook(for: s, stats: usage(visits: visits, days: days), now: t0))
                #expect(o.fadesAt >= previous.fadesAt)
                #expect(o.shelvesAt >= previous.shelvesAt)
                #expect(o.fadesAt < o.shelvesAt)
                previous = o
            }
        }
        for days in 1...20 {
            var previous = floor
            for visits in visitSteps {
                let o = try #require(engine.outlook(for: s, stats: usage(visits: visits, days: days), now: t0))
                #expect(o.fadesAt >= previous.fadesAt)
                #expect(o.shelvesAt >= previous.shelvesAt)
                previous = o
            }
        }
    }

    @Test func moreVisitsNeverShelvesAPageSooner() {
        let fresh = page("fresh", used: t0.addingTimeInterval(30 * hour))
        for step in 0..<60 {
            let now = t0.addingTimeInterval(Double(step) * 0.5 * hour)
            var previous = Int.max
            for visits in [1, 2, 4, 9, 16, 200] {
                let p = page("p", used: t0, visits: visits)
                let s = site([p, fresh])
                let v = engine.evaluate(sites: [s], stats: [s.key: usage(visits: 99, days: 30)], visible: [], now: now)
                let r = v.pagesToShelve.contains(p.id) ? 2 : (v.pageStages[p.id] == .fading ? 1 : 0)
                #expect(r <= previous)
                previous = r
            }
        }
    }
}

@Suite struct Outlook {
    @Test func outlookMatchesWhatEvaluateDoes() throws {
        let s = site([page("a", used: t0.addingTimeInterval(-3 * hour)), page("b", used: t0)])
        let stats = usage(visits: 6, days: 2)
        let o = try #require(engine.outlook(for: s, stats: stats, now: t0))
        func stage(_ at: Date) -> FadeStage? {
            // Only the latest page, so the page clock stays out of it.
            let alone = Site(id: s.id, key: s.key, name: s.name, pages: [s.pages[1]])
            return engine.evaluate(sites: [alone], stats: [s.key: stats], visible: [], now: at).siteStages[s.id]
        }
        #expect(stage(o.fadesAt.addingTimeInterval(-1)) == .live)
        #expect(stage(o.fadesAt) == .fading)
        #expect(stage(o.shelvesAt.addingTimeInterval(-1)) == .fading)
        #expect(stage(o.shelvesAt) == nil)
    }

    @Test func outlookForAOneOff() throws {
        let o = try #require(engine.outlook(for: site([page()]), stats: usage(), now: t0))
        #expect(o.fadesAt == t0.addingTimeInterval(15 * hour))
        #expect(o.shelvesAt == t0.addingTimeInterval(20 * hour))
    }

    @Test func pageOutlookAppliesOnlyToPagesOnThePageClock() throws {
        let stale = page("stale", used: t0)
        let fresh = page("fresh", used: t0.addingTimeInterval(hour))
        let s = site([stale, fresh])
        let o = try #require(engine.pageOutlook(for: stale.id, in: s))
        #expect(o.fadesAt == t0.addingTimeInterval(9 * hour))
        #expect(o.shelvesAt == t0.addingTimeInterval(12 * hour))
        #expect(engine.pageOutlook(for: fresh.id, in: s) == nil)
        #expect(engine.pageOutlook(for: PageID(), in: s) == nil)
        #expect(engine.pageOutlook(for: stale.id, in: site([stale])) == nil)
    }
}


@Suite struct ScaledPolicy {
    private func evaluate(_ policy: FadePolicy, age: TimeInterval) -> FadeVerdict {
        let s = site([page(used: t0)])
        return FadeEngine(policy: policy).evaluate(sites: [s], stats: [s.key: usage(last: t0)], visible: [],
                                                   now: t0.addingTimeInterval(age))
    }

    @Test func standardScaleChangesNothing() {
        #expect(FadePolicy.standard.scaled(by: 1) == .standard)
        #expect(FadePolicy.standard.scaled(by: 1).siteLifetime(for: usage()) == 20 * hour)
    }

    @Test func scalesEveryLifetime() {
        let half = FadePolicy.standard.scaled(by: 0.5)
        #expect(half.siteBaseLifetime == 10 * hour)
        #expect(half.siteLifetimePerExtraDay == 15 * hour)
        #expect(half.siteMaxLifetime == 7 * day)
        #expect(half.pageBaseLifetime == 6 * hour)
        #expect(half.pageMaxLifetime == 12 * hour)
        #expect(FadePolicy.standard.scaled(by: 2).siteLifetime(for: usage()) == 40 * hour)
        #expect(!half.neverFades)
    }

    @Test func shorterFadesSoonerAndLongerLater() {
        #expect(evaluate(.standard, age: 12 * hour).sitesToShelve.isEmpty)
        #expect(evaluate(FadePolicy.standard.scaled(by: 0.5), age: 12 * hour).sitesToShelve.count == 1)
        #expect(evaluate(.standard, age: 25 * hour).sitesToShelve.count == 1)
        #expect(evaluate(FadePolicy.standard.scaled(by: 2), age: 25 * hour).sitesToShelve.isEmpty)
    }

    @Test func neverKeepsAHundredDayOldPage() {
        let never = FadePolicy.standard.scaled(by: .infinity)
        #expect(never.neverFades)
        let verdict = evaluate(never, age: 100 * day)
        #expect(verdict.sitesToShelve.isEmpty && verdict.pagesToShelve.isEmpty)
        #expect(verdict.nextCheck == nil)
        #expect(verdict.siteStages.values.allSatisfy { $0 == .live })
        let s = site([page(used: t0)])
        #expect(FadeEngine(policy: never).outlook(for: s, stats: nil, now: t0) == nil)
    }

    @Test func neverAlsoKeepsExtraPagesInASite() {
        let a = page("a", used: t0), b = page("b", used: t0.addingTimeInterval(1))
        let s = site([a, b])
        let verdict = FadeEngine(policy: FadePolicy.standard.scaled(by: .infinity))
            .evaluate(sites: [s], stats: [:], visible: [], now: t0.addingTimeInterval(100 * day))
        #expect(verdict.pagesToShelve.isEmpty && verdict.sitesToShelve.isEmpty)
    }

    @Test func nonsenseFactorsStayFinite() {
        #expect(FadePolicy.standard.scaled(by: .nan) == .standard)
        #expect(FadePolicy.standard.scaled(by: 0).siteBaseLifetime > 0)
        #expect(FadePolicy.standard.scaled(by: -3).siteBaseLifetime > 0)
        #expect(FadePolicy.standard.scaled(by: 0).siteLifetime(for: usage()).isFinite)
    }
}
