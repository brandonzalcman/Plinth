import Foundation
import Testing
import PlinthModel
@testable import PlinthStore


private var utc: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}

/// Wednesday 12:00 UTC.
private let noon = Date(timeIntervalSince1970: 1_799_971_200 + 12 * 3_600)

private func entry(_ url: String, _ title: String, hoursAgo: Double) -> HistoryEntry {
    let link = u(url)
    return HistoryEntry(url: link, title: title, name: title, key: SiteKey(URLCanonical.host(link)),
                        visitedAt: noon.addingTimeInterval(-hoursAgo * 3_600))
}

struct HistoryIndexTests {
    private let small: [HistoryEntry] = [
        entry("https://a.com/one", "Alpha one", hoursAgo: 1),
        entry("https://a.com/two", "Alpha two", hoursAgo: 2),
        entry("https://b.com/", "Beta", hoursAgo: 3),
        entry("https://a.com/one", "Alpha one", hoursAgo: 20),       // yesterday
        entry("https://c.org/", "Gamma", hoursAgo: 24 * 3),          // 3 days
        entry("https://c.org/old", "Gamma old", hoursAgo: 24 * 20),  // 20 days
        entry("https://d.net/", "Delta", hoursAgo: 24 * 100),        // long ago
    ]

    private func page(_ filter: HistoryFilter, in history: [HistoryEntry]? = nil) -> HistoryPage {
        HistoryIndex(history ?? small).page(for: filter, now: noon, calendar: utc)
    }

    @Test func textFiltersByTitleHostAndURL() {
        #expect(page(HistoryFilter(text: "alpha")).totalRows == 3)
        #expect(page(HistoryFilter(text: "b.com")).totalRows == 1)
        #expect(page(HistoryFilter(text: "gamma old")).totalRows == 1)
        #expect(page(HistoryFilter(text: "/two")).totalRows == 1)
        #expect(page(HistoryFilter(text: "nothing here")).totalRows == 0)
    }

    @Test func textIsCaseAndAccentInsensitive() {
        let history = [entry("https://cafe.example/", "Café Menü", hoursAgo: 1)]
        #expect(page(HistoryFilter(text: "CAFE menu"), in: history).totalRows == 1)
    }

    @Test func rangesCutAtLocalDays() {
        #expect(page(HistoryFilter(range: .today)).totalRows == 3)
        #expect(page(HistoryFilter(range: .yesterday)).totalRows == 1)
        #expect(page(HistoryFilter(range: .week)).totalRows == 5)
        #expect(page(HistoryFilter(range: .month)).totalRows == 6)
        #expect(page(HistoryFilter(range: .all)).totalRows == 7)
    }

    @Test func siteFilterKeepsOneHostButSitesListIgnoresIt() {
        let result = page(HistoryFilter(site: "a.com"))
        #expect(result.totalRows == 3)
        #expect(result.days.flatMap(\.rows).allSatisfy { $0.key.host == "a.com" })
        // Facets still show every site, so the user can switch.
        #expect(Set(result.sites.map(\.host)) == ["a.com", "b.com", "c.org", "d.net"])
        #expect(result.sites.first?.host == "a.com")
        #expect(result.sites.first?.count == 3)
    }

    @Test func groupsByDayNewestFirst() {
        let result = page(HistoryFilter())
        #expect(result.days.count == 5)
        #expect(result.days.map(\.day) == result.days.map(\.day).sorted(by: >))
        #expect(result.days[0].rows.map(\.title) == ["Alpha one", "Alpha two", "Beta"])
    }

    @Test func mergesConsecutiveRepeatsOnly() {
        let history = [
            entry("https://a.com/x", "X", hoursAgo: 1),
            entry("https://www.a.com/x#top", "X", hoursAgo: 1.1),
            entry("http://a.com/x/", "X", hoursAgo: 1.2),
            entry("https://a.com/y", "Y", hoursAgo: 1.3),
            entry("https://a.com/x", "X", hoursAgo: 1.4),
        ]
        let rows = page(HistoryFilter(), in: history).days.flatMap(\.rows)
        #expect(rows.map(\.title) == ["X", "Y", "X"])
        #expect(rows.map(\.visits) == [3, 1, 1])
        #expect(page(HistoryFilter(), in: history).totalRows == 3)
    }

    @Test func repeatsMergeAfterFilteringToo() {
        let history = [
            entry("https://a.com/x", "X", hoursAgo: 1),
            entry("https://b.com/", "Other", hoursAgo: 1.1),
            entry("https://a.com/x", "X", hoursAgo: 1.2),
        ]
        #expect(page(HistoryFilter(site: "a.com"), in: history).days.flatMap(\.rows).map(\.visits) == [2])
        #expect(page(HistoryFilter(), in: history).days.flatMap(\.rows).map(\.visits) == [1, 1, 1])
    }

    @Test func rowLimitTruncatesButTotalsStayHonest() {
        let history = (0..<100).map { entry("https://a.com/\($0)", "Page \($0)", hoursAgo: Double($0) / 10) }
        let result = HistoryIndex(history).page(for: HistoryFilter(), now: noon, calendar: utc, rowLimit: 25)
        #expect(result.shownRows == 25)
        #expect(result.totalRows == 100)
    }

    @Test func outOfOrderImportsAreSorted() {
        let history = [entry("https://a.com/old", "Old", hoursAgo: 50), entry("https://a.com/new", "New", hoursAgo: 1)]
        #expect(page(HistoryFilter(), in: history).days.flatMap(\.rows).map(\.title) == ["New", "Old"])
    }

    @Test func emptyHistoryGivesAnEmptyPage() {
        #expect(page(HistoryFilter(), in: []) == .empty)
    }

    @Test func rowTitleFallsBackToTheAddress() {
        let bare = HistoryEntry(url: u("https://www.untitled.example/a/b"), title: "", name: "", key: SiteKey("untitled.example"), visitedAt: noon)
        #expect(page(HistoryFilter(), in: [bare]).days.first?.rows.first?.title == "untitled.example/a/b")
    }
}

struct HistoryScaleTests {
    /// 50,000 visits over a year: a few hundred sites, each with a handful of pages revisited constantly.
    private func fiftyThousand() -> [HistoryEntry] {
        var history: [HistoryEntry] = []
        history.reserveCapacity(50_000)
        for i in 0..<50_000 {
            let site = (i * 7) % 300
            let pageNumber = i % 12
            history.append(entry("https://www.site\(site).example.com/section/\(pageNumber)?utm_source=mail\(i % 5)",
                                 "Site \(site) section \(pageNumber)", hoursAgo: Double(i) * 0.17))
        }
        return history
    }

    @Test func buildsAndQueriesFiftyThousandVisitsQuickly() {
        let history = fiftyThousand()
        let built = ContinuousClock.now
        let index = HistoryIndex(history)
        let buildTime = ContinuousClock.now - built
        #expect(index.count == 50_000)
        #expect(buildTime < .seconds(5))

        let filters = [HistoryFilter(), HistoryFilter(text: "site17"), HistoryFilter(text: "site17 section 3"),
                       HistoryFilter(text: "zzz"), HistoryFilter(range: .month), HistoryFilter(range: .today, site: "site7.example.com"),
                       HistoryFilter(text: "section", range: .week)]
        let start = ContinuousClock.now
        for _ in 0..<5 {
            for filter in filters { _ = index.page(for: filter, now: noon, calendar: utc) }
        }
        let perQuery = (ContinuousClock.now - start) / (5 * filters.count)
        #expect(perQuery < .milliseconds(150), "a query over 50k visits took \(perQuery)")
    }

    @Test func fiftyThousandResultsStayBoundedAndCorrect() {
        let index = HistoryIndex(fiftyThousand())
        let result = index.page(for: HistoryFilter(text: "site17"), now: noon, calendar: utc, rowLimit: 300)
        #expect(result.shownRows <= 300)
        #expect(result.totalRows > result.shownRows)
        #expect(result.days.flatMap(\.rows).allSatisfy { $0.title.hasPrefix("Site 17") })
        #expect(index.page(for: HistoryFilter(text: "site17 nomatch"), now: noon, calendar: utc).totalRows == 0)
    }

    @Test func duplicateHeavyHistoryStillShowsEveryDistinctVisit() {
        // 100 visits of one page then one of another, interleaved: nothing is consecutive, nothing merges.
        var history: [HistoryEntry] = []
        for i in 0..<100 {
            history.append(entry("https://a.com/x", "X", hoursAgo: Double(i) * 2))
            history.append(entry("https://a.com/y", "Y", hoursAgo: Double(i) * 2 + 1))
        }
        #expect(HistoryIndex(history).page(for: HistoryFilter(), now: noon, calendar: utc, rowLimit: 1_000).totalRows == 200)
    }
}
