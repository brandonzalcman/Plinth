import Foundation

/// "Clear all" on the shelf is undoable for a short while; after that the pages are gone for good.
extension AppController {
    static let shelfUndoWindow: Duration = .seconds(15)

    func clearShelf() {
        guard store.clearShelf() > 0 else { return }
        shelfUndoTask?.cancel()
        shelfUndoTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.shelfUndoWindow)
            guard !Task.isCancelled, let self else { return }
            self.store.commitClearedShelf()
            self.shelfUndoTask = nil
        }
    }

    func undoClearShelf() {
        shelfUndoTask?.cancel()
        shelfUndoTask = nil
        store.undoClearShelf()
    }
}
