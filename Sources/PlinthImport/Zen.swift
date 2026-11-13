import Foundation
import SQLite3

/// Zen is Firefox-based: bookmarks and history are in the profile's `places.sqlite`.
enum ZenReader {
    static func folder(_ home: URL) -> URL {
        home.appendingPathComponent("Library/Application Support/zen", isDirectory: true)
    }

    /// The profile Zen last used: the install's default in `profiles.ini`, else the one marked `Default=1`,
    /// else the first profile that has `places.sqlite`.
    static func placesFile(home: URL) -> URL? {
        let root = folder(home)
        var candidates: [String] = []
        if let text = try? String(contentsOf: root.appendingPathComponent("profiles.ini"), encoding: .utf8) {
            var section = ""
            var path: String?
            var isDefault = false
            var installDefault: String?
            var marked: [String] = []
            var all: [String] = []
            func flush() {
                if section.hasPrefix("Profile"), let path { all.append(path); if isDefault { marked.append(path) } }
            }
            for raw in text.split(whereSeparator: \.isNewline) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("[") { flush(); section = String(line.dropFirst().dropLast()); path = nil; isDefault = false; continue }
                guard let eq = line.firstIndex(of: "=") else { continue }
                let key = line[..<eq], value = String(line[line.index(after: eq)...])
                if section.hasPrefix("Install"), key == "Default", installDefault == nil { installDefault = value }
                if section.hasPrefix("Profile") {
                    if key == "Path" { path = value }
                    if key == "Default", value == "1" { isDefault = true }
                }
            }
            flush()
            candidates = [installDefault].compactMap { $0 } + marked + all
        }
        let profilesDir = root.appendingPathComponent("Profiles")
        candidates += ((try? FileManager.default.contentsOfDirectory(atPath: profilesDir.path)) ?? []).sorted().map { "Profiles/\($0)" }
        for path in candidates {
            let file = root.appendingPathComponent(path).appendingPathComponent("places.sqlite")
            if Probe.state(file) != .missing { return file }
        }
        return nil
    }

    private static func file(home: URL, what: String) throws(ImportFailure) -> URL {
        if let file = placesFile(home: home) { return file }
        if Probe.state(folder(home)) == .denied { throw Failures.denied(.zen) }
        throw Failures.notFound(.zen, what)
    }

    static func bookmarks(home: URL) throws(ImportFailure) -> [ImportedBookmark] {
        let file = try file(home: home, what: "bookmarks")
        return try withDatabaseCopy(file, source: .zen, what: "bookmarks") { db throws(ImportFailure) in
            var out: [ImportedBookmark] = []
            try query(db, """
                SELECT p.url, b.title FROM moz_bookmarks b JOIN moz_places p ON p.id = b.fk
                WHERE b.type = 1 ORDER BY b.dateAdded
                """, source: .zen, what: "bookmarks") { row in
                guard let url = httpURL(text(row, 0)) else { return }
                out.append(ImportedBookmark(title: text(row, 1), url: url))
            }
            return out
        }
    }

    /// Firefox visit times are microseconds since 1970.
    static func date(mozTime t: Int64) -> Date { Date(timeIntervalSince1970: Double(t) / 1_000_000) }

    static func history(home: URL, limit: Int) throws(ImportFailure) -> [ImportedVisit] {
        let file = try file(home: home, what: "history")
        return try withDatabaseCopy(file, source: .zen, what: "history") { db throws(ImportFailure) in
            var out: [ImportedVisit] = []
            try query(db, """
                SELECT p.url, p.title, v.visit_date FROM moz_historyvisits v JOIN moz_places p ON p.id = v.place_id
                ORDER BY v.visit_date DESC LIMIT \(limit)
                """, source: .zen, what: "history") { row in
                guard let url = httpURL(text(row, 0)) else { return }
                out.append(ImportedVisit(title: text(row, 1), url: url, date: date(mozTime: sqlite3_column_int64(row, 2))))
            }
            return out
        }
    }
}
