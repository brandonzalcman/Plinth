import Foundation
import PlinthModel

extension BrowserStore {
    /// Keyword search. Every word of the query must appear somewhere in an item's name, title,
    /// URL or site name. Results come in four bands (open pages, pins, shelf, history); inside a
    /// band the better match wins, then the more recently used.
    public func search(_ query: String, limit: Int = 20) -> [SearchResult] {
        let tokens = query.split(whereSeparator: { $0.isWhitespace }).map { Self.fold(String($0)) }
        guard !tokens.isEmpty, limit > 0 else { return [] }

        struct Hit { var result: SearchResult; var score: Int; var recency: Date; var url: URL }
        func ranked(_ hits: [Hit]) -> [Hit] {
            // Stable for equal score and recency: keeps bar order.
            hits.enumerated().sorted { a, b in
                if a.element.score != b.element.score { return a.element.score > b.element.score }
                if a.element.recency != b.element.recency { return a.element.recency > b.element.recency }
                return a.offset < b.offset
            }.map(\.element)
        }

        var open: [Hit] = []
        // Private pages are never offered, not even to the private window itself.
        for window in windows where !window.isPrivate {
            for site in window.sites {
                for page in site.pages {
                    guard let score = Self.score(tokens, name: page.name, title: page.rawTitle, url: page.url, site: site.name) else { continue }
                    open.append(Hit(result: SearchResult(id: "page-\(page.id.raw.uuidString)",
                                                         target: .openPage(page.id, window: window.id),
                                                         title: page.name, subtitle: Self.displayURL(page.url), key: site.key),
                                    score: score, recency: page.usage.lastUsed, url: page.url))
                }
            }
        }

        var pinned: [Hit] = []
        for pin in pins {
            guard let score = Self.score(tokens, name: pin.page.name, title: pin.page.rawTitle, url: pin.page.url, site: pin.name) else { continue }
            pinned.append(Hit(result: SearchResult(id: "pin-\(pin.id.raw.uuidString)", target: .pin(pin.id),
                                                   title: pin.name, subtitle: Self.displayURL(pin.page.url), key: pin.key),
                              score: score, recency: pin.page.usage.lastUsed, url: pin.page.url))
        }

        var shelved: [Hit] = []
        for entry in shelf {
            for page in entry.pages {
                guard let score = Self.score(tokens, name: page.name, title: page.rawTitle, url: page.url, site: entry.name) else { continue }
                shelved.append(Hit(result: SearchResult(id: "shelf-\(page.id.raw.uuidString)",
                                                        target: .shelf(entry: entry.id, page: page.id),
                                                        title: page.name, subtitle: Self.displayURL(page.url), key: entry.key),
                                   score: score, recency: page.usage.lastUsed, url: page.url))
            }
        }

        var results = ranked(open) + ranked(pinned) + ranked(shelved)
        if results.count >= limit { return results.prefix(limit).map(\.result) }

        // History: one result per URL, and nothing that is already listed above.
        var seen = Set(results.map(\.url))
        var past: [Hit] = []
        for entry in history {
            guard !seen.contains(entry.url) else { continue }
            guard let score = Self.score(tokens, name: entry.name, title: entry.title, url: entry.url, site: entry.key.host) else { continue }
            seen.insert(entry.url) // history is newest first, so the newest visit represents the URL
            past.append(Hit(result: SearchResult(id: "history-\(entry.id.uuidString)", target: .history(entry.url),
                                                 title: entry.name.isEmpty ? (entry.title.isEmpty ? Self.displayURL(entry.url) : entry.title) : entry.name,
                                                 subtitle: Self.displayURL(entry.url), key: entry.key),
                            score: score, recency: entry.visitedAt, url: entry.url))
        }
        results += ranked(past)
        return results.prefix(limit).map(\.result)
    }

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// nil when some word matches nothing. Otherwise higher is better: a word found at the start
    /// of the name beats one inside the name, which beats the title, the site name, then the URL.
    static func score(_ tokens: [String], name: String, title: String, url: URL, site: String) -> Int? {
        let name = fold(name), title = fold(title), site = fold(site), url = fold(url.absoluteString)
        var total = 0
        for token in tokens {
            if name.hasPrefix(token) { total += 6 }
            else if name.contains(" " + token) { total += 5 }
            else if name.contains(token) { total += 4 }
            else if title.contains(token) { total += 3 }
            else if site.contains(token) { total += 2 }
            else if url.contains(token) { total += 1 }
            else { return nil }
        }
        return total
    }

    /// "https://www.example.com/a/b/?q=1" -> "example.com/a/b".
    public static func displayURL(_ url: URL) -> String {
        guard var host = url.host, !host.isEmpty else { return url.absoluteString }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        var path = url.path
        while path.hasSuffix("/") { path.removeLast() }
        return host + path
    }
}
