import Foundation
import Testing
import PlinthModel
import PlinthRules
@testable import PlinthImport

private func writeArcSidebar(_ home: FakeHome, tabs: [(String, String?)]) {
    let dir = home.url.appendingPathComponent("Library/Application Support/Arc")
    home.dir(dir)
    var items: [[String: Any]] = [["id": "c", "data": ["itemContainer": ["containerType": "x"]], "title": NSNull()]]
    for (i, t) in tabs.enumerated() {
        var tab: [String: Any] = ["savedURL": t.0]
        if let title = t.1 { tab["savedTitle"] = title }
        items.append(["id": "t\(i)", "title": "item \(i)", "data": ["tab": tab]])
    }
    let doc: [String: Any] = ["version": 1, "sidebar": ["containers": [["global": [:]], ["items": items]]]]
    try! JSONSerialization.data(withJSONObject: doc).write(to: dir.appendingPathComponent("StorableSidebar.json"))
}

private func writeArcHistory(_ home: FakeHome, _ rows: [(String, String?, Double)]) {
    let dir = home.url.appendingPathComponent("Library/Application Support/Arc/User Data/Default")
    home.dir(dir)
    var sql = ["CREATE TABLE urls (id INTEGER PRIMARY KEY, url TEXT, title TEXT, last_visit_time INTEGER)",
               "CREATE TABLE visits (id INTEGER PRIMARY KEY, url INTEGER, visit_time INTEGER)"]
    for (i, r) in rows.enumerated() {
        sql.append("INSERT INTO urls VALUES (\(i + 1), '\(r.0)', \(r.1.map { "'\($0)'" } ?? "NULL"), 0)")
        sql.append("INSERT INTO visits VALUES (\(i + 1), \(i + 1), \(Int64((r.2 + 11_644_473_600) * 1_000_000)))")
    }
    makeSQLite(dir.appendingPathComponent("History"), sql)
}

private func writeZen(_ home: FakeHome, profile: String = "abc.Default (release)", ini: Bool = true,
                      bookmarks: [(String, String)], history: [(String, String?, Double)]) {
    let root = home.url.appendingPathComponent("Library/Application Support/zen")
    let dir = root.appendingPathComponent("Profiles/\(profile)")
    home.dir(dir)
    if ini {
        try! "[Profile0]\nName=x\nIsRelative=1\nPath=Profiles/\(profile)\nDefault=1\n".write(to: root.appendingPathComponent("profiles.ini"), atomically: true, encoding: .utf8)
    }
    var sql = ["CREATE TABLE moz_places (id INTEGER PRIMARY KEY, url TEXT, title TEXT)",
               "CREATE TABLE moz_historyvisits (id INTEGER PRIMARY KEY, place_id INTEGER, visit_date INTEGER)",
               "CREATE TABLE moz_bookmarks (id INTEGER PRIMARY KEY, type INTEGER, fk INTEGER, title TEXT, dateAdded INTEGER, parent INTEGER)"]
    var place = 0
    for b in bookmarks {
        place += 1
        sql.append("INSERT INTO moz_places VALUES (\(place), '\(b.0)', '\(b.1)')")
        sql.append("INSERT INTO moz_bookmarks VALUES (\(place), 1, \(place), '\(b.1)', \(place), 5002)")
    }
    // A root, the toolbar under it, and a folder in the toolbar that holds the bookmarks.
    sql.append("INSERT INTO moz_bookmarks VALUES (5000, 2, NULL, '', 0, 0)")
    sql.append("INSERT INTO moz_bookmarks VALUES (5001, 2, NULL, 'toolbar', 0, 5000)")
    sql.append("INSERT INTO moz_bookmarks VALUES (5002, 2, NULL, 'a folder', 0, 5001)")
    for h in history {
        place += 1
        sql.append("INSERT INTO moz_places VALUES (\(place), '\(h.0)', \(h.1.map { "'\($0)'" } ?? "NULL"))")
        sql.append("INSERT INTO moz_historyvisits VALUES (\(place), \(place), \(Int64(h.2 * 1_000_000)))")
    }
    makeSQLite(dir.appendingPathComponent("places.sqlite"), sql)
}

@Suite struct ArcParsing {
    @Test func sidebarTabsBecomeBookmarks() throws {
        let home = FakeHome()
        writeArcSidebar(home, tabs: [("https://a.com/", "A"), ("chrome://x", "x"), ("https://b.com/", nil)])
        let items = try ArcReader.bookmarks(home: home.url)
        #expect(items.map(\.url.host) == ["a.com", "b.com"])
        #expect(items[0].title == "A")
        #expect(items[1].title == "item 2")
    }

    @Test func historyUsesChromiumFormat() throws {
        let home = FakeHome()
        writeArcHistory(home, [("https://a.com/", "A", 1_700_000_000), ("https://b.com/", nil, 1_700_000_100)])
        let visits = try ChromeReader.history(home: home.url, limit: 10, source: .arc)
        #expect(visits.map(\.url.host) == ["b.com", "a.com"])
        #expect(visits[1].date == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test func missingAndGarbage() throws {
        let home = FakeHome()
        #expect(!ImportService.isInstalled(.arc, home: home.url))
        #expect(throws: ImportFailure.self) { try ArcReader.bookmarks(home: home.url) }
        let dir = home.url.appendingPathComponent("Library/Application Support/Arc")
        home.dir(dir)
        try Data("nope".utf8).write(to: dir.appendingPathComponent("StorableSidebar.json"))
        #expect(ImportService.isInstalled(.arc, home: home.url))
        do { _ = try ArcReader.bookmarks(home: home.url); Issue.record("expected failure") }
        catch let f { #expect(f.kind == .unreadable) }
    }

    @MainActor @Test func endToEnd() async throws {
        let home = FakeHome()
        writeArcSidebar(home, tabs: [("https://a.com/", "A")])
        writeArcHistory(home, [("https://b.com/", "B", 1_700_000_000)])
        let store = makeStore()
        let report = try await ImportService.run(.arc, bookmarks: true, history: true, into: store, identity: SiteIdentity(), home: home.url)
        #expect(report.bookmarksImported == 1)
        #expect(report.historyImported == 1)
        #expect(report.notes.contains { $0.contains("sidebar") })
        #expect(store.checkInvariants().isEmpty)
    }
}

@Suite struct ZenParsing {
    @Test func bookmarksAndHistory() throws {
        let home = FakeHome()
        writeZen(home, bookmarks: [("https://a.com/", "A"), ("place:parent=1", "Smart")],
                 history: [("https://b.com/", "B", 1_700_000_000), ("about:blank", "x", 1_700_000_100)])
        let marks = try ZenReader.bookmarks(home: home.url)
        #expect(marks.map(\.url.host) == ["a.com"])
        #expect(marks[0].folder == ["Bookmarks Toolbar", "a folder"])
        let visits = try ZenReader.history(home: home.url, limit: 10)
        #expect(visits.map(\.url.host) == ["b.com"])
        #expect(visits[0].date == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test func profilesIniChoosesTheDefaultProfile() throws {
        let home = FakeHome()
        writeZen(home, profile: "one.Other", ini: false, bookmarks: [("https://other.com/", "O")], history: [])
        writeZen(home, profile: "two.Default", ini: true, bookmarks: [("https://main.com/", "M")], history: [])
        #expect(try ZenReader.bookmarks(home: home.url).map(\.url.host) == ["main.com"])
    }

    @Test func fallsBackToAnyProfileWithoutIni() throws {
        let home = FakeHome()
        writeZen(home, ini: false, bookmarks: [("https://a.com/", "A")], history: [])
        #expect(try ZenReader.bookmarks(home: home.url).count == 1)
    }

    @Test func missingAndGarbage() throws {
        let home = FakeHome()
        #expect(!ImportService.isInstalled(.zen, home: home.url))
        do { _ = try ZenReader.history(home: home.url, limit: 5); Issue.record("expected failure") }
        catch let f { #expect(f.kind == .notFound) }
        let dir = home.url.appendingPathComponent("Library/Application Support/zen/Profiles/p")
        home.dir(dir)
        try Data("not sqlite".utf8).write(to: dir.appendingPathComponent("places.sqlite"))
        do { _ = try ZenReader.bookmarks(home: home.url); Issue.record("expected failure") }
        catch let f { #expect(f.kind == .unreadable) }
    }

    @MainActor @Test func endToEnd() async throws {
        let home = FakeHome()
        writeZen(home, bookmarks: [("https://a.com/", "A")], history: [("https://b.com/", "B", 1_700_000_000)])
        let store = makeStore()
        let report = try await ImportService.run(.zen, bookmarks: true, history: true, into: store, identity: SiteIdentity(), home: home.url)
        #expect(report.bookmarksImported == 1 && report.historyImported == 1)
        #expect(report.notes.contains { $0.contains("pinned tabs") })
        #expect(store.checkInvariants().isEmpty)
    }
}
