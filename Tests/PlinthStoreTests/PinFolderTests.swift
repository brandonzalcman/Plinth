import Foundation
import Testing
import PlinthModel
@testable import PlinthStore

@MainActor @Suite struct PinFolderTests {
    /// A rig with pins a.com…d.com, in a window.
    func rigWithPins(_ hosts: [String] = ["a.com", "b.com", "c.com", "d.com"], dir: URL? = nil) -> (Rig, WindowID) {
        let r = Rig(dir: dir)
        let w = r.store.createWindow()
        for h in hosts {
            r.open("https://\(h)/", in: w)
            r.store.pin(site: r.store.window(w)!.sites.first { $0.key.host == h }!.id)
        }
        return (r, w)
    }
    func id(_ r: Rig, _ host: String) -> SiteID { r.store.pins.first { $0.key.host == host }!.id }
    func order(_ r: Rig) -> String { r.store.pins.map { $0.key.host + ($0.folder.map { "@" + $0.name } ?? "") }.joined(separator: " ") }

    @Test func newFolderThenJoinKeepsMembersTogether() {
        let (r, _) = rigWithPins()
        let f = r.store.createPinFolder(with: id(r, "a.com"))!
        #expect(f.name == "Folder")
        r.store.movePin(id(r, "c.com"), toFolder: f.id)
        r.store.movePin(id(r, "d.com"), toFolder: f.id)
        #expect(order(r) == "a.com@Folder c.com@Folder d.com@Folder b.com")
        r.ok()
    }

    @Test func secondFolderGetsADistinctName() {
        let (r, _) = rigWithPins()
        r.store.createPinFolder(with: id(r, "a.com"))
        let g = r.store.createPinFolder(with: id(r, "b.com"))!
        #expect(g.name == "Folder 2")
    }

    @Test func renameUngroupAndRemove() {
        let (r, _) = rigWithPins()
        let f = r.store.createPinFolder(with: id(r, "a.com"))!
        r.store.movePin(id(r, "b.com"), toFolder: f.id)
        r.store.renamePinFolder(f.id, to: "  Work ")
        r.store.renamePinFolder(f.id, to: "   ")
        #expect(order(r) == "a.com@Work b.com@Work c.com d.com")
        r.store.removePinFromFolder(id(r, "a.com"))
        #expect(order(r) == "b.com@Work a.com c.com d.com")
        r.store.ungroupPinFolder(f.id)
        #expect(order(r) == "b.com a.com c.com d.com")
        #expect(r.store.pinFolders.isEmpty)
    }

    @Test func unpinningTheLastMemberDissolvesTheFolder() {
        let (r, w) = rigWithPins()
        let f = r.store.createPinFolder(with: id(r, "a.com"))!
        r.store.movePin(id(r, "b.com"), toFolder: f.id)
        r.store.unpin(id(r, "a.com"), into: w)
        r.store.unpin(id(r, "b.com"), into: w)
        #expect(r.store.pinFolders.isEmpty)
        #expect(r.store.pins.map(\.key.host) == ["c.com", "d.com"])
    }

    @Test func foldersSurviveRelaunchAndOldFilesLoadUnchanged() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (r, _) = rigWithPins(dir: dir)
        let f = r.store.createPinFolder(with: id(r, "b.com"), name: "Reading")!
        r.store.movePin(id(r, "d.com"), toFolder: f.id)
        try r.store.save()
        let again = Rig(dir: dir)
        #expect(again.store.pins == r.store.pins)
        #expect(again.store.pinFolders.map(\.folder.name) == ["Reading"])
        #expect(again.store.pinFolders[0].pins.map(\.key.host) == ["b.com", "d.com"])

        // A file written before folders existed has no "folder" key on any pin.
        let url = dir.appendingPathComponent(StoreSnapshot.fileName)
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var pins = try #require(json["pins"] as? [[String: Any]])
        for i in pins.indices { pins[i].removeValue(forKey: "folder") }
        json["pins"] = pins
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        let old = Rig(dir: dir)
        #expect(old.store.pins.count == 4)
        #expect(old.store.pins.allSatisfy { $0.folder == nil })
    }

    @Test func shortcutsCountFolderMembersInBarOrder() {
        let (r, _) = rigWithPins()
        let f = r.store.createPinFolder(with: id(r, "a.com"))!
        r.store.movePin(id(r, "c.com"), toFolder: f.id)
        #expect(order(r) == "a.com@Folder c.com@Folder b.com d.com")
        // Members count, in the order the bar shows them, even if the array were out of step.
        let scrambled = [r.store.pins[0], r.store.pins[2], r.store.pins[1], r.store.pins[3]]
        let expected = ["a.com", "c.com", "b.com", "d.com"].map { h in r.store.pins.first { $0.key.host == h }!.page.id }
        #expect(BarOrder.pageOrder(pins: scrambled, sites: []) == expected)
    }

    @Test func selectingAMemberBehavesLikeAnyPin() {
        let (r, w) = rigWithPins()
        let f = r.store.createPinFolder(with: id(r, "a.com"))!
        r.store.movePin(id(r, "b.com"), toFolder: f.id)
        r.store.selectPin(id(r, "b.com"), in: w)
        #expect(r.store.window(w)?.selectedPageID == r.store.pins.first { $0.key.host == "b.com" }!.page.id)
        r.ok()
    }
}
