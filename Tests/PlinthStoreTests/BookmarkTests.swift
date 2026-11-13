import Foundation
import Testing
import PlinthModel
@testable import PlinthStore

@MainActor
struct BookmarkTests {
    let a = URL(string: "https://example.com/recipes/pasta")!
    let b = URL(string: "https://swift.org/blog")!

    func makeStore(_ dir: URL? = nil) -> BookmarkStore { BookmarkStore(storageDirectory: dir) }

    func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("plinth-bookmarks-\(UUID().uuidString)")
        return dir
    }

    @Test func addsAndFindsByAddress() {
        let store = makeStore()
        let added = store.add(title: "Pasta", url: a)
        #expect(added?.bookmark.title == "Pasta")
        #expect(store.bookmark(for: a)?.id == added?.bookmark.id)
        #expect(store.bookmarks.count == 1)
    }

    @Test func sameCanonicalAddressIsOneBookmark() {
        let store = makeStore()
        store.add(title: "Pasta", url: a)
        let again = store.add(title: "Other", url: URL(string: "http://www.example.com/recipes/pasta/?utm_source=x#top")!)
        guard case .existing(let existing)? = again else { Issue.record("expected .existing"); return }
        #expect(existing.title == "Pasta")
        #expect(store.bookmarks.count == 1)
    }

    @Test func onlyWebAddressesAreKept() {
        let store = makeStore()
        #expect(store.add(title: "x", url: URL(string: "file:///tmp/a.html")!) == nil)
        #expect(store.add(title: "x", url: URL(string: "about:blank")!) == nil)
        #expect(store.bookmarks.isEmpty)
    }

    @Test func emptyTitleFallsBackToAddress() {
        let store = makeStore()
        #expect(store.add(title: "  ", url: a)?.bookmark.title == "example.com/recipes/pasta")
    }

    @Test func renameAndRemove() throws {
        let store = makeStore()
        let id = try #require(store.add(title: "Pasta", url: a)).bookmark.id
        store.rename(id, to: "  Carbonara ")
        #expect(store.bookmark(id)?.title == "Carbonara")
        store.rename(id, to: "   ")
        #expect(store.bookmark(id)?.title == "Carbonara")
        store.remove(id)
        #expect(store.bookmarks.isEmpty)
    }

    @Test func foldersHoldBookmarksAndMoveThem() throws {
        let store = makeStore()
        let id = try #require(store.add(title: "Pasta", url: a)).bookmark.id
        let food = store.addFolder(named: "Food")
        store.move(id, to: food.id)
        #expect(store.bookmarks(in: food.id).map(\.id) == [id])
        #expect(store.bookmarks(in: nil).isEmpty)
        store.move(id, to: UUID()) // unknown folder: ignored
        #expect(store.bookmark(id)?.folder == food.id)
        store.move(id, to: nil)
        #expect(store.bookmarks(in: nil).count == 1)
    }

    @Test func addIntoFolderIgnoresUnknownFolder() throws {
        let store = makeStore()
        let food = store.addFolder(named: "Food")
        #expect(store.add(title: "Pasta", url: a, in: food.id)?.bookmark.folder == food.id)
        #expect(store.add(title: "Swift", url: b, in: UUID())?.bookmark.folder == nil)
    }

    @Test func nestedFoldersHavePaths() {
        let store = makeStore()
        let reading = store.addFolder(named: "Reading")
        let recipes = store.addFolder(named: "Recipes", in: reading.id)
        #expect(store.path(of: recipes.id) == ["Reading", "Recipes"])
        #expect(store.subfolders(of: reading.id).map(\.id) == [recipes.id])
        #expect(store.addFolder(named: "  ").name == "New Folder")
    }

    @Test func folderCannotMoveIntoItself() {
        let store = makeStore()
        let outer = store.addFolder(named: "Outer")
        let inner = store.addFolder(named: "Inner", in: outer.id)
        store.moveFolder(outer.id, to: inner.id)
        store.moveFolder(outer.id, to: outer.id)
        #expect(store.folder(outer.id)?.parent == nil)
        store.moveFolder(inner.id, to: nil)
        #expect(store.folder(inner.id)?.parent == nil)
    }

    @Test func removingAFolderKeepsItsContents() throws {
        let store = makeStore()
        let outer = store.addFolder(named: "Outer")
        let inner = store.addFolder(named: "Inner", in: outer.id)
        let id = try #require(store.add(title: "Pasta", url: a, in: inner.id)).bookmark.id
        store.removeFolder(inner.id)
        #expect(store.bookmark(id)?.folder == outer.id)
        store.removeFolder(outer.id)
        #expect(store.bookmark(id)?.folder == nil)
        #expect(store.folders.isEmpty)
    }

    @Test func searchMatchesTitleFolderAndAddress() throws {
        let store = makeStore()
        let food = store.addFolder(named: "Dinner")
        store.add(title: "Weeknight Pasta", url: a, in: food.id)
        store.add(title: "Swift blog", url: b)
        #expect(store.search("pasta").map(\.title) == ["Weeknight Pasta"])
        #expect(store.search("dinner").count == 1)
        #expect(store.search("swift.org").count == 1)
        #expect(store.search("pasta swift").isEmpty)
        #expect(store.search("").isEmpty)
        let hit = try #require(store.search("pasta").first)
        #expect(hit.isBookmark)
        #expect(hit.target == .history(a))
    }

    @Test func searchRanksTitleStartFirst() {
        let store = makeStore()
        store.add(title: "A note about Swift", url: URL(string: "https://a.example/1")!)
        store.add(title: "Swift evolution", url: URL(string: "https://b.example/2")!)
        #expect(store.search("swift").map(\.title) == ["Swift evolution", "A note about Swift"])
    }

    @Test func survivesRelaunch() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = makeStore(dir)
        let food = first.addFolder(named: "Food")
        first.add(title: "Pasta", url: a, in: food.id)
        try first.save()
        let second = makeStore(dir)
        #expect(second.folders == first.folders)
        #expect(second.bookmarks == first.bookmarks)
    }

    @Test func profileWithoutBookmarksLoadsEmpty() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("{\"version\":1,\"windows\":[]}".utf8).write(to: dir.appendingPathComponent("state.json"))
        let store = makeStore(dir)
        #expect(store.bookmarks.isEmpty && store.folders.isEmpty)
        #expect(store.recoveredCorruptFile == nil)
    }

    @Test func corruptFileIsMovedAside() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("bookmarks.json")
        try Data("not json".utf8).write(to: file)
        let store = makeStore(dir)
        #expect(store.bookmarks.isEmpty)
        let moved = try #require(store.recoveredCorruptFile)
        #expect(FileManager.default.fileExists(atPath: moved.path))
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func loadRepairsDanglingFolders() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let x = BookmarkFolder(name: "X", parent: UUID())
        let y = BookmarkFolder(name: "Y", parent: nil)
        let loop1 = BookmarkFolder(name: "L1", parent: nil)
        var loop2 = BookmarkFolder(name: "L2", parent: loop1.id)
        var l1 = loop1; l1.parent = loop2.id; loop2.parent = loop1.id
        let bm = Bookmark(title: "t", url: a, folder: UUID(), addedAt: Date())
        let data = try JSONEncoder().encode(BookmarkSnapshot(version: 1, folders: [x, y, l1, loop2], bookmarks: [bm]))
        try data.write(to: dir.appendingPathComponent("bookmarks.json"))
        let store = makeStore(dir)
        #expect(store.folder(x.id)?.parent == nil)
        #expect(store.bookmarks.first?.folder == nil)
        for f in store.folders { #expect(store.path(of: f.id).count <= 2) }
    }
}
