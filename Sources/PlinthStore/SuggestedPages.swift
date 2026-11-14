import Foundation
import PlinthModel

// What the command bar offers before anything is typed: the pages the user (on any device whose
// history has synced in) goes back to most. Shared by every platform. The Plinth site itself is never
// listed here: it is suggested when typed, and opens as the first page of a new profile.

extension SuggestionIndex {
    /// The best pages by frecency, one row per canonical page, at most `hostCap` per site.
    /// `excluding` holds `URLCanonical.key`s to skip (open, pinned or shelved pages).
    func topPages(limit: Int, hostCap: Int = SuggestionRanker.hostCapHistory, excluding: Set<String>, now: Date) -> [SearchResult] {
        guard limit > 0 else { return [] }
        let scored = aggregates.values.compactMap { a -> (SuggestionAggregate, Double)? in
            guard !excluding.contains(a.canon), !PlinthPromo.isPlinthHost(a.host), !SuggestionRanker.isDownload(a.foldedURL) else { return nil }
            let score = FrecencyScorer.score(samples: a.samples.sorted(by: >).prefix(FrecencyScorer.sampleCount).map { $0 },
                                             visits: a.visits, dwell: a.dwell, now: now)
            return score > 0 ? (a, score) : nil
        }.sorted { x, y in
            if x.1 != y.1 { return x.1 > y.1 }
            if x.0.lastVisit != y.0.lastVisit { return x.0.lastVisit > y.0.lastVisit }
            return x.0.canon < y.0.canon
        }
        var perHost: [String: Int] = [:]
        var out: [SearchResult] = []
        for (a, _) in scored where out.count < limit {
            guard perHost[a.host, default: 0] < hostCap else { continue }
            perHost[a.host, default: 0] += 1
            let url = URLCanonical.stripTracking(a.url)
            let title = a.name.isEmpty ? (a.title.isEmpty ? URLCanonical.display(a.url) : a.title) : a.name
            out.append(SearchResult(id: "history-" + a.canon, target: .history(url), title: title,
                                    subtitle: URLCanonical.display(url), key: a.key))
        }
        return out
    }
}

extension BrowserStore {
    /// How many suggested pages the empty command bar lists.
    public static let suggestedPagesDefault = 4

    /// With nothing typed: the most visited and most recent pages from the history (which holds
    /// the visits other devices synced in), best first. Pages that are already open, pinned or
    /// shelved are left out, since the bar lists those anyway. Empty in a private window: pass `isPrivate`.
    public func suggestedPages(limit: Int = BrowserStore.suggestedPagesDefault, isPrivate: Bool = false) -> [SearchResult] {
        guard !isPrivate, limit > 0 else { return [] }
        suggestionIndex.update(with: history)
        var skip = Set<String>()
        for window in windows where !window.isPrivate {
            for site in window.sites { for page in site.pages { skip.insert(URLCanonical.key(page.url)) } }
        }
        for pin in pins { skip.insert(URLCanonical.key(pin.page.url)); skip.insert(URLCanonical.key(pin.homeURL)) }
        for entry in shelf { for page in entry.pages { skip.insert(URLCanonical.key(page.url)) } }
        return suggestionIndex.topPages(limit: limit, excluding: skip, now: now())
    }
}
