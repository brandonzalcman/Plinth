import Foundation
import SQLite3

enum ChromeReader {
    /// Chrome's data folder, or Arc's `User Data` folder (Arc is built on Chromium and keeps its history the same way).
    static func folder(_ home: URL, source: ImportSource = .chrome) -> URL {
        let path = source == .arc ? "Library/Application Support/Arc/User Data" : "Library/Application Support/Google/Chrome"
        return home.appendingPathComponent(path, isDirectory: true)
    }

    /// "Default" if it has the file, else the first "Profile N" (in numeric order) that does.
    static func profileFile(_ name: String, home: URL, source: ImportSource = .chrome) -> URL? {
        let root = folder(home, source: source)
        let first = root.appendingPathComponent("Default/\(name)")
        if Probe.state(first) != .missing { return first }
        let profiles = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
            .filter { $0.hasPrefix("Profile ") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        for p in profiles {
            let url = root.appendingPathComponent("\(p)/\(name)")
            if Probe.state(url) != .missing { return url }
        }
        return nil
    }

    static func bookmarks(home: URL) throws(ImportFailure) -> [ImportedBookmark] {
        guard let file = profileFile("Bookmarks", home: home) else {
            if Probe.state(folder(home)) == .denied { throw Failures.denied(.chrome) }
            throw Failures.notFound(.chrome, "bookmarks")
        }
        return try parseBookmarks(try readFile(file, source: .chrome, what: "bookmarks"))
    }

    static func parseBookmarks(_ data: Data) throws(ImportFailure) -> [ImportedBookmark] {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let roots = json["roots"] as? [String: Any] else { throw Failures.unreadable(.chrome, "bookmarks") }
        var out: [ImportedBookmark] = []
        for name in ["bookmark_bar", "other", "synced"] {
            if let node = roots[name] as? [String: Any] { walk(node, path: [], into: &out) }
        }
        return out
    }

    private static func walk(_ node: [String: Any], path: [String], into out: inout [ImportedBookmark]) {
        if node["type"] as? String == "url" {
            if let s = node["url"] as? String, let url = httpURL(s) { out.append(ImportedBookmark(title: node["name"] as? String ?? "", url: url, folder: path)) }
            return
        }
        var inner = path
        if let name = node["name"] as? String, !name.isEmpty { inner.append(name) }
        for case let child as [String: Any] in (node["children"] as? [Any]) ?? [] { walk(child, path: inner, into: &out) }
    }

    /// Microseconds since 1601-01-01 to a date.
    static func date(chromeTime t: Int64) -> Date {
        Date(timeIntervalSince1970: Double(t) / 1_000_000 - 11_644_473_600)
    }

    static func history(home: URL, limit: Int, source: ImportSource = .chrome) throws(ImportFailure) -> [ImportedVisit] {
        guard let file = profileFile("History", home: home, source: source) else {
            if Probe.state(folder(home, source: source)) == .denied { throw Failures.denied(source) }
            throw Failures.notFound(source, "history")
        }
        return try withDatabaseCopy(file, source: source, what: "history") { db throws(ImportFailure) in
            var out: [ImportedVisit] = []
            try query(db, """
                SELECT u.url, u.title, v.visit_time FROM visits v JOIN urls u ON u.id = v.url
                ORDER BY v.visit_time DESC LIMIT \(limit)
                """, source: source, what: "history") { row in
                guard let url = httpURL(text(row, 0)) else { return }
                out.append(ImportedVisit(title: text(row, 1), url: url, date: date(chromeTime: sqlite3_column_int64(row, 2))))
            }
            return out
        }
    }
}
