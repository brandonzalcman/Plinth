import Foundation
import SQLite3

enum SafariReader {
    static func folder(_ home: URL) -> URL { home.appendingPathComponent("Library/Safari", isDirectory: true) }

    static func bookmarks(home: URL) throws(ImportFailure) -> [ImportedBookmark] {
        let data = try readFile(folder(home).appendingPathComponent("Bookmarks.plist"), source: .safari, what: "bookmarks")
        return try parseBookmarks(data)
    }

    static func parseBookmarks(_ data: Data) throws(ImportFailure) -> [ImportedBookmark] {
        guard let root = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any] else {
            throw Failures.unreadable(.safari, "bookmarks")
        }
        var out: [ImportedBookmark] = []
        walk(root, into: &out)
        return out
    }

    private static func walk(_ node: [String: Any], into out: inout [ImportedBookmark]) {
        if node["Title"] as? String == "com.apple.ReadingList" { return }
        switch node["WebBookmarkType"] as? String {
        case "WebBookmarkTypeLeaf":
            guard let s = node["URLString"] as? String, let url = httpURL(s) else { return }
            let title = ((node["URIDictionary"] as? [String: Any])?["title"] as? String) ?? ""
            out.append(ImportedBookmark(title: title, url: url))
            return
        case "WebBookmarkTypeProxy":
            return
        default:
            break
        }
        for case let child as [String: Any] in (node["Children"] as? [Any]) ?? [] { walk(child, into: &out) }
    }

    /// Newest first, at most `limit` visits.
    static func history(home: URL, limit: Int) throws(ImportFailure) -> [ImportedVisit] {
        try withDatabaseCopy(folder(home).appendingPathComponent("History.db"), source: .safari, what: "history") { db throws(ImportFailure) in
            var out: [ImportedVisit] = []
            try query(db, """
                SELECT i.url, v.title, v.visit_time FROM history_visits v JOIN history_items i ON i.id = v.history_item
                ORDER BY v.visit_time DESC LIMIT \(limit)
                """, source: .safari, what: "history") { row in
                guard let url = httpURL(text(row, 0)) else { return }
                out.append(ImportedVisit(title: text(row, 1), url: url, date: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(row, 2))))
            }
            return out
        }
    }
}
