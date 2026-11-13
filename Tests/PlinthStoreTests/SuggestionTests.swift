import Foundation
import Testing
import PlinthModel
@testable import PlinthStore


/// 2026-11-14 12:00 UTC-ish; fixed so frecency buckets are deterministic.
private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

private func visit(_ url: String, title: String = "", daysAgo: Double = 0, minutes: Double = 0, dwell: TimeInterval = 0) -> HistoryEntry {
    let link = u(url)
    let host = URLCanonical.host(link)
    return HistoryEntry(url: link, title: title, name: title, key: SiteKey(host),
                        visitedAt: now.addingTimeInterval(-daysAgo * 86_400 - minutes * 60), dwell: dwell)
}

/// Newest first, like `BrowserStore.history`.
private func newestFirst(_ entries: [HistoryEntry]) -> [HistoryEntry] {
    entries.sorted { $0.visitedAt > $1.visitedAt }
}

private func rank(_ query: String, history: [HistoryEntry], live: [SuggestionCandidate] = [],
                  picks: [String: PickRecord] = [:], limit: Int = 7) -> [SearchResult] {
    let index = SuggestionIndex(history: newestFirst(history))
    let tokens = URLCanonical.fold(query).split(whereSeparator: { $0.isWhitespace }).map(String.init)
    return SuggestionRanker.rank(tokens: tokens, rawQuery: query,
                                 candidates: index.candidates(matching: tokens) + index.candidates(typedBefore: picks, query: tokens.joined(separator: " ")) + live,
                                 picks: picks, now: now, limit: limit)
}

private func liveCandidate(_ kind: SuggestionCandidate.Kind, _ url: String, title: String) -> SuggestionCandidate {
    let link = u(url)
    let canon = URLCanonical.key(link)
    return SuggestionCandidate(
        kind: kind, canon: canon, host: URLCanonical.host(link), name: URLCanonical.fold(title), title: URLCanonical.fold(title),
        url: URLCanonical.fold(canon), isRoot: URLCanonical.isRoot(canon), visits: 1, lastUsed: now, samples: [now], dwell: 0,
        result: SearchResult(id: "live-" + canon, target: kind == .pin ? .pin(SiteID()) : .history(link), title: title,
                             subtitle: URLCanonical.display(link), key: SiteKey(URLCanonical.host(link))))
}

struct URLCanonicalTests {
    @Test func collapsesSchemeWwwSlashFragmentAndPort() {
        let variants = ["http://www.Example.com/a/b/", "https://example.com/a/b", "https://example.com:443/a/b#section",
                        "https://example.com/a/b/index.html", "http://example.com:80/a/b?"]
        let keys = Set(variants.map { URLCanonical.key($0) })
        #expect(keys == ["example.com/a/b"])
    }

    @Test func dropsTrackingParametersButKeepsContentOnes() {
        #expect(URLCanonical.key("https://a.com/p?utm_source=x&id=7&fbclid=abc") == "a.com/p?id=7")
        #expect(URLCanonical.key("https://a.com/p?b=2&a=1") == URLCanonical.key("https://a.com/p?a=1&b=2"))
        #expect(URLCanonical.key("https://a.com/p?id=7") != URLCanonical.key("https://a.com/p?id=8"))
        #expect(URLCanonical.key("https://a.com/p?gclid=1") == "a.com/p")
    }

    @Test func pathCaseAndDifferentPathsStayDistinct() {
        #expect(URLCanonical.key("https://a.com/Docs") != URLCanonical.key("https://a.com/docs"))
        #expect(URLCanonical.key("https://a.com/x") != URLCanonical.key("https://a.com/y"))
        #expect(URLCanonical.key("https://A.com/x") == URLCanonical.key("https://a.com/x"))
    }

    @Test func nonWebAddressesKeepTheirText() {
        #expect(URLCanonical.key("file:///tmp/a.html") == "file:///tmp/a.html")
        #expect(URLCanonical.key("about:blank") == "about:blank")
    }

    @Test func stripTrackingRemovesOnlyTrackers() {
        #expect(URLCanonical.stripTracking(u("https://a.com/p?utm_medium=x&id=7")).absoluteString == "https://a.com/p?id=7")
        #expect(URLCanonical.stripTracking(u("https://a.com/p?utm_medium=x")).absoluteString == "https://a.com/p")
        #expect(URLCanonical.stripTracking(u("https://a.com/p?id=7")).absoluteString == "https://a.com/p?id=7")
    }

    @Test func rootDetection() {
        #expect(URLCanonical.isRoot(URLCanonical.key("https://www.a.com/")))
        #expect(!URLCanonical.isRoot(URLCanonical.key("https://a.com/x")))
        #expect(!URLCanonical.isRoot(URLCanonical.key("https://a.com/?q=1")))
    }
}

struct FrecencyTests {
    @Test func recentBeatsOld() {
        let recent = FrecencyScorer.score(samples: [now], visits: 1, dwell: 0, now: now)
        let old = FrecencyScorer.score(samples: [now.addingTimeInterval(-200 * 86_400)], visits: 1, dwell: 0, now: now)
        #expect(recent > old * 5)
    }

    @Test func moreVisitsBeatFewer() {
        let few = FrecencyScorer.score(samples: [now], visits: 1, dwell: 0, now: now)
        let many = FrecencyScorer.score(samples: [Date](repeating: now, count: 10), visits: 40, dwell: 0, now: now)
        #expect(many > few * 10)
    }

    @Test func dwellHelpsALittle() {
        let plain = FrecencyScorer.score(samples: [now], visits: 3, dwell: 0, now: now)
        let engaged = FrecencyScorer.score(samples: [now], visits: 3, dwell: 900, now: now)
        #expect(engaged > plain)
        #expect(engaged < plain * 1.3)
    }

    @Test func noVisitsScoresZero() {
        #expect(FrecencyScorer.score(samples: [], visits: 0, dwell: 0, now: now) == 0)
    }
}

struct SuggestionRankingTests {
    /// 100 visits to one docs site, differing only by fragment, slash, scheme, www and tracking.
    private func duplicateHeavy() -> [HistoryEntry] {
        var out: [HistoryEntry] = []
        for i in 0..<100 {
            let variants = ["https://docs.example.com/guide", "http://docs.example.com/guide/", "https://docs.example.com/guide#s\(i)",
                            "https://docs.example.com/guide?utm_source=n\(i)", "https://www.docs.example.com/guide"]
            out.append(visit(variants[i % variants.count], title: "Guide", daysAgo: Double(i) / 10, minutes: Double(i)))
        }
        return out
    }

    @Test func hundredVisitsOfOnePageCollapseToOneRow() {
        let results = rank("guide", history: duplicateHeavy())
        #expect(results.count == 1)
        #expect(results.first?.title == "Guide")
    }

    @Test func aSiteIsCappedAtTwoHistoryRows() {
        var history: [HistoryEntry] = []
        for i in 0..<60 { history.append(visit("https://news.example.com/story/\(i)", title: "Story \(i) news", daysAgo: Double(i % 5), minutes: Double(i))) }
        history.append(visit("https://other.org/news", title: "News on another site", daysAgo: 1))
        let results = rank("news", history: history)
        let fromExample = results.filter { URLCanonical.host(URL(string: "https://" + $0.subtitle)!) == "news.example.com" }
        #expect(fromExample.count <= SuggestionRanker.hostCapHistory)
        #expect(results.contains { $0.subtitle.hasPrefix("other.org") })
        #expect(results.count <= 7)
    }

    @Test func resultsAreBounded() {
        var history: [HistoryEntry] = []
        for i in 0..<400 { history.append(visit("https://site\(i).com/page", title: "Recipe \(i)", daysAgo: Double(i % 40))) }
        #expect(rank("recipe", history: history).count == 7)
        #expect(rank("recipe", history: history, limit: 5).count == 5)
        #expect(rank("recipe", history: history, limit: 0).isEmpty)
    }

    @Test func frequentRecentPageOutranksRareOldOne() {
        var history = [visit("https://a.com/report", title: "Report old", daysAgo: 300)]
        for i in 0..<8 { history.append(visit("https://b.com/report", title: "Report weekly", daysAgo: Double(i))) }
        let results = rank("report", history: history)
        #expect(results.first?.subtitle == "b.com/report")
    }

    @Test func hostPrefixIsAConfidentTopHit() {
        var history: [HistoryEntry] = []
        for i in 0..<12 { history.append(visit("https://github.com/", title: "GitHub", daysAgo: Double(i))) }
        for i in 0..<30 { history.append(visit("https://github.com/acme/repo/pull/\(i)", title: "Pull \(i) github", daysAgo: Double(i % 3))) }
        history.append(visit("https://blog.example.com/why-git-is-hard", title: "Why git is hard", daysAgo: 1))
        let results = rank("git", history: history)
        #expect(results.first?.isTopHit == true)
        #expect(results.first?.subtitle == "github.com")
        #expect(results.filter(\.isTopHit).count == 1)
    }

    @Test func aOneOffVisitIsNotConfidentEnoughForTopHit() {
        let results = rank("rare", history: [visit("https://rarely.example.net/", title: "Rare", daysAgo: 400)])
        #expect(results.count == 1)
        #expect(results.first?.isTopHit == false)
    }

    @Test func typedAddressesAndPathsGetNoTopHit() {
        var history: [HistoryEntry] = []
        for i in 0..<10 { history.append(visit("https://github.com/acme/repo", title: "repo", daysAgo: Double(i))) }
        #expect(rank("github.com", history: history).allSatisfy { !$0.isTopHit })
        #expect(rank("github.com/ac", history: history).allSatisfy { !$0.isTopHit })
    }

    @Test func openPagesComeBeforeHistoryAndAreNotRepeated() {
        var history: [HistoryEntry] = []
        for i in 0..<6 { history.append(visit("https://wiki.example.org/Swift", title: "Swift wiki", daysAgo: Double(i))) }
        for i in 0..<6 { history.append(visit("https://docs.example.net/swift", title: "Swift docs", daysAgo: Double(i))) }
        let open = liveCandidate(.open, "https://wiki.example.org/Swift#intro", title: "Swift wiki")
        let results = rank("swift", history: history, live: [open])
        // The open page is listed once (not again from history) and ahead of the history-only page.
        #expect(results.filter { $0.subtitle == "wiki.example.org/Swift" }.count == 1)
        let wiki = results.firstIndex { $0.subtitle == "wiki.example.org/Swift" }!
        let docs = results.firstIndex { $0.subtitle == "docs.example.net/swift" }!
        #expect(wiki < docs)
    }

    @Test func pickedPagesRankHigher() {
        var history: [HistoryEntry] = []
        for i in 0..<5 { history.append(visit("https://a.com/notes", title: "Notes alpha", daysAgo: Double(i))) }
        for i in 0..<5 { history.append(visit("https://b.com/notes", title: "Notes beta", daysAgo: Double(i))) }
        let before = rank("notes", history: history)
        let loser = before.last!.subtitle
        var picks: [String: PickRecord] = [:]
        var record = PickRecord(count: 0, last: now, inputs: [])
        for _ in 0..<4 { record.record(input: "notes", at: now) }
        picks[URLCanonical.key("https://" + loser)] = record
        let after = rank("notes", history: history, picks: picks)
        #expect(after.first?.subtitle == loser)
    }

    @Test func aTypedInputBecomesATopHitForThatPrefix() {
        var history: [HistoryEntry] = []
        for i in 0..<3 { history.append(visit("https://intranet.corp.example/tools/timesheet", title: "Timesheet", daysAgo: Double(i))) }
        for i in 0..<3 { history.append(visit("https://other.example/ts", title: "ts calculator", daysAgo: Double(i))) }
        var record = PickRecord(count: 0, last: now, inputs: [])
        record.record(input: "ts", at: now)
        let picks = [URLCanonical.key("https://intranet.corp.example/tools/timesheet"): record]
        let results = rank("ts", history: history, picks: picks)
        #expect(results.first?.subtitle == "intranet.corp.example/tools/timesheet")
        #expect(results.first?.isTopHit == true)
    }

    @Test func everyWordMustMatch() {
        let history = [visit("https://a.com/x", title: "Berlin flights"), visit("https://b.com/y", title: "Berlin hotels")]
        #expect(rank("berlin hotels", history: history).map(\.subtitle) == ["b.com/y"])
        #expect(rank("berlin tokyo", history: history).isEmpty)
        #expect(rank("   ", history: history).isEmpty)
    }

    @Test func diacriticsAndCaseDoNotMatter() {
        let history = [visit("https://cafe.example/menu", title: "Café Menü")]
        #expect(rank("CAFE menu", history: history).count == 1)
    }

    @Test func resultsUseTheCleanAddress() {
        let history = [visit("https://a.com/p?utm_source=x&id=1", title: "Item")]
        guard case .history(let url)? = rank("item", history: history).first?.target else { Issue.record("no result"); return }
        #expect(url.absoluteString == "https://a.com/p?id=1")
    }

    @Test func hostCapCountsTheTopHit() {
        var history: [HistoryEntry] = []
        for i in 0..<10 { history.append(visit("https://github.com/", title: "GitHub", daysAgo: Double(i))) }
        for i in 0..<10 { history.append(visit("https://github.com/a/\(i)", title: "github \(i)", daysAgo: Double(i))) }
        let results = rank("github", history: history)
        #expect(results.count == SuggestionRanker.hostCapHistory)
    }
}

struct SuggestionIndexTests {
    @Test func incrementalUpdateMatchesFullRebuild() {
        var history = newestFirst((0..<200).map { visit("https://s\($0 % 7).com/p\($0 % 13)", title: "T\($0 % 13)", daysAgo: Double($0) / 5) })
        var index = SuggestionIndex(history: history)
        for i in 0..<5 {
            history.insert(visit("https://s\(i).com/p\(i)", title: "T\(i)", daysAgo: -Double(i + 1) / 100), at: 0)
            index.update(with: history)
        }
        let fresh = SuggestionIndex(history: history)
        #expect(Set(index.aggregates.keys) == Set(fresh.aggregates.keys))
        for (key, value) in fresh.aggregates {
            #expect(index.aggregates[key]?.visits == value.visits)
            #expect(index.aggregates[key]?.lastVisit == value.lastVisit)
        }
    }

    @Test func clearedHistoryEmptiesTheIndex() {
        var index = SuggestionIndex(history: [visit("https://a.com/", title: "A")])
        index.update(with: [])
        #expect(index.aggregates.isEmpty)
    }

    @Test func aLateTitleReachesTheIndex() {
        var entry = visit("https://a.com/x", title: "")
        var index = SuggestionIndex(history: [entry])
        entry.title = "Late title"
        entry.name = "Late title"
        index.update(with: [entry])
        #expect(index.aggregates.values.first?.title == "Late title")
    }

    @Test func largeDuplicateHeavyHistoryIsFast() {
        var history: [HistoryEntry] = []
        for i in 0..<20_000 { history.append(visit("https://site\(i % 150).com/page\(i % 40)?utm_source=\(i)", title: "Page \(i % 40) of site \(i % 150)", daysAgo: Double(i) / 120)) }
        let sorted = newestFirst(history)
        let start = ContinuousClock.now
        let index = SuggestionIndex(history: sorted)
        let build = ContinuousClock.now - start
        let tokens = ["site1"]
        let queryStart = ContinuousClock.now
        let results = SuggestionRanker.rank(tokens: tokens, rawQuery: "site1", candidates: index.candidates(matching: tokens),
                                            picks: [:], now: now, limit: 7)
        let query = ContinuousClock.now - queryStart
        #expect(index.aggregates.count == 150 * 40 / 1 || index.aggregates.count <= 6_000)
        #expect(results.count <= 7)
        #expect(build < .seconds(3))
        #expect(query < .milliseconds(500))
    }
}

@MainActor
struct SuggestionStoreTests {
    private func seed(_ rig: Rig) {
        let store = rig.store
        var entries: [HistoryEntry] = []
        for i in 0..<100 {
            entries.append(HistoryEntry(url: u("https://www.example.com/docs/\(i % 3)?utm_campaign=\(i)#x\(i)"), title: "Docs \(i % 3) - Example",
                                        name: "Docs \(i % 3)", key: SiteKey("example.com"), visitedAt: rig.clock.t.addingTimeInterval(-Double(i) * 600)))
        }
        entries.append(HistoryEntry(url: u("https://example.org/"), title: "Example Org", name: "Example Org", key: SiteKey("example.org"), visitedAt: rig.clock.t.addingTimeInterval(-86_400)))
        store.history = entries
    }

    @Test func storeCollapsesAHundredVisitsToThreePages() {
        let rig = Rig()
        seed(rig)
        let results = rig.store.suggestions(for: "docs")
        // Three distinct pages on one site, but at most two history rows per site.
        #expect(results.count == SuggestionRanker.hostCapHistory)
        #expect(Set(results.map(\.subtitle)).count == results.count)
    }

    @Test func recordingAPickRaisesThatPageAndPersists() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("plinth-picks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let rig = Rig(dir: dir)
        seed(rig)
        _ = rig.store.suggestions(for: "example")
        rig.store.recordSuggestionPick(url: u("https://example.org/"))
        #expect(rig.store.picks.count == 1)
        let results = rig.store.suggestions(for: "example")
        #expect(results.first?.subtitle == "example.org")
        try rig.store.save()
        let again = Rig(dir: dir)
        #expect(again.store.picks.keys.contains("example.org"))
        #expect(again.store.picks["example.org"]?.inputs == ["example"])
    }

    @Test func nonWebPicksAreIgnoredAndTheTableIsBounded() {
        let rig = Rig()
        rig.store.recordSuggestionPick(url: u("about:blank"), input: "x")
        #expect(rig.store.picks.isEmpty)
        for i in 0..<(BrowserStore.picksCap + 50) { rig.store.recordSuggestionPick(url: u("https://p\(i).com/"), input: "p") }
        #expect(rig.store.picks.count == BrowserStore.picksCap)
    }

    @Test func emptyQueryGivesNothing() {
        let rig = Rig()
        seed(rig)
        #expect(rig.store.suggestions(for: "  ").isEmpty)
    }

    @Test func openPageIsListedBeforeHistoryOnlyPages() {
        let rig = Rig()
        let w = rig.store.createWindow()
        rig.open("https://example.org/", in: w)
        seed(rig)
        let results = rig.store.suggestions(for: "example")
        guard case .openPage? = results.first(where: { $0.subtitle == "example.org" })?.target else {
            Issue.record("the open page should be listed as open"); return
        }
        #expect(results.filter { $0.subtitle == "example.org" }.count == 1)
    }
}
