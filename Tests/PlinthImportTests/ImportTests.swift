import Foundation
import SQLite3
import Testing
import PlinthModel
import PlinthRules
import PlinthStore
@testable import PlinthImport

// MARK: - Fixtures

struct NoFade: FadeEvaluating {
    func evaluate(sites: [Site], stats: [SiteKey: Usage], visible: Set<PageID>, now: Date) -> FadeVerdict { FadeVerdict() }
}

@MainActor func makeStore() -> BrowserStore {
    BrowserStore(identity: SiteIdentity(), namer: PageNamer(), fader: NoFade(), storageDirectory: nil)
}

/// A fake home directory, removed when the value goes away.
final class FakeHome {
    let url: URL
    init() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("plinth-import-test-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit {
        // Undo any chmod 000 so the tree can be removed.
        if let e = FileManager.default.enumerator(atPath: url.path) {
            for case let p as String in e { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.appendingPathComponent(p).path) }
        }
        try? FileManager.default.removeItem(at: url)
    }
    var safari: URL { url.appendingPathComponent("Library/Safari") }
    var chrome: URL { url.appendingPathComponent("Library/Application Support/Google/Chrome") }
    func dir(_ u: URL) { try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true) }
}

func leaf(_ url: String, _ title: String?) -> [String: Any] {
    var d: [String: Any] = ["WebBookmarkType": "WebBookmarkTypeLeaf", "URLString": url]
    if let title { d["URIDictionary"] = ["title": title] }
    return d
}
func folder(_ title: String, _ children: [[String: Any]]) -> [String: Any] {
    ["WebBookmarkType": "WebBookmarkTypeList", "Title": title, "Children": children]
}

func writeSafariPlist(_ home: FakeHome, _ children: [[String: Any]]) {
    home.dir(home.safari)
    let root: [String: Any] = ["WebBookmarkType": "WebBookmarkTypeList", "Children": children]
    let data = try! PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
    try! data.write(to: home.safari.appendingPathComponent("Bookmarks.plist"))
}

func makeSQLite(_ url: URL, _ statements: [String]) {
    var db: OpaquePointer?
    precondition(sqlite3_open(url.path, &db) == SQLITE_OK)
    defer { sqlite3_close(db) }
    for s in statements { precondition(sqlite3_exec(db, s, nil, nil, nil) == SQLITE_OK, "\(s)") }
}

/// Safari rows are (url, title, CFAbsoluteTime).
func writeSafariHistory(_ home: FakeHome, _ rows: [(String, String?, Double)]) {
    home.dir(home.safari)
    var sql = ["CREATE TABLE history_items (id INTEGER PRIMARY KEY, url TEXT)",
               "CREATE TABLE history_visits (id INTEGER PRIMARY KEY, history_item INTEGER, visit_time REAL, title TEXT)",
               "BEGIN"]
    for (i, r) in rows.enumerated() {
        sql.append("INSERT INTO history_items VALUES (\(i + 1), '\(r.0)')")
        sql.append("INSERT INTO history_visits VALUES (\(i + 1), \(i + 1), \(r.2), \(r.1.map { "'\($0)'" } ?? "NULL"))")
    }
    sql.append("COMMIT")
    makeSQLite(home.safari.appendingPathComponent("History.db"), sql)
}

func chromeNode(_ name: String, _ url: String) -> [String: Any] { ["type": "url", "name": name, "url": url] }
func chromeFolder(_ name: String, _ children: [[String: Any]]) -> [String: Any] { ["type": "folder", "name": name, "children": children] }

func writeChromeBookmarks(_ home: FakeHome, profile: String = "Default", bar: [[String: Any]] = [], other: [[String: Any]] = []) {
    let dir = home.chrome.appendingPathComponent(profile)
    home.dir(dir)
    let roots: [String: Any] = ["bookmark_bar": chromeFolder("Bookmarks bar", bar), "other": chromeFolder("Other", other),
                                "synced": chromeFolder("Mobile", [])]
    let data = try! JSONSerialization.data(withJSONObject: ["roots": roots, "version": 1])
    try! data.write(to: dir.appendingPathComponent("Bookmarks"))
}

/// Chrome rows are (url, title, unix seconds).
func writeChromeHistory(_ home: FakeHome, profile: String = "Default", _ rows: [(String, String?, Double)]) {
    let dir = home.chrome.appendingPathComponent(profile)
    home.dir(dir)
    var sql = ["CREATE TABLE urls (id INTEGER PRIMARY KEY, url TEXT, title TEXT, last_visit_time INTEGER)",
               "CREATE TABLE visits (id INTEGER PRIMARY KEY, url INTEGER, visit_time INTEGER)",
               "BEGIN"]
    for (i, r) in rows.enumerated() {
        let t = Int64((r.2 + 11_644_473_600) * 1_000_000)
        sql.append("INSERT INTO urls VALUES (\(i + 1), '\(r.0)', \(r.1.map { "'\($0)'" } ?? "NULL"), \(t))")
        sql.append("INSERT INTO visits VALUES (\(i + 1), \(i + 1), \(t))")
    }
    sql.append("COMMIT")
    makeSQLite(dir.appendingPathComponent("History"), sql)
}

@MainActor func failure(_ body: @MainActor () async throws -> some Any) async -> ImportFailure? {
    do { _ = try await body(); return nil } catch { return error as? ImportFailure }
}

// MARK: - Parsing

@Suite struct SafariParsing {
    @Test func bookmarksNestedAndFiltered() throws {
        let home = FakeHome()
        writeSafariPlist(home, [
            folder("BookmarksBar", [leaf("https://a.com/x", "A"), folder("Deep", [folder("Deeper", [leaf("http://b.com/", "B")])]), leaf("javascript:alert(1)", "js"), leaf("file:///tmp/x", "f")]),
            folder("com.apple.ReadingList", [leaf("https://reading.com/", "R")]),
            ["WebBookmarkType": "WebBookmarkTypeProxy", "Title": "History", "URLString": "https://proxy.com/"],
            leaf("https://notitle.com/", nil),
        ])
        let items = try SafariReader.bookmarks(home: home.url)
        #expect(items.map(\.url.absoluteString) == ["https://a.com/x", "http://b.com/", "https://notitle.com/"])
        #expect(items[0].title == "A")
        #expect(items[2].title == "")
    }

    @Test func historyTimeAndFilters() throws {
        let home = FakeHome()
        writeSafariHistory(home, [("https://a.com/", "A", 700_000_000), ("https://b.com/", nil, 700_000_500), ("ftp://c.com/", "C", 700_000_900), ("about:blank", "x", 700_001_000)])
        let visits = try SafariReader.history(home: home.url, limit: 100)
        #expect(visits.map(\.url.host) == ["b.com", "a.com"], "newest first, http(s) only")
        #expect(visits[1].date == Date(timeIntervalSinceReferenceDate: 700_000_000))
        #expect(visits[0].title == "")
    }

    @Test func historyReadsWalAndLeavesSourceAlone() throws {
        let home = FakeHome()
        writeSafariHistory(home, [("https://a.com/", "A", 700_000_000)])
        let db = home.safari.appendingPathComponent("History.db")
        let before = try Data(contentsOf: db)
        _ = try SafariReader.history(home: home.url, limit: 10)
        #expect(try Data(contentsOf: db) == before)
        // The temp copy is cleaned up.
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path))?.filter { $0.hasPrefix("plinth-import-") && !$0.hasPrefix("plinth-import-test-") } ?? []
        #expect(leftovers.isEmpty)
    }
}

@Suite struct ChromeParsing {
    @Test func bookmarksNestedAndFiltered() throws {
        let home = FakeHome()
        writeChromeBookmarks(home, bar: [chromeNode("A", "https://a.com/"), chromeFolder("F", [chromeFolder("G", [chromeNode("B", "http://b.com/")]), chromeNode("js", "javascript:void(0)")])],
                             other: [chromeNode("chrome", "chrome://settings"), chromeNode("C", "https://c.com/")])
        let items = try ChromeReader.bookmarks(home: home.url)
        #expect(items.map(\.url.host) == ["a.com", "b.com", "c.com"])
        #expect(items[1].title == "B")
    }

    @Test func historyTimeConversion() throws {
        let home = FakeHome()
        writeChromeHistory(home, [("https://a.com/", "A", 1_700_000_000), ("https://b.com/", nil, 1_700_000_100), ("chrome://x", "x", 1_700_000_200)])
        let visits = try ChromeReader.history(home: home.url, limit: 10)
        #expect(visits.count == 2)
        #expect(visits[0].url.host == "b.com")
        #expect(visits[1].date == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(ChromeReader.date(chromeTime: 11_644_473_600 * 1_000_000) == Date(timeIntervalSince1970: 0))
    }

    @Test func fallsBackToNumberedProfile() throws {
        let home = FakeHome()
        home.dir(home.chrome.appendingPathComponent("Default"))
        writeChromeBookmarks(home, profile: "Profile 2", bar: [chromeNode("P2", "https://p2.com/")])
        writeChromeBookmarks(home, profile: "Profile 10", bar: [chromeNode("P10", "https://p10.com/")])
        #expect(try ChromeReader.bookmarks(home: home.url).map(\.url.host) == ["p2.com"])
    }

    @Test func defaultWinsOverNumberedProfiles() throws {
        let home = FakeHome()
        writeChromeBookmarks(home, profile: "Profile 1", bar: [chromeNode("P1", "https://p1.com/")])
        writeChromeBookmarks(home, bar: [chromeNode("D", "https://d.com/")])
        #expect(try ChromeReader.bookmarks(home: home.url).map(\.url.host) == ["d.com"])
    }
}

// MARK: - Failures

@MainActor @Suite struct Failing {
    @Test func missingFilesAreNotFound() async {
        let home = FakeHome()
        for source in ImportSource.allCases {
            #expect(!ImportService.isInstalled(source, home: home.url))
            let f = await failure { try await ImportService.run(source, bookmarks: true, history: true, into: makeStore(), identity: SiteIdentity(), home: home.url) }
            #expect(f?.kind == .notFound)
            #expect(f?.message.isEmpty == false)
        }
        // Folder exists but no files.
        home.dir(home.safari)
        #expect(ImportService.isInstalled(.safari, home: home.url))
        let f = await failure { try await ImportService.run(.safari, bookmarks: true, history: true, into: makeStore(), identity: SiteIdentity(), home: home.url) }
        #expect(f?.kind == .notFound)
        #expect(f?.message.hasPrefix("Safari's") == true)
    }

    @Test func garbageIsUnreadable() async throws {
        let home = FakeHome()
        home.dir(home.safari)
        try Data("not a plist".utf8).write(to: home.safari.appendingPathComponent("Bookmarks.plist"))
        try Data("definitely not sqlite, just some text padding".utf8).write(to: home.safari.appendingPathComponent("History.db"))
        for (b, h) in [(true, false), (false, true), (true, true)] {
            let f = await failure { try await ImportService.run(.safari, bookmarks: b, history: h, into: makeStore(), identity: SiteIdentity(), home: home.url) }
            #expect(f?.kind == .unreadable)
        }
        writeChromeBookmarks(home)
        try Data("{not json".utf8).write(to: home.chrome.appendingPathComponent("Default/Bookmarks"))
        try Data("garbage garbage garbage garbage".utf8).write(to: home.chrome.appendingPathComponent("Default/History"))
        for (b, h) in [(true, false), (false, true)] {
            let f = await failure { try await ImportService.run(.chrome, bookmarks: b, history: h, into: makeStore(), identity: SiteIdentity(), home: home.url) }
            #expect(f?.kind == .unreadable)
        }
    }

    @Test func wrongSchemaIsUnreadable() async {
        let home = FakeHome()
        home.dir(home.safari)
        makeSQLite(home.safari.appendingPathComponent("History.db"), ["CREATE TABLE other (a)"])
        let f = await failure { try await ImportService.run(.safari, bookmarks: false, history: true, into: makeStore(), identity: SiteIdentity(), home: home.url) }
        #expect(f?.kind == .unreadable)
    }

    @Test func permissionDenied() async {
        let home = FakeHome()
        writeSafariPlist(home, [leaf("https://a.com/", "A")])
        writeSafariHistory(home, [("https://a.com/", "A", 700_000_000)])
        chmod(home.safari.path, 0o000)
        #expect(ImportService.isInstalled(.safari, home: home.url))
        for (b, h) in [(true, false), (false, true), (true, true)] {
            let f = await failure { try await ImportService.run(.safari, bookmarks: b, history: h, into: makeStore(), identity: SiteIdentity(), home: home.url) }
            #expect(f?.kind == .permissionDenied)
            #expect(f?.message.contains("Full Disk Access") == true)
        }
        chmod(home.chrome.path, 0o000) // does not exist: stays not found
        chmod(home.safari.path, 0o755)
    }

    @Test func chromePermissionDenied() async {
        let home = FakeHome()
        writeChromeBookmarks(home, bar: [chromeNode("A", "https://a.com/")])
        chmod(home.chrome.appendingPathComponent("Default").path, 0o000)
        let f = await failure { try await ImportService.run(.chrome, bookmarks: true, history: false, into: makeStore(), identity: SiteIdentity(), home: home.url) }
        #expect(f?.kind == .permissionDenied)
        chmod(home.chrome.appendingPathComponent("Default").path, 0o755)
    }
}

// MARK: - End to end

@MainActor @Suite struct EndToEnd {
    @Test func safariBookmarksAndHistory() async throws {
        let home = FakeHome()
        writeSafariPlist(home, [folder("Bar", [leaf("https://a.com/one", "One"), leaf("https://a.com/two", "Two"), leaf("https://a.com/one", "One again"), leaf("https://b.com/", "B")])])
        writeSafariHistory(home, [("https://a.com/one", "One", 700_000_000), ("https://b.com/", "B", 700_000_100), ("https://a.com/one", "One", 700_000_000)])
        let store = makeStore()
        let report = try await ImportService.run(.safari, bookmarks: true, history: true, into: store, identity: SiteIdentity(), home: home.url)
        #expect(report.bookmarksImported == 3)
        #expect(report.historyImported == 2)
        #expect(report.notes.contains { $0.contains("Bookmark folders aren't kept") })
        #expect(report.notes.contains { $0.contains("1 bookmark was skipped") })
        #expect(store.shelf.count == 2)
        #expect(store.shelf.first { $0.key.host == "a.com" }?.pages.count == 2)
        #expect(store.history.map(\.url.host) == ["b.com", "a.com"])
        #expect(store.history[0].dwell == 0)
        #expect(store.checkInvariants().isEmpty)

        // Running again adds nothing.
        let again = try await ImportService.run(.safari, bookmarks: true, history: true, into: store, identity: SiteIdentity(), home: home.url)
        #expect(again.bookmarksImported == 0 && again.historyImported == 0)
        #expect(store.shelf.count == 2 && store.history.count == 2)
        #expect(store.checkInvariants().isEmpty)
    }

    @Test func skipsOpenPinnedAndShelvedAndMergesIntoExistingEntry() async throws {
        let home = FakeHome()
        writeChromeBookmarks(home, bar: [chromeNode("Open", "https://open.com/x"), chromeNode("New", "https://open.com/y"), chromeNode("New2", "https://fresh.com/")])
        let store = makeStore()
        let w = store.createWindow()
        _ = store.openPage(url: URL(string: "https://open.com/x")!, in: w)
        let report = try await ImportService.run(.chrome, bookmarks: true, history: false, into: store, identity: SiteIdentity(), home: home.url)
        #expect(report.bookmarksImported == 2)
        #expect(store.shelf.map(\.key.host).sorted() == ["fresh.com", "open.com"])
        #expect(store.checkInvariants().isEmpty)
        // A second source for an existing shelf entry merges into it.
        #expect(store.importBookmarks([(title: "Z", url: URL(string: "https://fresh.com/z")!)]) == 1)
        #expect(store.shelf.count == 2)
        #expect(store.shelf.first { $0.key.host == "fresh.com" }?.pages.count == 2)
        #expect(store.checkInvariants().isEmpty)
    }

    @Test func historyMergesNewestFirstWithoutDuplicates() {
        let store = makeStore()
        let t = Date(timeIntervalSinceReferenceDate: 700_000_000)
        #expect(store.importHistory([(title: "A", url: URL(string: "https://a.com/")!, date: t)]) == 1)
        let n = store.importHistory([
            (title: "A", url: URL(string: "https://a.com/")!, date: t),
            (title: "Old", url: URL(string: "https://o.com/")!, date: t - 1000),
            (title: "New", url: URL(string: "https://n.com/")!, date: t + 1000),
            (title: "Mail", url: URL(string: "mailto:x@y.com")!, date: t),
        ])
        #expect(n == 2)
        #expect(store.history.map(\.title) == ["New", "A", "Old"])
        #expect(store.history.allSatisfy { $0.dwell == 0 })
        #expect(store.checkInvariants().isEmpty)
    }

    @Test func titleFallsBackToHost() {
        let store = makeStore()
        store.importHistory([(title: "", url: URL(string: "https://example.com/")!, date: Date())])
        #expect(store.history[0].title == "example.com")
        store.importBookmarks([(title: "  ", url: URL(string: "https://example.org/")!)])
        #expect(!store.shelf[0].pages[0].name.isEmpty)
        #expect(store.checkInvariants().isEmpty)
    }

    @Test func historyCapKeepsNewest() async throws {
        let home = FakeHome()
        let total = 20_050
        writeSafariHistory(home, (0..<total).map { ("https://site\($0 % 50).com/p\($0)", "T\($0)", 700_000_000 + Double($0)) })
        let store = makeStore()
        let report = try await ImportService.run(.safari, bookmarks: false, history: true, into: store, identity: SiteIdentity(), home: home.url)
        #expect(report.historyImported == 20_000)
        #expect(store.history.count == 20_000)
        #expect(store.history.first?.visitedAt == Date(timeIntervalSinceReferenceDate: 700_000_000 + Double(total - 1)))
        #expect(report.notes.contains { $0.contains("newest") })
        #expect(store.checkInvariants().isEmpty)
    }

    @Test func bookmarkCap() async throws {
        let home = FakeHome()
        writeChromeBookmarks(home, bar: (0..<650).map { chromeNode("B\($0)", "https://s\($0 % 7).com/p\($0)") })
        let store = makeStore()
        let report = try await ImportService.run(.chrome, bookmarks: true, history: false, into: store, identity: SiteIdentity(), home: home.url)
        #expect(report.bookmarksImported == 500)
        #expect(report.notes.contains { $0.contains("only the first 500") && $0.contains("150 more") })
        #expect(store.shelf.flatMap(\.pages).count == 500)
        #expect(store.checkInvariants().isEmpty)
    }

    @Test func oneSideMissingBecomesANote() async throws {
        let home = FakeHome()
        writeChromeBookmarks(home, bar: [chromeNode("A", "https://a.com/")])
        let store = makeStore()
        let report = try await ImportService.run(.chrome, bookmarks: true, history: true, into: store, identity: SiteIdentity(), home: home.url)
        #expect(report.bookmarksImported == 1 && report.historyImported == 0)
        #expect(report.notes.contains { $0.hasPrefix("History wasn't imported.") })
    }
}
