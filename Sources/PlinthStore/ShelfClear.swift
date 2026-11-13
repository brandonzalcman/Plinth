import Foundation
import PlinthModel

/// "Clear all" for the shelf, with Undo.
///
/// `clearShelf()` takes every entry off the shelf but keeps them in `clearedShelf` and does not
/// destroy their suspended views yet. `undoClearShelf()` puts them back; `commitClearedShelf()`
/// (the shell calls it when the Undo window ends) makes the clear final by emitting `.pageClosed`
/// for each page, exactly like `removeFromShelf`.
extension BrowserStore {
    /// The number of pages waiting on an Undo.
    public var clearedShelfPageCount: Int { clearedShelf.reduce(0) { $0 + $1.pages.count } }

    /// Empties the shelf. Returns how many pages it held (0 when it was empty: nothing changes).
    /// A clear that is still undoable is committed first, so only the latest clear can be undone.
    @discardableResult public func clearShelf() -> Int {
        guard !shelf.isEmpty else { return 0 }
        commitClearedShelf()
        clearedShelf = shelf
        shelf = []
        commit()
        return clearedShelfPageCount
    }

    /// Puts the cleared pages back on the shelf. Entries for a site that has meanwhile gained a new
    /// shelf entry are merged into it. Returns the number of pages restored.
    @discardableResult public func undoClearShelf() -> Int {
        guard !clearedShelf.isEmpty else { return 0 }
        let back = clearedShelf
        clearedShelf = []
        var restored = 0
        for entry in back where !entry.pages.isEmpty {
            restored += entry.pages.count
            if let i = shelf.firstIndex(where: { $0.key == entry.key }) {
                var merged = shelf[i]
                let known = Set(merged.pages.map(\.id))
                merged.pages.append(contentsOf: entry.pages.filter { !known.contains($0.id) })
                merged.shelvedAt = max(merged.shelvedAt, entry.shelvedAt)
                shelf[i] = merged
            } else {
                shelf.append(entry)
            }
        }
        // Newest first, as everywhere else; stable for equal times.
        shelf = shelf.enumerated().sorted {
            $0.element.shelvedAt != $1.element.shelvedAt ? $0.element.shelvedAt > $1.element.shelvedAt : $0.offset < $1.offset
        }.map(\.element)
        commit()
        return restored
    }

    /// Makes a pending clear final: the pages' suspended views and snapshots are destroyed.
    public func commitClearedShelf() {
        guard !clearedShelf.isEmpty else { return }
        let gone = clearedShelf.flatMap(\.pages)
        clearedShelf = []
        for page in gone {
            latestHistory[page.id] = nil
            emit(.pageClosed(page.id))
        }
        commit(mutated: false)
    }
}
