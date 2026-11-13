import Foundation
import Observation
import PlinthModel

/// The on-disk form of the bookmarks: `bookmarks.json`, beside `state.json` and independent of it,
/// so a profile written before bookmarks existed simply has no such file.
struct BookmarkSnapshot: Codable {
    static let currentVersion = 1
    static let fileName = "bookmarks.json"

    var version: Int
    var folders: [BookmarkFolder]
    var bookmarks: [Bookmark]
}

/// What `BookmarkStore.add` did.
public enum BookmarkAddition: Sendable, Equatable {
    case added(Bookmark)
    /// The page was already saved (same canonical address); nothing changed.
    case existing(Bookmark)

    public var bookmark: Bookmark {
        switch self { case .added(let b), .existing(let b): b }
    }
}

/// Bookmarks and their folders. Global to the profile, not tied to a window. Order in the arrays
/// is the order shown inside a folder.
///
/// One address is saved once: two addresses that `URLCanonical` treats as the same page are one
/// bookmark. Deleting a folder keeps what was in it (it moves up a level), so nothing is lost
/// to a stray click.
@MainActor @Observable
public final class BookmarkStore {
    public private(set) var folders: [BookmarkFolder] = []
    public private(set) var bookmarks: [Bookmark] = []

    @ObservationIgnored private let storageDirectory: URL?
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored var autosaveDelay: Duration = .seconds(1)
    /// Where an unreadable bookmarks file was moved to during `init`, if that happened.
    @ObservationIgnored public private(set) var recoveredCorruptFile: URL?

    public init(storageDirectory: URL?, now: @escaping @Sendable () -> Date = { Date() }) {
        self.storageDirectory = storageDirectory
        self.now = now
        load()
    }

    // MARK: Reading

    public func bookmark(_ id: UUID) -> Bookmark? { bookmarks.first { $0.id == id } }
    public func folder(_ id: UUID) -> BookmarkFolder? { folders.first { $0.id == id } }

    /// The saved bookmark for a page, matching on canonical address.
    public func bookmark(for url: URL) -> Bookmark? {
        let key = URLCanonical.key(url)
        return bookmarks.first { URLCanonical.key($0.url) == key }
    }

    public func bookmarks(in folder: UUID?) -> [Bookmark] { bookmarks.filter { $0.folder == folder } }
    public func subfolders(of parent: UUID?) -> [BookmarkFolder] { folders.filter { $0.parent == parent } }

    /// Folder names from the top down, e.g. ["Reading", "Recipes"].
    public func path(of folder: UUID?) -> [String] {
        var names: [String] = []
        var current = folder
        var guardCount = 0
        while let id = current, let f = self.folder(id), guardCount < 64 {
            names.insert(f.name, at: 0)
            current = f.parent
            guardCount += 1
        }
        return names
    }

    // MARK: Bookmarks

    /// Saves a page. An address that is already saved is left as it is and reported as `.existing`.
    /// Only web addresses are kept. An empty title falls back to the address.
    @discardableResult
    public func add(title: String, url: URL, in folder: UUID? = nil) -> BookmarkAddition? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        if let existing = bookmark(for: url) { return .existing(existing) }
        let target = folder.flatMap { self.folder($0) != nil ? $0 : nil }
        let bookmark = Bookmark(title: Self.cleanTitle(title, url: url), url: url, folder: target, addedAt: now())
        bookmarks.append(bookmark)
        changed()
        return .added(bookmark)
    }

    public func remove(_ id: UUID) {
        guard bookmarks.contains(where: { $0.id == id }) else { return }
        bookmarks.removeAll { $0.id == id }
        changed()
    }

    /// An empty title is ignored.
    public func rename(_ id: UUID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = bookmarks.firstIndex(where: { $0.id == id }), bookmarks[i].title != trimmed else { return }
        bookmarks[i].title = trimmed
        changed()
    }

    /// Moves a bookmark into `folder` (nil: top level), to the end of it. An unknown folder is ignored.
    public func move(_ id: UUID, to folder: UUID?) {
        guard let i = bookmarks.firstIndex(where: { $0.id == id }) else { return }
        if let folder, self.folder(folder) == nil { return }
        guard bookmarks[i].folder != folder else { return }
        var moved = bookmarks.remove(at: i)
        moved.folder = folder
        bookmarks.append(moved)
        changed()
    }

    // MARK: Folders

    /// Makes a folder, inside `parent` (nil: top level). An empty name becomes "New Folder".
    @discardableResult
    public func addFolder(named name: String, in parent: UUID? = nil) -> BookmarkFolder {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let valid = parent.flatMap { folder($0) != nil ? $0 : nil }
        let made = BookmarkFolder(name: trimmed.isEmpty ? "New Folder" : trimmed, parent: valid)
        folders.append(made)
        changed()
        return made
    }

    /// An empty name is ignored.
    public func renameFolder(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = folders.firstIndex(where: { $0.id == id }), folders[i].name != trimmed else { return }
        folders[i].name = trimmed
        changed()
    }

    /// Moves a folder under `parent` (nil: top level). Refused when that would put a folder inside itself.
    public func moveFolder(_ id: UUID, to parent: UUID?) {
        guard let i = folders.firstIndex(where: { $0.id == id }), folders[i].parent != parent else { return }
        if let parent {
            guard folder(parent) != nil, !isInside(parent, ancestor: id) else { return }
        }
        folders[i].parent = parent
        changed()
    }

    /// Removes a folder. Its bookmarks and subfolders move up to its parent.
    public func removeFolder(_ id: UUID) {
        guard let removed = folder(id) else { return }
        folders.removeAll { $0.id == id }
        for i in folders.indices where folders[i].parent == id { folders[i].parent = removed.parent }
        for i in bookmarks.indices where bookmarks[i].folder == id { bookmarks[i].folder = removed.parent }
        changed()
    }

    /// True when `folder` is `ancestor` or sits anywhere below it.
    func isInside(_ folder: UUID, ancestor: UUID) -> Bool {
        var current: UUID? = folder
        var steps = 0
        while let id = current, steps < 64 {
            if id == ancestor { return true }
            current = self.folder(id)?.parent
            steps += 1
        }
        return false
    }

    // MARK: Search

    /// Bookmarks whose title, address or folder name contain every word of the query, best first:
    /// a word at the start of the title beats one inside it, then the folder, then the address.
    /// Keyword only; never uses AI.
    public func search(_ query: String, limit: Int = 5) -> [SearchResult] {
        let tokens = query.split(whereSeparator: { $0.isWhitespace }).map { BrowserStore.fold(String($0)) }
        guard !tokens.isEmpty, limit > 0 else { return [] }
        var hits: [(offset: Int, score: Int, bookmark: Bookmark)] = []
        for (offset, bookmark) in bookmarks.enumerated() {
            let folderText = path(of: bookmark.folder).joined(separator: " ")
            guard let score = BrowserStore.score(tokens, name: bookmark.title, title: folderText, url: bookmark.url, site: URLCanonical.host(bookmark.url))
            else { continue }
            hits.append((offset, score, bookmark))
        }
        hits.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.bookmark.addedAt != b.bookmark.addedAt { return a.bookmark.addedAt > b.bookmark.addedAt }
            return a.offset < b.offset
        }
        return hits.prefix(limit).map { hit in
            let url = hit.bookmark.url
            return SearchResult(id: SearchResult.bookmarkIDPrefix + hit.bookmark.id.uuidString, target: .history(url), title: hit.bookmark.title,
                                subtitle: BrowserStore.displayURL(url), key: SiteKey(URLCanonical.host(url)))
        }
    }

    static func cleanTitle(_ title: String, url: URL) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? URLCanonical.display(url) : trimmed
    }

    // MARK: Persistence

    /// Writes `bookmarks.json` now. Does nothing without a storage directory.
    public func save() throws {
        saveTask?.cancel()
        saveTask = nil
        guard let storageDirectory else { return }
        let data = try JSONEncoder().encode(BookmarkSnapshot(version: BookmarkSnapshot.currentVersion, folders: folders, bookmarks: bookmarks))
        try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
        try data.write(to: storageDirectory.appendingPathComponent(BookmarkSnapshot.fileName), options: .atomic)
    }

    /// Synchronous save for app termination. Errors are swallowed.
    public func flush() { try? save() }

    private func changed() {
        guard storageDirectory != nil, saveTask == nil else { return }
        let delay = autosaveDelay
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    private func load() {
        guard let storageDirectory else { return }
        let file = storageDirectory.appendingPathComponent(BookmarkSnapshot.fileName)
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            let snapshot = try JSONDecoder().decode(BookmarkSnapshot.self, from: try Data(contentsOf: file))
            guard snapshot.version == BookmarkSnapshot.currentVersion else { throw CocoaError(.fileReadCorruptFile) }
            folders = snapshot.folders
            bookmarks = snapshot.bookmarks
            sanitize()
        } catch {
            recoveredCorruptFile = Self.moveAside(file, now: now())
        }
    }

    /// Drops duplicate ids and repairs references to folders that are gone or form a loop.
    private func sanitize() {
        var seen = Set<UUID>()
        folders = folders.filter { seen.insert($0.id).inserted }
        let ids = Set(folders.map(\.id))
        for i in folders.indices {
            if let p = folders[i].parent, !ids.contains(p) { folders[i].parent = nil }
        }
        for i in folders.indices where isInside(folders[i].parent ?? folders[i].id, ancestor: folders[i].id) && folders[i].parent != nil {
            folders[i].parent = nil
        }
        seen = []
        bookmarks = bookmarks.filter { seen.insert($0.id).inserted }
        for i in bookmarks.indices {
            if let f = bookmarks[i].folder, !ids.contains(f) { bookmarks[i].folder = nil }
        }
    }

    /// Moves an unreadable file out of the way so the next save cannot destroy it.
    private static func moveAside(_ file: URL, now: Date) -> URL? {
        let stamp = now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).timeSeparator(.omitted)
            .dateSeparator(.omitted)).replacingOccurrences(of: ":", with: "")
        var target = file.deletingLastPathComponent().appendingPathComponent("bookmarks.corrupt-\(stamp).json")
        var n = 1
        while FileManager.default.fileExists(atPath: target.path) {
            n += 1
            target = file.deletingLastPathComponent().appendingPathComponent("bookmarks.corrupt-\(stamp)-\(n).json")
        }
        do { try FileManager.default.moveItem(at: file, to: target); return target } catch { return nil }
    }
}

extension BookmarkStore {
    /// What the command bar lists for a query: the suggestions it already had, plus bookmark
    /// matches. A history suggestion for a bookmarked page is dropped, because the bookmark row
    /// stands for it under its own heading; open pages, pins, shelved pages and a top hit stay.
    public func results(for query: String, amid suggestions: [SearchResult], limit: Int = 3) -> [SearchResult] {
        let hits = search(query, limit: limit)
        guard !hits.isEmpty else { return suggestions }
        let saved = Set(hits.compactMap { hit -> String? in
            if case .history(let url) = hit.target { return URLCanonical.key(url) }
            return nil
        })
        let kept = suggestions.filter { item in
            guard !item.isTopHit, case .history(let url) = item.target else { return true }
            return !saved.contains(URLCanonical.key(url))
        }
        return kept + hits
    }
}

extension BookmarkStore {
    /// Every folder by full path (parents first, alphabetical among siblings), after the top level.
    public func folderChoices() -> [BookmarkFolderChoice] {
        var out = [BookmarkFolderChoice(id: nil, label: "Bookmarks")]
        func walk(_ parent: UUID?, depth: Int) {
            guard depth < 16 else { return }
            for f in subfolders(of: parent).sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) {
                out.append(BookmarkFolderChoice(id: f.id, label: path(of: f.id).joined(separator: " › ")))
                walk(f.id, depth: depth + 1)
            }
        }
        walk(nil, depth: 0)
        return out
    }
}
