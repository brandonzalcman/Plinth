import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import SwiftToolchainCSQLite
#endif

/// Firefox and Zen: bookmarks and history are in the profile's `places.sqlite`. Only the profile the
/// browser last used is read, as on the Mac: Firefox keeps a spare, unused profile on most Macs.
enum FirefoxReader {
    static func placesFile(_ source: ImportSource, home: URL) -> URL? {
        FirefoxProfiles.primary(root: source.dataFolder(home: home)).map { $0.appendingPathComponent("places.sqlite") }
    }

    private static func file(_ source: ImportSource, home: URL, what: String) throws(ImportFailure) -> URL {
        if let file = placesFile(source, home: home) { return file }
        if Probe.state(source.dataFolder(home: home)) == .denied { throw Failures.denied(source) }
        throw Failures.notFound(source, what)
    }

    static func bookmarks(_ source: ImportSource, home: URL) throws(ImportFailure) -> [ImportedBookmark] {
        let file = try file(source, home: home, what: "bookmarks")
        return try withDatabaseCopy(file, source: source, what: "bookmarks") { db throws(ImportFailure) in
            // Folders (type 2) by id, so each bookmark's path can be walked up to the root.
            var folders: [Int64: (parent: Int64, title: String)] = [:]
            try query(db, "SELECT id, parent, title FROM moz_bookmarks WHERE type = 2", source: source, what: "bookmarks") { row in
                folders[sqlite3_column_int64(row, 0)] = (sqlite3_column_int64(row, 1), text(row, 2))
            }
            func path(from parent: Int64) -> [String] {
                var names: [String] = []
                var at = parent
                var steps = 0
                while let f = folders[at], f.parent != 0, steps < 64 { // the root (parent 0) is not a folder to show
                    names.insert(folderName(f.title), at: 0)
                    at = f.parent
                    steps += 1
                }
                return names
            }
            var out: [ImportedBookmark] = []
            try query(db, """
                SELECT p.url, b.title, b.parent FROM moz_bookmarks b JOIN moz_places p ON p.id = b.fk
                WHERE b.type = 1 ORDER BY b.dateAdded
                """, source: source, what: "bookmarks") { row in
                guard let url = httpURL(text(row, 0)) else { return }
                out.append(ImportedBookmark(title: text(row, 1), url: url, folder: path(from: sqlite3_column_int64(row, 2))))
            }
            return out
        }
    }

    /// Firefox's built-in folders have internal names.
    static func folderName(_ title: String) -> String {
        switch title {
        case "menu": "Bookmarks Menu"
        case "toolbar": "Bookmarks Toolbar"
        case "unfiled": "Other Bookmarks"
        case "mobile": "Mobile Bookmarks"
        default: title
        }
    }

    /// Firefox visit times are microseconds since 1970.
    static func date(mozTime t: Int64) -> Date { Date(timeIntervalSince1970: Double(t) / 1_000_000) }

    static func history(_ source: ImportSource, home: URL, limit: Int) throws(ImportFailure) -> [ImportedVisit] {
        let file = try file(source, home: home, what: "history")
        return try withDatabaseCopy(file, source: source, what: "history") { db throws(ImportFailure) in
            var out: [ImportedVisit] = []
            try query(db, """
                SELECT p.url, p.title, v.visit_date FROM moz_historyvisits v JOIN moz_places p ON p.id = v.place_id
                WHERE (p.url LIKE 'http://%' OR p.url LIKE 'https://%')
                ORDER BY v.visit_date DESC LIMIT \(limit)
                """, source: source, what: "history") { row in
                guard let url = httpURL(text(row, 0)) else { return }
                out.append(ImportedVisit(title: text(row, 1), url: url, date: date(mozTime: sqlite3_column_int64(row, 2))))
            }
            return out
        }
    }
}
