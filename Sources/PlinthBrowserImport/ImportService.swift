import Foundation
import PlinthModel
import PlinthRules
import PlinthStore

/// Bookmark and history import from the other browsers on this Mac, as in the Mac app's Settings ▸ Import.
public enum ImportService {
    /// True when the browser's data folder exists (it can still be unreadable: see `permissionDenied`).
    public static func isInstalled(_ source: ImportSource, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let folder = source == .arc ? ArcReader.folder(home) : source.dataFolder(home: home)
        // A folder macOS won't let us look inside still exists.
        return Probe.state(folder) != .missing
    }

    /// Every browser whose data is on this Mac, in the order Settings lists them.
    public static func installedSources(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [ImportSource] {
        ImportSource.supported.filter { isInstalled($0, home: home) }
    }

    /// The profiles Plinth would read for `source`, named as the browser names them. Safari has none.
    public static func profiles(_ source: ImportSource, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [BrowserProfile] {
        switch source.family {
        case .safari: return []
        case .chromium: return ChromiumProfiles.discover(source, home: home)
        case .firefox:
            return FirefoxProfiles.primary(root: source.dataFolder(home: home)).map {
                [BrowserProfile(folderName: $0.lastPathComponent, name: $0.lastPathComponent, folder: $0)]
            } ?? []
        }
    }

    /// Reads bookmarks and/or history from `source` and adds them to the stores. Bookmarks go to
    /// `bookmarkStore` with their folders, under a folder named for the browser. Never throws anything
    /// but `ImportFailure` and never crashes on missing, locked or malformed files.
    @MainActor
    public static func run(_ source: ImportSource, bookmarks: Bool, history: Bool, into store: BrowserStore,
                           bookmarkStore: BookmarkStore,
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

        if bookmarks, read.bookmarkFailure == nil {
            let root = folderName(for: source)
            let result = bookmarkStore.importItems(read.bookmarks.map { (title: $0.title, url: $0.url, folder: $0.folder) }, under: root)
            report.bookmarksImported = result.added
            if read.bookmarks.isEmpty {
                report.notes.append("\(source.displayName) had no bookmarks to import.")
            } else {
                if result.added > 0 {
                    report.notes.append("Bookmarks were added to Bookmarks, in a folder named \"\(root)\" with their own folders.")
                }
                if source == .arc {
                    report.notes.append("Arc has no bookmarks file, so Plinth imported the tabs saved in Arc's sidebar.")
                }
                if source == .zen {
                    report.notes.append("Zen's pinned tabs and Essentials aren't imported; only its bookmarks are.")
                }
                if source.family == .chromium, profiles(source, home: home).count > 1 {
                    report.notes.append("Each \(source.displayName) profile's bookmarks are in a folder named for the profile.")
                }
                if result.alreadySaved > 0 {
                    report.notes.append("\(result.alreadySaved) bookmark\(result.alreadySaved == 1 ? " was" : "s were") skipped because the page is already bookmarked, or was listed twice.")
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

    /// The top-level bookmark folder an import goes into, e.g. "Imported from Brave".
    public static func folderName(for source: ImportSource) -> String { "Imported from \(source.displayName)" }

    static func readBookmarks(_ source: ImportSource, home: URL) throws(ImportFailure) -> [ImportedBookmark] {
        switch source.family {
        case .safari: try SafariReader.bookmarks(home: home)
        case .chromium:
            if source == .arc { try ArcReader.bookmarks(home: home) } else { try ChromiumReader.bookmarks(source, home: home) }
        case .firefox: try FirefoxReader.bookmarks(source, home: home)
        }
    }

    static func readHistory(_ source: ImportSource, home: URL, limit: Int) throws(ImportFailure) -> [ImportedVisit] {
        switch source.family {
        case .safari: try SafariReader.history(home: home, limit: limit)
        case .chromium: try ChromiumReader.history(source, home: home, limit: limit)
        case .firefox: try FirefoxReader.history(source, home: home, limit: limit)
        }
    }

    private struct ReadResult: Sendable {
        var bookmarks: [ImportedBookmark] = []
        var visits: [ImportedVisit] = []
        var bookmarkFailure: ImportFailure?
        var historyFailure: ImportFailure?
    }
}
