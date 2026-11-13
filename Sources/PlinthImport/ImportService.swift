import Foundation
import PlinthModel
import PlinthRules
import PlinthStore

// CONTRACT (the settings UI codes against this; the import agent implements it behind the same signatures).

public enum ImportSource: String, CaseIterable, Sendable {
    case safari, chrome, arc, zen
    public var displayName: String {
        switch self {
        case .safari: "Safari"
        case .chrome: "Chrome"
        case .arc: "Arc"
        case .zen: "Zen"
        }
    }
}

/// What an import did, in numbers and plain-language notes the UI shows as is.
public struct ImportReport: Sendable, Equatable {
    public var bookmarksImported = 0
    public var historyImported = 0
    /// e.g. "Bookmark folders aren't kept: Plinth has no folders, so bookmarks were added to the shelf by site."
    public var notes: [String] = []
    public init() {}
}

/// A failure with a message fit for the screen.
public struct ImportFailure: Error, Equatable, Sendable {
    public enum Kind: Sendable, Equatable { case notFound, permissionDenied, unreadable }
    public var kind: Kind
    public var message: String
    public init(kind: Kind, message: String) { self.kind = kind; self.message = message }
}

public enum ImportService {
    /// True when the browser's data folder exists (it can still be unreadable: see `permissionDenied`).
    public static func isInstalled(_ source: ImportSource, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let folder: URL
        switch source {
        case .safari: folder = SafariReader.folder(home)
        case .chrome: folder = ChromeReader.folder(home)
        case .arc: folder = ArcReader.folder(home)
        case .zen: folder = ZenReader.folder(home)
        }
        // A folder macOS won't let us look inside still exists.
        return Probe.state(folder) != .missing
    }

    /// Reads bookmarks and/or history from `source` and adds them to `store`. With `bookmarkStore`, bookmarks
    /// go there with their folders, under a folder named for the source; without it they go to the shelf. Never throws anything but `ImportFailure`
    /// and never crashes on missing, locked or malformed files.
    @MainActor
    public static func run(_ source: ImportSource, bookmarks: Bool, history: Bool, into store: BrowserStore,
                           identity: SiteIdentity, bookmarkStore: BookmarkStore? = nil,
                           home: URL = FileManager.default.homeDirectoryForCurrentUser) async throws -> ImportReport {
        let historyLimit = BrowserStore.importHistoryCap
        let read = await Task.detached { () -> ReadResult in
            var r = ReadResult()
            if bookmarks {
                do throws(ImportFailure) { r.bookmarks = try readBookmarks(source, home: home) }
                catch { r.bookmarkFailure = error }
            }
            if history {
                do throws(ImportFailure) { r.visits = try readHistory(source, home: home, limit: historyLimit) }
                catch { r.historyFailure = error }
            }
            return r
        }.value

        // Nothing readable at all: report why. One side failing becomes a note beside the other's success.
        let wanted = (bookmarks ? 1 : 0) + (history ? 1 : 0)
        let failures = [read.bookmarkFailure, read.historyFailure].compactMap { $0 }
        if wanted == 0 || failures.count == wanted {
            throw failures.first ?? ImportFailure(kind: .notFound, message: "Nothing was selected to import.")
        }

        var report = ImportReport()
        if let f = read.bookmarkFailure { report.notes.append("Bookmarks weren't imported. " + f.message) }
        if let f = read.historyFailure { report.notes.append("History wasn't imported. " + f.message) }

        if bookmarks, read.bookmarkFailure == nil, let bookmarkStore {
            let result = bookmarkStore.importItems(read.bookmarks.map { (title: $0.title, url: $0.url, folder: $0.folder) },
                                                   under: "Imported from \(source.displayName)")
            report.bookmarksImported = result.added
            if read.bookmarks.isEmpty {
                report.notes.append("\(source.displayName) had no bookmarks to import.")
            } else {
                if result.added > 0 {
                    report.notes.append("Bookmarks were added to Bookmarks, in a folder named \"Imported from \(source.displayName)\" with their own folders.")
                }
                if source == .arc {
                    report.notes.append("Arc has no bookmarks file, so Plinth imported the tabs saved in Arc's sidebar.")
                }
                if source == .zen {
                    report.notes.append("Zen's pinned tabs and Essentials aren't imported; only its bookmarks are.")
                }
                if result.alreadySaved > 0 {
                    report.notes.append("\(result.alreadySaved) bookmark\(result.alreadySaved == 1 ? " was" : "s were") skipped because the page is already bookmarked, or was listed twice.")
                }
            }
        } else if bookmarks, read.bookmarkFailure == nil {
            let outcome = store.importBookmarksDetailed(read.bookmarks.map { (title: $0.title, url: $0.url) })
            report.bookmarksImported = outcome.added
            if read.bookmarks.isEmpty {
                report.notes.append("\(source.displayName) had no bookmarks to import.")
            } else {
                if outcome.added > 0 {
                    report.notes.append("Bookmark folders aren't kept: Plinth has no folders, so bookmarks were added to the shelf, grouped by site.")
                }
                if source == .arc {
                    report.notes.append("Arc has no bookmarks file, so Plinth imported the tabs saved in Arc's sidebar.")
                }
                if source == .zen {
                    report.notes.append("Zen's pinned tabs and Essentials aren't imported; only its bookmarks are.")
                }
                if outcome.alreadyThere > 0 {
                    report.notes.append("\(outcome.alreadyThere) bookmark\(outcome.alreadyThere == 1 ? " was" : "s were") skipped because the page is already open, pinned or on the shelf, or was listed twice.")
                }
                if outcome.overCap > 0 {
                    report.notes.append("To keep the shelf manageable, only the first \(BrowserStore.importBookmarkCap) bookmarks were added; \(outcome.overCap) more were left out.")
                }
            }
        }

        if history, read.historyFailure == nil {
            let visits = read.visits.map { (title: $0.title, url: $0.url, date: $0.date) }
            report.historyImported = store.importHistory(visits)
            if read.visits.isEmpty {
                report.notes.append("\(source.displayName) had no history to import.")
            } else {
                let skipped = visits.count - report.historyImported
                if skipped > 0 {
                    report.notes.append("\(skipped) visit\(skipped == 1 ? " was" : "s were") skipped because Plinth already had \(skipped == 1 ? "it" : "them") or was over its limit.")
                }
                if visits.count >= historyLimit {
                    report.notes.append("Plinth keeps the newest \(historyLimit.formatted()) history entries, so older visits were left out.")
                }
            }
        }
        return report
    }

    private static func readBookmarks(_ source: ImportSource, home: URL) throws(ImportFailure) -> [ImportedBookmark] {
        switch source {
        case .safari: try SafariReader.bookmarks(home: home)
        case .chrome: try ChromeReader.bookmarks(home: home)
        case .arc: try ArcReader.bookmarks(home: home)
        case .zen: try ZenReader.bookmarks(home: home)
        }
    }

    private static func readHistory(_ source: ImportSource, home: URL, limit: Int) throws(ImportFailure) -> [ImportedVisit] {
        switch source {
        case .safari: try SafariReader.history(home: home, limit: limit)
        case .chrome: try ChromeReader.history(home: home, limit: limit)
        case .arc: try ChromeReader.history(home: home, limit: limit, source: .arc)
        case .zen: try ZenReader.history(home: home, limit: limit)
        }
    }

    private struct ReadResult: Sendable {
        var bookmarks: [ImportedBookmark] = []
        var visits: [ImportedVisit] = []
        var bookmarkFailure: ImportFailure?
        var historyFailure: ImportFailure?
    }
}
