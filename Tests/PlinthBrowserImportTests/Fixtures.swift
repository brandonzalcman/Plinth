import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import SwiftToolchainCSQLite
#endif
@testable import PlinthBrowserImport

// Every file here is made up in a temporary folder. Nothing reads a real profile or the real Keychain.

/// A fake home directory, removed when the value goes away.
final class FakeHome {
    let url: URL
    init() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("plinth-browser-import-test-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }

    func root(_ source: ImportSource) -> URL { source.dataFolder(home: url) }
    func dir(_ u: URL) { try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true) }
    func write(_ text: String, to u: URL) {
        dir(u.deletingLastPathComponent())
        try! text.write(to: u, atomically: true, encoding: .utf8)
    }
}

func makeSQLite(_ url: URL, _ statements: [String]) {
    try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    var db: OpaquePointer?
    precondition(sqlite3_open(url.path, &db) == SQLITE_OK)
    defer { sqlite3_close(db) }
    for s in statements { precondition(sqlite3_exec(db, s, nil, nil, nil) == SQLITE_OK, "\(s)") }
}

func hexLiteral(_ d: Data) -> String { "X'" + d.map { String(format: "%02x", $0) }.joined() + "'" }

// MARK: - Chromium family

func chromeNode(_ name: String, _ url: String) -> [String: Any] { ["type": "url", "name": name, "url": url] }
func chromeFolder(_ name: String, _ children: [[String: Any]]) -> [String: Any] { ["type": "folder", "name": name, "children": children] }

func writeChromiumBookmarks(_ profile: URL, bar: [[String: Any]] = [], other: [[String: Any]] = []) {
    try! FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
    let roots: [String: Any] = ["bookmark_bar": chromeFolder("Bookmarks bar", bar), "other": chromeFolder("Other bookmarks", other),
                                "synced": chromeFolder("Mobile bookmarks", [])]
    let data = try! JSONSerialization.data(withJSONObject: ["roots": roots, "version": 1])
    try! data.write(to: profile.appendingPathComponent("Bookmarks"))
}

/// Rows are (url, title, unix seconds).
func writeChromiumHistory(_ profile: URL, _ rows: [(String, String, Double)]) {
    var sql = ["CREATE TABLE urls (id INTEGER PRIMARY KEY, url TEXT, title TEXT, last_visit_time INTEGER)",
               "CREATE TABLE visits (id INTEGER PRIMARY KEY, url INTEGER, visit_time INTEGER)"]
    for (i, r) in rows.enumerated() {
        let t = Int64((r.2 + 11_644_473_600) * 1_000_000)
        sql.append("INSERT INTO urls VALUES (\(i + 1), '\(r.0)', '\(r.1)', \(t))")
        sql.append("INSERT INTO visits VALUES (\(i + 1), \(i + 1), \(t))")
    }
    makeSQLite(profile.appendingPathComponent("History"), sql)
}

func writeLocalState(_ root: URL, names: [String: String], order: [String]? = nil) {
    var profile: [String: Any] = ["info_cache": names.mapValues { ["name": $0] }]
    if let order { profile["profiles_order"] = order }
    try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try! JSONSerialization.data(withJSONObject: ["profile": profile]).write(to: root.appendingPathComponent("Local State"))
}

// MARK: - Firefox family

/// A places.sqlite with one folder and bookmarks under the toolbar, and visits (unix seconds).
func writePlaces(_ profile: URL, bookmarks: [(url: String, title: String)], visits: [(url: String, title: String, at: Double)]) {
    var sql = ["CREATE TABLE moz_places (id INTEGER PRIMARY KEY, url TEXT, title TEXT)",
               "CREATE TABLE moz_bookmarks (id INTEGER PRIMARY KEY, type INTEGER, fk INTEGER, parent INTEGER, title TEXT, dateAdded INTEGER)",
               "CREATE TABLE moz_historyvisits (id INTEGER PRIMARY KEY, place_id INTEGER, visit_date INTEGER)",
               "INSERT INTO moz_bookmarks VALUES (1, 2, NULL, 0, 'root', 0)",
               "INSERT INTO moz_bookmarks VALUES (2, 2, NULL, 1, 'toolbar', 0)",
               "INSERT INTO moz_bookmarks VALUES (3, 2, NULL, 2, 'Reading', 0)"]
    var place = 0
    for (i, b) in bookmarks.enumerated() {
        place += 1
        sql.append("INSERT INTO moz_places VALUES (\(place), '\(b.url)', '\(b.title)')")
        sql.append("INSERT INTO moz_bookmarks VALUES (\(10 + i), 1, \(place), \(i == 0 ? 2 : 3), '\(b.title)', \(i))")
    }
    for (i, v) in visits.enumerated() {
        place += 1
        sql.append("INSERT INTO moz_places VALUES (\(place), '\(v.url)', '\(v.title)')")
        sql.append("INSERT INTO moz_historyvisits VALUES (\(i + 1), \(place), \(Int64(v.at * 1_000_000)))")
    }
    makeSQLite(profile.appendingPathComponent("places.sqlite"), sql)
}
