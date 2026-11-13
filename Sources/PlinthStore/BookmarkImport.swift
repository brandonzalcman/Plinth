import Foundation
import PlinthModel

/// What `BookmarkStore.importItems` did.
public struct BookmarkImportResult: Sendable, Equatable {
    public var added = 0
    /// Already bookmarked (same canonical address), or repeated in the import.
    public var alreadySaved = 0
    public init() {}
}

extension BookmarkStore {
    /// Adds bookmarks from another browser, keeping their folders. Everything goes under one new or
    /// existing top-level folder named `root` (for example "Imported from Safari"), then under
    /// the folder path each item came with. Folders are found by name before they are made, so
    /// running the same import twice adds nothing. Only web addresses are taken.
    @discardableResult
    public func importItems(_ items: [(title: String, url: URL, folder: [String])], under root: String) -> BookmarkImportResult {
        var result = BookmarkImportResult()
        var rootID: UUID?
        func folder(named name: String, in parent: UUID?) -> UUID {
            if let existing = subfolders(of: parent).first(where: { $0.name == name }) { return existing.id }
            return addFolder(named: name, in: parent).id
        }
        for item in items {
            guard let scheme = item.url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { continue }
            if bookmark(for: item.url) != nil { result.alreadySaved += 1; continue }
            if rootID == nil { rootID = folder(named: root, in: nil) }
            var parent = rootID
            for name in item.folder where !name.trimmingCharacters(in: .whitespaces).isEmpty { parent = folder(named: name, in: parent) }
            if case .added? = add(title: item.title, url: item.url, in: parent) { result.added += 1 } else { result.alreadySaved += 1 }
        }
        return result
    }
}
