import Foundation
import Testing
import PlinthModel
import PlinthRules
import PlinthFade
import PlinthStore
@testable import PlinthBrowserImport

@Suite struct ChromiumReaderTests {
    @Test func bookmarksFromEveryProfileSitInFoldersNamedForThem() throws {
        let home = FakeHome()
        let root = home.root(.brave)
        writeChromiumBookmarks(root.appendingPathComponent("Default"), bar: [chromeNode("Swift", "https://swift.org/"),
                                                                             chromeFolder("News", [chromeNode("BBC", "https://www.bbc.co.uk/")])])
        writeChromiumBookmarks(root.appendingPathComponent("Profile 1"), other: [chromeNode("Docs", "https://docs.example/"),
                                                                                 chromeNode("Script", "javascript:void(0)")])
        writeLocalState(root, names: ["Default": "Me", "Profile 1": "Work"])
        let items = try ChromiumReader.bookmarks(.brave, home: home.url)
        #expect(items.map(\.url.host) == ["swift.org", "www.bbc.co.uk", "docs.example"])
        #expect(items.map(\.folder) == [["Me", "Bookmarks bar"], ["Me", "Bookmarks bar", "News"], ["Work", "Other bookmarks"]])
    }

    @Test func oneProfileKeepsItsFoldersAsTheyAre() throws {
        let home = FakeHome()
        writeChromiumBookmarks(home.root(.vivaldi).appendingPathComponent("Default"), bar: [chromeNode("A", "https://a.example/")])
        #expect(try ChromiumReader.bookmarks(.vivaldi, home: home.url).map(\.folder) == [["Bookmarks bar"]])
    }

    @Test func historyIsMergedAcrossProfilesNewestFirst() throws {
        let home = FakeHome()
        let root = home.root(.edge)
        writeChromiumHistory(root.appendingPathComponent("Default"), [("https://a.example/", "A", 1_700_000_000), ("https://c.example/", "C", 1_700_000_300)])
        writeChromiumHistory(root.appendingPathComponent("Profile 2"), [("https://b.example/", "B", 1_700_000_100), ("ftp://x.example/", "X", 1_700_000_400)])
        let visits = try ChromiumReader.history(.edge, home: home.url, limit: 100)
        #expect(visits.map(\.title) == ["C", "B", "A"])
        #expect(visits[2].date == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(try ChromiumReader.history(.edge, home: home.url, limit: 2).map(\.title) == ["C", "B"])
    }

    @Test func operaReadsItsDataFolderAsAProfile() throws {
        let home = FakeHome()
        writeChromiumHistory(home.root(.opera), [("https://opera.example/", "O", 1_700_000_000)])
        #expect(try ChromiumReader.history(.opera, home: home.url, limit: 10).map(\.title) == ["O"])
    }

    @Test func aMissingBrowserIsReportedAsNotFound() {
        let home = FakeHome()
        #expect(throws: ImportFailure.self) { _ = try ChromiumReader.bookmarks(.chromium, home: home.url) }
        do throws(ImportFailure) { _ = try ChromiumReader.history(.chromium, home: home.url, limit: 1) }
        catch { #expect(error.kind == .notFound) }
    }
}

@Suite struct FirefoxReaderTests {
    @Test func bookmarksKeepTheirFoldersAndHistoryIsNewestFirst() throws {
        let home = FakeHome()
        let profile = home.root(.firefox).appendingPathComponent("Profiles/abc.default-release")
        writePlaces(profile, bookmarks: [("https://mozilla.org/", "Mozilla"), ("https://read.example/", "Later")],
                    visits: [("https://one.example/", "One", 1_700_000_000), ("https://two.example/", "Two", 1_700_000_500)])
        let bookmarks = try FirefoxReader.bookmarks(.firefox, home: home.url)
        #expect(bookmarks.map(\.title) == ["Mozilla", "Later"])
        #expect(bookmarks.map(\.folder) == [["Bookmarks Toolbar"], ["Bookmarks Toolbar", "Reading"]])
        let visits = try FirefoxReader.history(.firefox, home: home.url, limit: 10)
        #expect(visits.map(\.title) == ["Two", "One"])
        #expect(visits[1].date == Date(timeIntervalSince1970: 1_700_000_000))
    }
}

@MainActor
@Suite struct ImportRunTests {
    struct NoFade: FadeEvaluating {
        func evaluate(sites: [Site], stats: [SiteKey: Usage], visible: Set<PageID>, now: Date) -> FadeVerdict { FadeVerdict() }
    }

    @Test func aRunAddsBookmarksUnderTheBrowsersFolderAndHistoryToTheStore() async throws {
        let home = FakeHome()
        let root = home.root(.brave)
        writeChromiumBookmarks(root.appendingPathComponent("Default"), bar: [chromeNode("Swift", "https://swift.org/")])
        writeChromiumHistory(root.appendingPathComponent("Default"), [("https://swift.org/", "Swift", 1_700_000_000)])
        let store = BrowserStore(identity: SiteIdentity(), namer: PageNamer(), fader: NoFade(), storageDirectory: nil)
        let bookmarks = BookmarkStore(storageDirectory: nil)
        let report = try await ImportService.run(.brave, bookmarks: true, history: true, into: store, bookmarkStore: bookmarks, home: home.url)
        #expect(report.bookmarksImported == 1)
        #expect(report.historyImported == 1)
        #expect(bookmarks.folderChoices().map(\.label).contains("Imported from Brave"))
        #expect(store.history.first?.url.host == "swift.org")
        // Running it again adds nothing.
        let again = try await ImportService.run(.brave, bookmarks: true, history: true, into: store, bookmarkStore: bookmarks, home: home.url)
        #expect(again.bookmarksImported == 0)
        #expect(again.historyImported == 0)
    }

    @Test func oneSideFailingIsANoteNotAFailure() async throws {
        let home = FakeHome()
        writeChromiumHistory(home.root(.chromium).appendingPathComponent("Default"), [("https://a.example/", "A", 1_700_000_000)])
        let store = BrowserStore(identity: SiteIdentity(), namer: PageNamer(), fader: NoFade(), storageDirectory: nil)
        let report = try await ImportService.run(.chromium, bookmarks: true, history: true, into: store,
                                                 bookmarkStore: BookmarkStore(storageDirectory: nil), home: home.url)
        #expect(report.historyImported == 1)
        #expect(report.notes.contains { $0.hasPrefix("Bookmarks weren't imported.") })
    }
}

#if os(macOS)
@Suite struct SafariHistoryTests {
    @Test func historyIsNewestFirstAndSkipsNonWebAddresses() throws {
        let home = FakeHome()
        let folder = home.root(.safari)
        home.dir(folder)
        // Safari stores visit times as seconds since 2001 (the reference date).
        makeSQLite(folder.appendingPathComponent("History.db"), [
            "CREATE TABLE history_items (id INTEGER PRIMARY KEY, url TEXT)",
            "CREATE TABLE history_visits (id INTEGER PRIMARY KEY, history_item INTEGER, title TEXT, visit_time REAL)",
            "INSERT INTO history_items VALUES (1, 'https://apple.com/'), (2, 'https://swift.org/blog'), (3, 'file:///etc/hosts')",
            "INSERT INTO history_visits VALUES (1, 1, 'Apple', 700000000), (2, 2, 'Swift blog', 700000500), (3, 3, 'Hosts', 700000900)",
        ])
        let visits = try SafariReader.history(home: home.url, limit: 10)
        #expect(visits.map(\.title) == ["Swift blog", "Apple"])
        #expect(visits[1].date == Date(timeIntervalSinceReferenceDate: 700000000))
        #expect(try SafariReader.history(home: home.url, limit: 1).count == 1)
    }

    @Test func noSafariHistoryIsReportedNotThrownAway() {
        do {
            _ = try SafariReader.history(home: FakeHome().url, limit: 10)
            Issue.record("expected a failure")
        } catch {
            #expect(error.kind == .notFound || error.kind == .permissionDenied)
        }
    }
}
#endif

/// Each browser's newest-N history is the newest N *web* visits: other addresses are filtered before the limit.
@Suite struct HistoryLimitTests {
    @Test func chromiumLimitCountsOnlyWebVisits() throws {
        let home = FakeHome()
        writeChromiumHistory(home.root(.chrome).appendingPathComponent("Default"),
                             [("https://old.example/", "Old", 1_700_000_000),
                              ("chrome://settings/", "Settings", 1_700_000_900)])
        #expect(try ChromiumReader.history(.chrome, home: home.url, limit: 1).map(\.title) == ["Old"])
    }

    @Test func firefoxLimitCountsOnlyWebVisits() throws {
        let home = FakeHome()
        writePlaces(home.root(.firefox).appendingPathComponent("Profiles/abc.default-release"), bookmarks: [],
                    visits: [("https://old.example/", "Old", 1_700_000_000), ("about:config", "Config", 1_700_000_900)])
        #expect(try FirefoxReader.history(.firefox, home: home.url, limit: 1).map(\.title) == ["Old"])
    }
}
