import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import SwiftToolchainCSQLite
#endif

/// Bookmarks and history from any Chromium-family browser (Chrome, Edge, Brave, Arc, Vivaldi, Opera,
/// Chromium). They all keep the same files in each profile folder; only where the folder is differs.
enum ChromiumReader {
    /// Bookmarks from every profile. With more than one profile, each profile's bookmarks sit in a
    /// folder named for it, so two people's bookmarks don't run together.
    static func bookmarks(_ source: ImportSource, home: URL) throws(ImportFailure) -> [ImportedBookmark] {
        let profiles = try profiles(source, home: home, file: "Bookmarks", what: "bookmarks")
        var out: [ImportedBookmark] = []
        var lastFailure: ImportFailure?
        for profile in profiles {
            do throws(ImportFailure) {
                let items = try parseBookmarks(try readFile(profile.folder.appendingPathComponent("Bookmarks"), source: source, what: "bookmarks"),
                                               source: source)
                out += profiles.count > 1 ? items.map { var b = $0; b.folder.insert(profile.name, at: 0); return b } : items
            } catch { lastFailure = error }
        }
        if out.isEmpty, let lastFailure { throw lastFailure }
        return out
    }

    static func parseBookmarks(_ data: Data, source: ImportSource = .chrome) throws(ImportFailure) -> [ImportedBookmark] {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let roots = json["roots"] as? [String: Any] else { throw Failures.unreadable(source, "bookmarks") }
        var out: [ImportedBookmark] = []
        // Vivaldi adds its speed dials to "bookmark_bar"; they are ordinary folders there.
        for name in ["bookmark_bar", "other", "synced", "custom_root"] {
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

    /// The newest `limit` visits across every profile, newest first.
    static func history(_ source: ImportSource, home: URL, limit: Int) throws(ImportFailure) -> [ImportedVisit] {
        let profiles = try profiles(source, home: home, file: "History", what: "history")
        var out: [ImportedVisit] = []
        var lastFailure: ImportFailure?
        for profile in profiles {
            do throws(ImportFailure) {
                out += try withDatabaseCopy(profile.folder.appendingPathComponent("History"), source: source, what: "history") { db throws(ImportFailure) in
                    var visits: [ImportedVisit] = []
                    try query(db, """
                        SELECT u.url, u.title, v.visit_time FROM visits v JOIN urls u ON u.id = v.url
                        WHERE (u.url LIKE 'http://%' OR u.url LIKE 'https://%')
                        ORDER BY v.visit_time DESC LIMIT \(limit)
                        """, source: source, what: "history") { row in
                        guard let url = httpURL(text(row, 0)) else { return }
                        visits.append(ImportedVisit(title: text(row, 1), url: url, date: date(chromeTime: sqlite3_column_int64(row, 2))))
                    }
                    return visits
                }
            } catch { lastFailure = error }
        }
        if out.isEmpty, let lastFailure { throw lastFailure }
        return Array(out.sorted { $0.date > $1.date }.prefix(limit))
    }

    /// The profiles that have `file`, or a failure that says why there are none.
    static func profiles(_ source: ImportSource, home: URL, file: String, what: String) throws(ImportFailure) -> [BrowserProfile] {
        let found = ChromiumProfiles.discover(source, home: home)
            .filter { Probe.state($0.folder.appendingPathComponent(file)) != .missing }
        if found.isEmpty {
            if Probe.state(source.dataFolder(home: home)) == .denied { throw Failures.denied(source) }
            throw Failures.notFound(source, what)
        }
        return found
    }
}
