import Foundation
import PlinthModel

// Address-bar suggestions. Everything here is pure (no store, no UI) so it can be tested with
// large synthetic histories:
//
//   HistoryEntry (one per visit)  --SuggestionIndex-->  one Aggregate per canonical page
//   Aggregate / open page / pin / shelved page          --SuggestionRanker-->  a short, grouped list
//
// Ranking uses "frecency" (how often and how recently a page was visited), what the user chose
// from earlier suggestions, and how well the typed text matches the host, title and address.

/// What the user picked for a page from the command bar: how often, when, and what they had typed.
struct PickRecord: Codable, Sendable, Equatable {
    var count: Int
    var last: Date
    /// Lowercased inputs that led here, newest first (a few are kept).
    var inputs: [String]

    static let maxInputs = 5

    mutating func record(input: String, at date: Date) {
        count += 1
        last = date
        let text = input.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputs.removeAll { $0 == text }
        inputs.insert(text, at: 0)
        if inputs.count > Self.maxInputs { inputs.removeLast(inputs.count - Self.maxInputs) }
    }
}

/// One page as the suggestions see it, whatever kind it is.
struct SuggestionCandidate: Sendable {
    enum Kind: Int, Sendable { case open = 0, pin, shelf, history }

    var kind: Kind
    /// `URLCanonical.key` of the address; two candidates with the same one are the same page.
    var canon: String
    /// Host without "www.".
    var host: String
    /// Folded (lowercase, no diacritics) text to match against.
    var name: String
    var title: String
    var url: String
    var isRoot: Bool
    var visits: Int
    var lastUsed: Date
    /// Up to the ten newest visit dates, for frecency. Empty for pages that are only open.
    var samples: [Date]
    var dwell: TimeInterval
    var result: SearchResult
}

/// Visits of one canonical page, built from the history list.
struct SuggestionAggregate: Sendable {
    var canon: String
    var url: URL
    var title: String
    var name: String
    var key: SiteKey
    var host: String
    var visits: Int
    var lastVisit: Date
    /// Newest first, at most `FrecencyScorer.sampleCount`.
    var samples: [Date]
    var dwell: TimeInterval
    /// Folded copies for matching.
    var foldedName: String
    var foldedTitle: String
    var foldedURL: String
}

/// How much a page's visits are worth: recent visits count most, and many visits count more than
/// few, with diminishing returns.
enum FrecencyScorer {
    static let sampleCount = 10

    /// Weight of one visit by age, in the Firefox style: buckets, not a smooth curve.
    static func weight(age: TimeInterval) -> Double {
        let days = age / 86_400
        switch days {
        case ..<4: return 100
        case ..<14: return 70
        case ..<31: return 50
        case ..<90: return 30
        default: return 10
        }
    }

    static func score(samples: [Date], visits: Int, dwell: TimeInterval, now: Date) -> Double {
        guard !samples.isEmpty, visits > 0 else { return 0 }
        let sum = samples.reduce(0.0) { $0 + weight(age: now.timeIntervalSince($1)) }
        // The samples are the newest few; scale up to the whole count (older visits are worth at least the bottom weight).
        let scaled = sum * Double(visits) / Double(samples.count)
        let engaged = 1 + min(dwell, 600) / 600 * 0.25
        return scaled * engaged
    }
}

/// The history, folded into one aggregate per canonical page. Updated incrementally as visits are
/// added at the front of the history list, rebuilt from scratch when anything else changed.
struct SuggestionIndex: Sendable {
    private(set) var aggregates: [String: SuggestionAggregate] = [:]
    private var firstID: UUID?
    private var ingested = 0

    init() {}

    init(history: [HistoryEntry]) {
        for entry in history.reversed() { ingest(entry) } // oldest first, so the newest ends up on top
        firstID = history.first?.id
        ingested = history.count
    }

    /// Brings the index in line with `history` (newest first). Cheap when only new visits arrived.
    mutating func update(with history: [HistoryEntry]) {
        guard let first = history.first else {
            if ingested != 0 { self = SuggestionIndex() }
            return
        }
        if first.id == firstID, history.count == ingested {
            // Same list; a title can still arrive late for the newest visit.
            refreshTitle(of: first)
            return
        }
        // Visits added in front stay incremental, also at the history cap where each new visit pushes the
        // oldest one off the end (the tail may only shrink). A merge that also added older entries from
        // another device makes the tail longer than what was ingested and needs a rebuild.
        if let known = firstID, let offset = history.firstIndex(where: { $0.id == known }), offset > 0, offset <= 500,
           history.count - offset <= ingested {
            for entry in history[..<offset].reversed() { ingest(entry) }
            firstID = first.id
            ingested = history.count
            return
        }
        self = SuggestionIndex(history: history)
    }

    private mutating func refreshTitle(of entry: HistoryEntry) {
        let canon = URLCanonical.key(entry.url)
        guard var aggregate = aggregates[canon], aggregate.lastVisit == entry.visitedAt,
              aggregate.title != entry.title || aggregate.name != entry.name else { return }
        aggregate.title = entry.title
        aggregate.name = entry.name
        aggregate.foldedTitle = URLCanonical.fold(entry.title)
        aggregate.foldedName = URLCanonical.fold(entry.name)
        aggregates[canon] = aggregate
    }

    /// Adds one visit. Visits must arrive oldest to newest for a rebuild, or newest-batch-last for an update.
    private mutating func ingest(_ entry: HistoryEntry) {
        let canon = URLCanonical.key(entry.url)
        if var existing = aggregates[canon] {
            existing.visits += 1
            existing.dwell += entry.dwell
            if entry.visitedAt >= existing.lastVisit {
                existing.lastVisit = entry.visitedAt
                existing.url = entry.url
                if !entry.title.isEmpty || !entry.name.isEmpty {
                    existing.title = entry.title
                    existing.name = entry.name
                    existing.foldedTitle = URLCanonical.fold(entry.title)
                    existing.foldedName = URLCanonical.fold(entry.name)
                }
                existing.key = entry.key
            }
            existing.samples.append(entry.visitedAt)
            if existing.samples.count > 24 { // keep a bounded, sorted set of the newest
                existing.samples.sort(by: >)
                existing.samples.removeLast(existing.samples.count - FrecencyScorer.sampleCount)
            }
            aggregates[canon] = existing
        } else {
            aggregates[canon] = SuggestionAggregate(
                canon: canon, url: entry.url, title: entry.title, name: entry.name, key: entry.key,
                host: URLCanonical.host(entry.url), visits: 1, lastVisit: entry.visitedAt, samples: [entry.visitedAt],
                dwell: entry.dwell, foldedName: URLCanonical.fold(entry.name), foldedTitle: URLCanonical.fold(entry.title),
                foldedURL: URLCanonical.fold(canon))
        }
    }

    /// Candidates for ranking: only aggregates that match every word, to keep the per-keystroke
    /// work small even for a large history.
    func candidates(matching tokens: [String]) -> [SuggestionCandidate] {
        var out: [SuggestionCandidate] = []
        for aggregate in aggregates.values {
            guard tokens.allSatisfy({ aggregate.foldedURL.contains($0) || aggregate.foldedName.contains($0) || aggregate.foldedTitle.contains($0) }) else { continue }
            out.append(candidate(for: aggregate))
        }
        return out
    }

    /// Pages the user reached before by typing something that starts like `query` (or is it),
    /// even when the text does not appear in the page ("ts" for a timesheet tool).
    func candidates(typedBefore picks: [String: PickRecord], query: String) -> [SuggestionCandidate] {
        var out: [SuggestionCandidate] = []
        for (canon, record) in picks where SuggestionRanker.inputMatches(record, query: query) {
            if let aggregate = aggregates[canon] { out.append(candidate(for: aggregate)) }
        }
        return out
    }

    private func candidate(for aggregate: SuggestionAggregate) -> SuggestionCandidate {
        let samples = aggregate.samples.sorted(by: >).prefix(FrecencyScorer.sampleCount)
        let title = aggregate.name.isEmpty ? (aggregate.title.isEmpty ? URLCanonical.display(aggregate.url) : aggregate.title) : aggregate.name
        let url = URLCanonical.stripTracking(aggregate.url)
        return SuggestionCandidate(
            kind: .history, canon: aggregate.canon, host: aggregate.host,
            name: aggregate.foldedName, title: aggregate.foldedTitle, url: aggregate.foldedURL,
            isRoot: URLCanonical.isRoot(aggregate.canon), visits: aggregate.visits, lastUsed: aggregate.lastVisit,
            samples: Array(samples), dwell: aggregate.dwell,
            result: SearchResult(id: "history-" + aggregate.canon, target: .history(url), title: title,
                                 subtitle: URLCanonical.display(url), key: aggregate.key))
    }
}

enum SuggestionRanker {
    static let hostCapHistory = 2
    static let hostCapOpen = 3
    /// Open, pinned and shelved pages shown at most.
    static let openGroupMax = 3

    struct Scored {
        var candidate: SuggestionCandidate
        var score: Double
        /// A word of the query starts the host (or one of its labels).
        var hostPrefix: Bool
        /// The query is the start of something the user typed before to get here (or the same).
        var typedBefore: Bool
    }

    /// The ordered suggestions: top hit (when there is a confident one), then open, pinned and
    /// shelved pages, then history. Same page once; at most `hostCapHistory` history rows per site.
    static func rank(tokens: [String], rawQuery: String, candidates: [SuggestionCandidate],
                     picks: [String: PickRecord], now: Date, limit: Int) -> [SearchResult] {
        guard limit > 0, !tokens.isEmpty else { return [] }
        let query = tokens.joined(separator: " ")

        // One candidate per page: an open/pinned/shelved page beats its own history entry.
        var best: [String: Scored] = [:]
        for candidate in candidates {
            // Installers and archives are not places to go back to.
            if candidate.kind == .history, isDownload(candidate.url) { continue }
            guard let scored = score(candidate, tokens: tokens, query: query, picks: picks[candidate.canon], now: now) else { continue }
            if let existing = best[candidate.canon] {
                // Keep the more specific kind, but remember the history signal.
                if candidate.kind.rawValue < existing.candidate.kind.rawValue {
                    var merged = scored
                    merged.score = max(scored.score, existing.score)
                    best[candidate.canon] = merged
                } else if existing.score < scored.score {
                    best[candidate.canon]?.score = scored.score
                }
            } else {
                best[candidate.canon] = scored
            }
        }
        let ordered = best.values.sorted { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.candidate.lastUsed != b.candidate.lastUsed { return a.candidate.lastUsed > b.candidate.lastUsed }
            return a.candidate.canon < b.candidate.canon
        }

        var hostCount: [String: Int] = [:]
        var results: [SearchResult] = []

        // Top hit: only for plain words (a typed address or path goes to the literal "Go to" row).
        var top: Scored?
        if !rawQuery.contains("."), !rawQuery.contains("/"), !rawQuery.contains(":"), let first = ordered.first, isConfident(first) {
            top = first
            var result = first.candidate.result
            result.isTopHit = true
            results.append(result)
            hostCount[first.candidate.host, default: 0] += 1
        }

        let rest = ordered.filter { $0.candidate.canon != top?.candidate.canon }
        let live = rest.filter { $0.candidate.kind != .history }
        var openRows: [SearchResult] = []
        var openHosts: [String: Int] = [:]
        for scored in live where openRows.count < min(openGroupMax, limit - results.count) {
            let host = scored.candidate.host
            guard openHosts[host, default: 0] < hostCapOpen else { continue }
            openHosts[host, default: 0] += 1
            openRows.append(scored.candidate.result)
        }
        results += openRows

        for scored in rest where scored.candidate.kind == .history && results.count < limit {
            let host = scored.candidate.host
            guard hostCount[host, default: 0] < hostCapHistory else { continue }
            hostCount[host, default: 0] += 1
            results.append(scored.candidate.result)
        }
        return results
    }

    private static let downloadExtensions: Set<String> = ["dmg", "zip", "pkg", "exe", "msi", "gz", "tgz", "xz", "7z", "rar", "iso", "deb", "apk"]

    static func isDownload(_ foldedURL: String) -> Bool {
        guard let last = foldedURL.split(separator: "/").last, let dot = last.lastIndex(of: ".") else { return false }
        let ext = last[last.index(after: dot)...].split(separator: "?").first.map(String.init) ?? ""
        return downloadExtensions.contains(ext)
    }

    static func isConfident(_ s: Scored) -> Bool {
        guard s.hostPrefix || s.typedBefore else { return false }
        if s.candidate.kind != .history { return true }
        return s.candidate.visits >= 2 || s.typedBefore
    }

    /// nil when some word matches nothing. Higher is better.
    static func score(_ c: SuggestionCandidate, tokens: [String], query: String, picks: PickRecord?, now: Date) -> Scored? {
        var points = 0.0
        var hostPrefix = false
        let typedBefore = picks.map { inputMatches($0, query: query) } ?? false
        for token in tokens {
            var best = 0.0
            if c.host.hasPrefix(token) { best = 6; hostPrefix = true }
            else if c.host.split(separator: ".").contains(where: { $0.hasPrefix(token) }), !isTLD(token, host: c.host) { best = 5.5; hostPrefix = true }
            if best < 6 {
                if c.title.hasPrefix(token) || c.name.hasPrefix(token) { best = max(best, 6) }
                else if c.name.contains(" " + token) || c.title.contains(" " + token) { best = max(best, 5) }
                else if c.name.contains(token) || c.title.contains(token) { best = max(best, 3.5) }
                else if c.host.contains(token) { best = max(best, 3) }
                else if c.url.contains(token) { best = max(best, 1.5) }
            }
            if best == 0 {
                if typedBefore { continue } // reached before by typing this, whatever the page says
                return nil
            }
            points += best
        }
        var score = 50 * points / (6 * Double(tokens.count))
        if hostPrefix { score += c.isRoot ? 25 : 8 } // a deep link is not "the site"
        if hostPrefix, c.isRoot { score += 15 }

        let frecency = FrecencyScorer.score(samples: c.samples, visits: c.visits, dwell: c.dwell, now: now)
        score += min(60, 16 * log(1 + frecency / 40))

        if let picks {
            score += 14 * log(1 + Double(picks.count))
            // Picked recently counts a little more.
            score += picks.last.timeIntervalSince(now) > -14 * 86_400 ? 4 : 0
            if typedBefore { score += 60 }
        }
        switch c.kind {
        case .open, .pin: score += 25
        case .shelf: score += 10
        case .history: break
        }
        return Scored(candidate: c, score: score, hostPrefix: hostPrefix, typedBefore: typedBefore)
    }

    /// The query is the start of an input that led here before, or begins with one (2+ letters).
    static func inputMatches(_ record: PickRecord, query: String) -> Bool {
        record.inputs.contains { $0.hasPrefix(query) || (query.hasPrefix($0) && $0.count >= 2) }
    }

    /// "com" matching "github.com" through a label prefix says nothing about the site.
    private static func isTLD(_ token: String, host: String) -> Bool {
        guard let last = host.split(separator: ".").last else { return false }
        return last.hasPrefix(token) && host.split(separator: ".").count > 1 && token.count <= 3
    }
}
