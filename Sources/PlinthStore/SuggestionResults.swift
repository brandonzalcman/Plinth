import Foundation
import PlinthModel

extension BrowserStore {
    static let picksCap = 1_500

    /// What the command bar lists while typing: a bounded, grouped list (top hit, then open,
    /// pinned and shelved pages, then history), ranked by frecency and past choices, with one row
    /// per page and at most two history rows per site. See `SuggestionRanker`.
    public func suggestions(for query: String, limit: Int = 7) -> [SearchResult] {
        let tokens = Self.fold(query).split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !tokens.isEmpty, limit > 0 else { return [] }
        lastSuggestionQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        suggestionIndex.update(with: history)

        var candidates = suggestionIndex.candidates(matching: tokens)
        candidates += suggestionIndex.candidates(typedBefore: picks, query: tokens.joined(separator: " "))
        candidates += livePageCandidates(tokens: tokens)
        return SuggestionRanker.rank(tokens: tokens, rawQuery: query, candidates: candidates,
                                     picks: picks, now: now(), limit: limit)
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
