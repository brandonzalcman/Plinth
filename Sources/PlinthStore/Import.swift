import Foundation
import PlinthModel

/// What `importBookmarks` did with the items it was given.
public struct BookmarkImportOutcome: Sendable, Equatable {
    public var added = 0
    /// Already open, pinned, shelved, or repeated in the import.
    public var alreadyThere = 0
    /// Left out because the shelf cap for one import was reached.
    public var overCap = 0
    public init() {}
}

extension BrowserStore {
    /// The most bookmark pages one import adds to the shelf.
    public static let importBookmarkCap = 500
    /// The most history entries the store keeps (an import keeps the newest).
    public static var importHistoryCap: Int { historyCap }

    /// Adds visits from another browser to history: merged by time, newest first, duplicates
    /// (same URL and the same second) skipped, trimmed to the history cap. Returns how many
    /// entries were added and survived the cap. Only http and https URLs are taken.
    @discardableResult
    public func importHistory(_ visits: [(title: String, url: URL, date: Date)]) -> Int {
        struct Slot: Hashable { var url: URL; var second: Int64 }
        func slot(_ url: URL, _ date: Date) -> Slot { Slot(url: url, second: Int64(date.timeIntervalSinceReferenceDate.rounded(.down))) }

        var seen = Set(history.map { slot($0.url, $0.visitedAt) })
        var fresh: [HistoryEntry] = []
        for v in visits {
            guard let scheme = v.url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { continue }
            guard seen.insert(slot(v.url, v.date)).inserted else { continue }
            let key = identity.key(for: v.url)
            let title = v.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let shown = title.isEmpty ? (v.url.host ?? v.url.absoluteString) : title
            let name = namer.name(title: shown, url: v.url, siteName: identity.siteName(for: key))
            fresh.append(HistoryEntry(url: v.url, title: shown, name: name.isEmpty ? shown : name, key: key,
                                      visitedAt: v.date, dwell: 0))
        }
        guard !fresh.isEmpty else { return 0 }
        let freshIDs = Set(fresh.map(\.id))
        history = (history + fresh).sorted { $0.visitedAt > $1.visitedAt }
        if history.count > Self.historyCap { history.removeLast(history.count - Self.historyCap) }
        let alive = Set(history.map(\.id))
        latestHistory = latestHistory.filter { alive.contains($0.value) }
        commit()
        return freshIDs.intersection(alive).count
    }

    /// Puts bookmarks on the shelf, grouped by site (one shelf entry per site key; an existing
    /// entry gets the pages added at its end). Skips pages that are already open, pinned or
    /// shelved, and stops after `importBookmarkCap` pages. Returns how many were added.
    @discardableResult
    public func importBookmarks(_ items: [(title: String, url: URL)]) -> Int {
        importBookmarksDetailed(items).added
    }

    public func importBookmarksDetailed(_ items: [(title: String, url: URL)]) -> BookmarkImportOutcome {
        var outcome = BookmarkImportOutcome()
        var known = Set<URL>()
        for pin in pins { known.insert(pin.page.url); known.insert(pin.homeURL) }
        for w in windows { for site in w.sites { for p in site.pages { known.insert(p.url) } } }
        for entry in shelf { for p in entry.pages { known.insert(p.url) } }

        let t = now()
        for item in items {
            guard let scheme = item.url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { continue }
            guard known.insert(item.url).inserted else { outcome.alreadyThere += 1; continue }
            guard outcome.added < Self.importBookmarkCap else { outcome.overCap += 1; continue }
            let key = identity.key(for: item.url)
            let siteName = shelf.first(where: { $0.key == key })?.name ?? identity.siteName(for: key)
            let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            var page = Page(url: item.url, rawTitle: title.isEmpty ? (item.url.host ?? "") : title, name: "", usage: Usage(at: t))
            page.name = displayName(page, siteName: siteName)
            if let i = shelf.firstIndex(where: { $0.key == key }) {
                shelf[i].pages.append(page)
            } else {
                shelf.append(ShelfEntry(key: key, name: siteName, pages: [page], shelvedAt: t))
            }
            outcome.added += 1
        }
        if outcome.added > 0 { commit() }
        return outcome
    }
}
