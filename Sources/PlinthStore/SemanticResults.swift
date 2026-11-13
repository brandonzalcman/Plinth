import Foundation
import PlinthModel

extension BrowserStore {
    /// Turns semantic-history hits into search results, all marked `byMeaning`. Each URL goes to
    /// the best place it can be found: an open page (first window, bar order), then a pin, then a
    /// shelved page, else history. Anything whose URL or target is already in `excluding` (the
    /// keyword results) is skipped, a URL appears once, and the order of `matches` is kept.
    /// URLs are compared exactly.
    public func semanticResults(_ matches: [SemanticMatch], excluding: [SearchResult], limit: Int = 20) -> [SearchResult] {
        guard limit > 0, !matches.isEmpty else { return [] }
        var seenURLs = Set<URL>()
        var seenTargets = Set<String>()
        for result in excluding {
            seenTargets.insert(Self.targetKey(result.target))
            if let url = url(of: result.target) { seenURLs.insert(url) }
        }

        var results: [SearchResult] = []
        for match in matches {
            guard results.count < limit else { break }
            guard seenURLs.insert(match.url).inserted else { continue }
            let result = bestResult(for: match)
            guard seenTargets.insert(Self.targetKey(result.target)).inserted else { continue }
            results.append(result)
        }
        return results
    }

    /// The history entry for the page's current visit: bar pages, pins and shelved pages, where known.
    public func latestHistoryEntry(for page: PageID) -> HistoryEntry? {
        guard let entryID = latestHistory[page] else { return nil }
        return history.first { $0.id == entryID }
    }

    private func bestResult(for match: SemanticMatch) -> SearchResult {
        for window in windows where !window.isPrivate {
            for site in window.sites {
                if let page = site.pages.first(where: { $0.url == match.url }) {
                    return SearchResult(id: "meaning-page-\(page.id.raw.uuidString)", target: .openPage(page.id, window: window.id),
                                        title: page.name, subtitle: Self.displayURL(page.url), key: site.key, byMeaning: true)
                }
            }
        }
        if let pin = pins.first(where: { $0.page.url == match.url }) {
            return SearchResult(id: "meaning-pin-\(pin.id.raw.uuidString)", target: .pin(pin.id),
                                title: pin.name, subtitle: Self.displayURL(pin.page.url), key: pin.key, byMeaning: true)
        }
        for entry in shelf {
            if let page = entry.pages.first(where: { $0.url == match.url }) {
                return SearchResult(id: "meaning-shelf-\(page.id.raw.uuidString)", target: .shelf(entry: entry.id, page: page.id),
                                    title: page.name, subtitle: Self.displayURL(page.url), key: entry.key, byMeaning: true)
            }
        }
        let past = history.first { $0.url == match.url }
        let title: String
        if let past, !past.name.isEmpty { title = past.name }
        else if !match.title.isEmpty { title = match.title }
        else if let past, !past.title.isEmpty { title = past.title }
        else { title = Self.displayURL(match.url) }
        return SearchResult(id: "meaning-history-\(match.url.absoluteString)", target: .history(match.url),
                            title: title, subtitle: Self.displayURL(match.url), key: past?.key ?? match.key, byMeaning: true)
    }

    /// The URL a result points at right now, when it still exists.
    public func url(of target: SearchResult.Target) -> URL? {
        switch target {
        case .openPage(let id, _):
            return findPage(id).map { windows[$0.w].sites[$0.s].pages[$0.p].url }
        case .pin(let id):
            return pins.first { $0.id == id }?.page.url
        case .shelf(_, let page):
            return findShelved(page).map { shelf[$0.e].pages[$0.p].url }
        case .history(let url):
            return url
        }
    }

    private static func targetKey(_ target: SearchResult.Target) -> String {
        switch target {
        case .openPage(let id, _): return "page-\(id.raw.uuidString)"
        case .pin(let id): return "pin-\(id.raw.uuidString)"
        case .shelf(_, let page): return "shelf-\(page.raw.uuidString)"
        case .history(let url): return "history-\(url.absoluteString)"
        }
    }
}
