import Foundation

/// Arc keeps its history like Chrome (see `ChromeReader`, source `.arc`) but has no bookmarks file:
/// its saved tabs live in the sidebar document `StorableSidebar.json`.
enum ArcReader {
    static func folder(_ home: URL) -> URL {
        home.appendingPathComponent("Library/Application Support/Arc", isDirectory: true)
    }

    static func bookmarks(home: URL) throws(ImportFailure) -> [ImportedBookmark] {
        let file = folder(home).appendingPathComponent("StorableSidebar.json")
        if Probe.state(file) == .missing, Probe.state(folder(home)) == .denied { throw Failures.denied(.arc) }
        return try parseSidebar(try readFile(file, source: .arc, what: "bookmarks"))
    }

    /// Every saved tab (`data.tab.savedURL`) in the sidebar's item list: pinned and sidebar tabs of every space.
    static func parseSidebar(_ data: Data) throws(ImportFailure) -> [ImportedBookmark] {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let sidebar = json["sidebar"] as? [String: Any],
              let containers = sidebar["containers"] as? [Any] else { throw Failures.unreadable(.arc, "bookmarks") }
        var out: [ImportedBookmark] = []
        for case let container as [String: Any] in containers {
            for case let item as [String: Any] in (container["items"] as? [Any]) ?? [] {
                guard let tab = (item["data"] as? [String: Any])?["tab"] as? [String: Any],
                      let s = tab["savedURL"] as? String, let url = httpURL(s) else { continue }
                let title = (tab["savedTitle"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (item["title"] as? String) ?? ""
                out.append(ImportedBookmark(title: title, url: url))
            }
        }
        return out
    }
}
