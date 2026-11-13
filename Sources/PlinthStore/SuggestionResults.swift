import Foundation
import PlinthModel

extension BrowserStore {
    static let picksCap = 1_500

    /// What the command bar lists while typing: a bounded, grouped list (top hit, then open,
    /// pinned and shelved pages, then history), ranked by frecency and past choices, with one row
    /// per page and at most two history rows per site. See `SuggestionRanker`.
    public func suggestions(for query: String, limit: Int = 7) -> [SearchResult] {
        let tokens = Self.fold(query).split(whereSeparator: { $0.isWhitespace }).map(String.init)
        lastSuggestionQuery = tokens.isEmpty ? "" : query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tokens.isEmpty, limit > 0 else { return [] }
        suggestionIndex.update(with: history)

        var candidates = suggestionIndex.candidates(matching: tokens)
        candidates += suggestionIndex.candidates(typedBefore: picks, query: tokens.joined(separator: " "))
        candidates += livePageCandidates(tokens: tokens)
        var ranked = SuggestionRanker.rank(tokens: tokens, rawQuery: query, candidates: candidates,
                                           picks: picks, now: now(), limit: limit)
        // A page the user reached before by typing exactly this stays the top hit.
        var habit = false
        if let first = ranked.first, first.isTopHit, case .history(let url) = first.target,
           let record = picks[URLCanonical.key(url)], SuggestionRanker.inputMatches(record, query: tokens.joined(separator: " ")) { habit = true }
        if !habit, let home = siteHomeHit(tokens: tokens, rawQuery: query, candidates: candidates) {
            // "github" leads with github.com itself, not a deep link that happens to be in the history.
            ranked.removeAll { $0.id == home.id || $0.target == home.target }
            for i in ranked.indices { ranked[i].isTopHit = false }
            ranked.insert(home, at: 0)
            if ranked.count > limit { ranked.removeLast(ranked.count - limit) }
        }
        return ranked
    }

    /// The front page of the site a single plain word names: a well-known site, or a host the user
    /// has visited a lot. nil for addresses, paths and several words.
    private func siteHomeHit(tokens: [String], rawQuery: String, candidates: [SuggestionCandidate]) -> SearchResult? {
        guard tokens.count == 1, let token = tokens.first, token.count >= 2,
              !rawQuery.contains("."), !rawQuery.contains("/"), !rawQuery.contains(":") else { return nil }
        // The host the user visits most among those whose name starts with the word.
        var visits: [String: Int] = [:]
        var roots: [String: SearchResult] = [:]
        for c in candidates where c.kind == .history && !c.host.isEmpty {
            guard let label = c.host.split(separator: ".").first, label.hasPrefix(token) || c.host.hasPrefix(token) else { continue }
            visits[c.host, default: 0] += c.visits
            if c.isRoot { roots[c.host] = c.result }
        }
        let favourite = visits.max { $0.value < $1.value }
        let popular = PopularSites.matches(token).first

        if let popular {
            let popularHost = popular.domain.hasPrefix("www.") ? String(popular.domain.dropFirst(4)) : popular.domain
            // A host the user really uses beats the table, unless it is the same site.
            if let favourite, favourite.key != popularHost, favourite.value >= 5 {
                return hostResult(favourite.key, root: roots[favourite.key])
            }
            return PopularSites.result(for: popular)
        }
        if let favourite { return hostResult(favourite.key, root: roots[favourite.key]) }
        return nil
    }

    private func hostResult(_ host: String, root: SearchResult?) -> SearchResult {
        var result = root ?? {
            let url = URL(string: "https://\(host)/")!
            let label = host.split(separator: ".").first.map(String.init) ?? host
            return SearchResult(id: "site-" + host, target: .history(url), title: label.prefix(1).uppercased() + label.dropFirst(),
                                subtitle: host, key: SiteKey(host))
        }()
        result.isTopHit = true
        return result
    }

    /// Remembers that the user chose `url` from the command bar (or typed it), so it ranks higher
    /// next time. `input` is what was typed; nil uses the last query the suggestions were built for.
    public func recordSuggestionPick(url: URL, input: String? = nil) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return }
        let canon = URLCanonical.key(url)
        let typed = input ?? lastSuggestionQuery
        var record = picks[canon] ?? PickRecord(count: 0, last: now(), inputs: [])
        record.record(input: typed, at: now())
        picks[canon] = record
        lastSuggestionQuery = ""
        if picks.count > Self.picksCap {
            // Drop the least recently picked.
            let drop = picks.sorted { $0.value.last < $1.value.last }.prefix(picks.count - Self.picksCap).map(\.key)
            for key in drop { picks[key] = nil }
        }
        scheduleAutosave()
    }

    /// Records the pick behind a suggestion row, whatever it points at.
    public func recordSuggestionPick(_ result: SearchResult) {
        switch result.target {
        case .openPage(let id, _):
            if let page = page(id) { recordSuggestionPick(url: page.url) }
        case .pin(let id):
            if let pin = pins.first(where: { $0.id == id }) { recordSuggestionPick(url: pin.page.url) }
        case .shelf(_, let page):
            if let found = findShelved(page) { recordSuggestionPick(url: shelf[found.e].pages[found.p].url) }
        case .history(let url):
            recordSuggestionPick(url: url)
        }
    }

    /// Open pages, pins and shelved pages that match every word.
    private func livePageCandidates(tokens: [String]) -> [SuggestionCandidate] {
        var out: [SuggestionCandidate] = []
        func make(_ kind: SuggestionCandidate.Kind, page: Page, siteName: String, key: SiteKey, id: String, target: SearchResult.Target, title: String) {
            let canon = URLCanonical.key(page.url)
            let name = Self.fold(page.name + " " + (page.customName ?? "") + " " + siteName)
            let pageTitle = Self.fold(page.rawTitle)
            let url = Self.fold(canon)
            guard tokens.allSatisfy({ name.contains($0) || pageTitle.contains($0) || url.contains($0) }) else { return }
            out.append(SuggestionCandidate(
                kind: kind, canon: canon, host: URLCanonical.host(page.url), name: name, title: pageTitle, url: url,
                isRoot: URLCanonical.isRoot(canon), visits: max(page.usage.visitCount, 1), lastUsed: page.usage.lastUsed,
                samples: [page.usage.lastUsed], dwell: page.dwell,
                result: SearchResult(id: id, target: target, title: title, subtitle: Self.displayURL(page.url), key: key)))
        }
        for window in windows {
            for site in window.sites {
                for page in site.pages {
                    make(.open, page: page, siteName: site.name, key: site.key, id: "page-\(page.id.raw.uuidString)",
                         target: .openPage(page.id, window: window.id), title: page.name)
                }
            }
        }
        for pin in pins {
            make(.pin, page: pin.page, siteName: pin.name, key: pin.key, id: "pin-\(pin.id.raw.uuidString)",
                 target: .pin(pin.id), title: pin.name)
        }
        for entry in shelf {
            for page in entry.pages {
                make(.shelf, page: page, siteName: entry.name, key: entry.key, id: "shelf-\(page.id.raw.uuidString)",
                     target: .shelf(entry: entry.id, page: page.id), title: page.name)
            }
        }
        return out
    }
}
