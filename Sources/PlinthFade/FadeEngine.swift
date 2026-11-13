import Foundation
import PlinthModel

/// Decides what on one window's bar is drawn dashed and what drops onto the shelf.
///
/// Two clocks run at different speeds (constants and formula: see `FadePolicy`):
///
/// - The **page clock**. In a site with two or more pages, each page except the most
///   recently used one goes dashed and is then shelved on its own, a fixed-ish time after
///   that page was last used. The most recently used page is the site's last page and is
///   never shelved by this clock.
/// - The **site clock**. The whole site, with whatever pages remain, goes dashed and is then
///   shelved as a unit, an adaptive time after any of its pages was last used.
///
/// Never faded: kept sites and their pages; visible pages and the sites that hold them
/// (other pages of a visible site still run their page clocks).
///
/// Stages reported: a site's stage is its site clock. A page is `.fading` when its own page
/// clock says so or when its site is `.fading`, so a dashed site has only dashed pages and
/// a single-page site's page always matches the site.
///
/// Pure: the verdict depends only on the arguments.
public struct FadeEngine: FadeEvaluating {
    public let policy: FadePolicy

    public init(policy: FadePolicy = .standard) {
        self.policy = policy
    }

    // MARK: Tooltip helpers

    /// When the site as a whole goes dashed and when it is shelved, if nothing in it is used
    /// before then. Either date may already be in the past relative to `now` (the site is then
    /// due on the next pass). Returns nil for a kept site, which never fades. A site that holds
    /// a visible page does not fade while it stays visible; that is the caller's to know.
    public func outlook(for site: Site, stats: Usage?, now: Date = Date()) -> (fadesAt: Date, shelvesAt: Date)? {
        guard !site.isKept, !policy.neverFades else { return nil }
        let span = siteSpan(site, stats: stats)
        return (span.fadesAt, span.shelvesAt)
    }

    /// When one page goes dashed and is shelved on the page clock. Returns nil when the page
    /// clock does not apply: the site is kept, has a single page, does not hold the page, or
    /// the page is the site's most recently used one (see `outlook(for:stats:now:)` for that).
    public func pageOutlook(for page: PageID, in site: Site) -> (fadesAt: Date, shelvesAt: Date)? {
        guard !site.isKept, !policy.neverFades, site.pages.count >= 2, page != anchor(of: site),
              let p = site.pages.first(where: { $0.id == page }) else { return nil }
        let span = pageSpan(p)
        return (span.fadesAt, span.shelvesAt)
    }

    /// The site's most recently used page: the one the page clock never shelves.
    /// Ties go to the site's current page, then to the leftmost.
    public func lastPage(of site: Site) -> PageID { anchor(of: site) }

    // MARK: Evaluation

    public func evaluate(sites: [Site], stats: [SiteKey: Usage], visible: Set<PageID>, now: Date) -> FadeVerdict {
        let pass = run(sites: sites, stats: stats, visible: visible, now: now)
        var verdict = FadeVerdict(pageStages: pass.pageStages, siteStages: pass.siteStages,
                                  pagesToShelve: pass.pagesToShelve, sitesToShelve: pass.sitesToShelve)

        // What stays once this verdict is applied; the next change is measured against that.
        let goneSites = Set(pass.sitesToShelve), gonePages = Set(pass.pagesToShelve)
        let remaining: [Site] = sites.compactMap { site in
            guard !goneSites.contains(site.id) else { return nil }
            var kept = site
            kept.pages.removeAll { gonePages.contains($0.id) }
            return kept.pages.isEmpty ? nil : kept
        }
        let settled = run(sites: remaining, stats: stats, visible: visible, now: now)
        for instant in Set(settled.instants).filter({ $0 > now }).sorted() {
            if run(sites: remaining, stats: stats, visible: visible, now: instant).outcome != settled.outcome {
                verdict.nextCheck = instant
                break
            }
        }
        return verdict
    }

    // MARK: Internals

    private struct Span {
        var fadesAt: Date
        var shelvesAt: Date

        /// nil once the lifetime is over.
        func stage(at now: Date) -> FadeStage? {
            if now >= shelvesAt { return nil }
            return now >= fadesAt ? .fading : .live
        }
    }

    private struct Outcome: Equatable {
        var pageStages: [PageID: FadeStage] = [:]
        var siteStages: [SiteID: FadeStage] = [:]
        var pagesToShelve: [PageID] = []
        var sitesToShelve: [SiteID] = []
    }

    private struct Pass {
        var outcome = Outcome()
        /// Every instant at which some clock in this pass steps.
        var instants: [Date] = []

        var pageStages: [PageID: FadeStage] { outcome.pageStages }
        var siteStages: [SiteID: FadeStage] { outcome.siteStages }
        var pagesToShelve: [PageID] { outcome.pagesToShelve }
        var sitesToShelve: [SiteID] { outcome.sitesToShelve }
    }

    private func span(lastUsed: Date, lifetime: TimeInterval) -> Span {
        let dashed = policy.fadingDuration(forLifetime: lifetime)
        return Span(fadesAt: lastUsed.addingTimeInterval(lifetime - dashed),
                    shelvesAt: lastUsed.addingTimeInterval(lifetime))
    }

    private func siteSpan(_ site: Site, stats: Usage?) -> Span {
        span(lastUsed: site.lastUsed, lifetime: policy.siteLifetime(for: stats))
    }

    private func pageSpan(_ page: Page) -> Span {
        span(lastUsed: page.usage.lastUsed, lifetime: policy.pageLifetime(for: page.usage))
    }

    private func anchor(of site: Site) -> PageID {
        let latest = site.lastUsed
        let tied = site.pages.filter { $0.usage.lastUsed == latest }
        if tied.contains(where: { $0.id == site.currentPageID }) { return site.currentPageID }
        return (tied.first ?? site.pages[0]).id
    }

    private func run(sites: [Site], stats: [SiteKey: Usage], visible: Set<PageID>, now: Date) -> Pass {
        var pass = Pass()
        for site in sites {
            if site.isKept || policy.neverFades {
                pass.outcome.siteStages[site.id] = .live
                for page in site.pages { pass.outcome.pageStages[page.id] = .live }
                continue
            }

            let siteStage: FadeStage
            if site.pages.contains(where: { visible.contains($0.id) }) {
                siteStage = .live
            } else {
                let clock = siteSpan(site, stats: stats[site.key])
                pass.instants.append(clock.fadesAt)
                pass.instants.append(clock.shelvesAt)
                guard let stage = clock.stage(at: now) else {
                    pass.outcome.sitesToShelve.append(site.id)
                    continue
                }
                siteStage = stage
            }
            pass.outcome.siteStages[site.id] = siteStage

            let last = anchor(of: site)
            for page in site.pages {
                if visible.contains(page.id) {
                    pass.outcome.pageStages[page.id] = .live
                } else if page.id == last || site.pages.count < 2 {
                    pass.outcome.pageStages[page.id] = siteStage
                } else {
                    let clock = pageSpan(page)
                    pass.instants.append(clock.fadesAt)
                    pass.instants.append(clock.shelvesAt)
                    if let stage = clock.stage(at: now) {
                        pass.outcome.pageStages[page.id] = siteStage == .fading ? .fading : stage
                    } else {
                        pass.outcome.pagesToShelve.append(page.id)
                    }
                }
            }
        }
        return pass
    }
}
