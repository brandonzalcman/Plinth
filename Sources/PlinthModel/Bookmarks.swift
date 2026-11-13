import Foundation

// MARK: - Bookmarks

/// A page the user chose to keep. Bookmarks live in folders; `folder` is nil at the top level.
public struct Bookmark: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var title: String
    public var url: URL
    public var folder: UUID?
    public var addedAt: Date

    public init(id: UUID = UUID(), title: String, url: URL, folder: UUID? = nil, addedAt: Date) {
        self.id = id; self.title = title; self.url = url; self.folder = folder; self.addedAt = addedAt
    }
}

/// A folder of bookmarks and other folders. `parent` is nil at the top level.
public struct BookmarkFolder: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var parent: UUID?

    public init(id: UUID = UUID(), name: String, parent: UUID? = nil) {
        self.id = id; self.name = name; self.parent = parent
    }
}

extension SearchResult {
    /// Result ids from the bookmarks store start with this. A bookmark opens like a history hit
    /// (it is just an address), but the command bar lists it under its own heading.
    public static let bookmarkIDPrefix = "bookmark-"
    public var isBookmark: Bool { id.hasPrefix(Self.bookmarkIDPrefix) }
}
