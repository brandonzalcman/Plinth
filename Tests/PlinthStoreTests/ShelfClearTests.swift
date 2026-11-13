import Foundation
import Testing
import PlinthModel
@testable import PlinthStore

@MainActor @Suite struct ShelfClearTests {
    private func shelved(_ r: Rig) -> (w: WindowID, a: PageID, b: PageID) {
        let w = r.store.createWindow()
        let a = r.open("https://a.com/1", in: w)
        let b = r.open("https://b.com/1", in: w)
        r.open("https://c.com/1", in: w)
        r.store.shelve(site: r.store.window(w)!.sites[0].id)
        r.store.shelve(site: r.store.window(w)!.sites[0].id)
        return (w, a, b)
    }

    @Test func clearEmptiesTheShelfButDestroysNothingYet() {
        let r = Rig()
        _ = shelved(r)
        #expect(r.store.shelf.count == 2)
        r.log.clear()
        #expect(r.store.clearShelf() == 2)
        #expect(r.store.shelf.isEmpty)
        #expect(r.store.clearedShelfPageCount == 2)
        #expect(r.log.events.isEmpty)
        r.ok()
    }

    @Test func undoPutsEverythingBackInOrder() {
        let r = Rig()
        _ = shelved(r)
        let before = r.store.shelf
        r.store.clearShelf()
        #expect(r.store.undoClearShelf() == 2)
        #expect(r.store.shelf == before)
        #expect(r.store.clearedShelf.isEmpty)
        #expect(r.store.undoClearShelf() == 0)
        r.ok()
    }

    @Test func commitDestroysThePagesAndEndsUndo() {
        let r = Rig()
        let s = shelved(r)
        r.store.clearShelf()
        r.log.clear()
        r.store.commitClearedShelf()
        #expect(r.log.events.count == 2 && r.log.events.contains(.pageClosed(s.a)) && r.log.events.contains(.pageClosed(s.b)))
        #expect(r.store.undoClearShelf() == 0)
        #expect(r.store.shelf.isEmpty)
        r.ok()
    }

    @Test func clearingAnEmptyShelfDoesNothing() {
        let r = Rig()
        #expect(r.store.clearShelf() == 0)
        #expect(r.store.clearedShelf.isEmpty)
    }

    @Test func aSecondClearCommitsTheFirst() {
        let r = Rig()
        let s = shelved(r)
        r.store.clearShelf()
        let w2 = r.store.createWindow()
        let d = r.open("https://d.com/1", in: w2)
        r.store.shelve(site: r.store.window(w2)!.sites[0].id)
        r.log.clear()
        #expect(r.store.clearShelf() == 1)
        #expect(r.log.events.count == 2 && r.log.events.contains(.pageClosed(s.a)) && r.log.events.contains(.pageClosed(s.b)))
        #expect(r.store.undoClearShelf() == 1)
        #expect(r.store.shelf.flatMap(\.pages).map(\.id) == [d])
        r.ok()
    }

    @Test func undoMergesWithAnEntryShelvedInTheMeantime() {
        let r = Rig()
        let s = shelved(r)
        r.store.clearShelf()
        let again = r.open("https://a.com/2", in: s.w)
        r.store.shelve(site: r.store.window(s.w)!.sites.first { $0.key.host == "a.com" }!.id)
        #expect(r.store.shelf.count == 1)
        r.store.undoClearShelf()
        #expect(r.store.shelf.count == 2)
        let a = r.store.shelf.first { $0.key.host == "a.com" }!
        #expect(Set(a.pages.map(\.id)) == [s.a, again])
        r.ok()
    }
}
