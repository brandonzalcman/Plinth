import Foundation
import Testing
import PlinthModel
@testable import PlinthStore

@MainActor @Suite struct FoldTests {
    private func rig() -> (Rig, WindowID, SiteID, [PageID]) {
        let r = Rig()
        let w = r.store.createWindow()
        let pages = (1...3).map { r.open("https://a.com/\($0)", in: w) }
        r.open("https://b.com/1", in: w)
        let a = r.store.window(w)!.sites[0].id
        return (r, w, a, pages)
    }

    @Test func togglesAndKeepsTheSelectionAndPages() {
        let (r, w, a, _) = rig()
        let selected = r.store.window(w)?.selectedPageID
        r.store.toggleFold(a, in: w)
        #expect(r.store.window(w)?.sites[0].isFolded == true)
        #expect(r.store.window(w)?.sites[0].pages.count == 3)
        #expect(r.store.window(w)?.selectedPageID == selected)
        r.store.toggleFold(a, in: w)
        #expect(r.store.window(w)?.sites[0].isFolded == false)
        r.ok()
    }

    @Test func singlePageSitesDoNotFold() {
        let (r, w, _, _) = rig()
        let b = r.store.window(w)!.sites[1].id
        r.store.toggleFold(b, in: w)
        #expect(r.store.window(w)?.sites[1].isFolded == false)
    }

    @Test func selectingAPageUnfoldsItsSite() {
        let (r, w, a, pages) = rig()
        r.store.toggleFold(a, in: w)
        r.store.select(pages[1], in: w)
        #expect(r.store.window(w)?.sites[0].isFolded == false)
        r.store.toggleFold(a, in: w)
        r.store.selectSite(a, in: w)
        #expect(r.store.window(w)?.sites[0].isFolded == false)
        r.store.toggleFold(a, in: w)
        r.open("https://a.com/new", in: w)
        #expect(r.store.window(w)?.sites[0].isFolded == false)
    }

    @Test func foldedSiteStaysFoldedWhenTheSelectionIsElsewhere() {
        let (r, w, a, _) = rig()
        r.store.toggleFold(a, in: w)
        r.open("https://b.com/2", in: w)
        #expect(r.store.window(w)?.sites[0].isFolded == true)
    }

    @Test func foldSurvivesRelaunchAndOldFilesLoadUnfolded() throws {
        let dir = tempDir()
        let r = Rig(dir: dir)
        let w = r.store.createWindow()
        for i in 1...2 { r.open("https://a.com/\(i)", in: w) }
        r.open("https://b.com/1", in: w)
        r.store.toggleFold(r.store.window(w)!.sites[0].id, in: w)
        try r.store.save()
        let again = Rig(dir: dir)
        #expect(again.store.window(w)?.sites[0].isFolded == true)
        again.ok()

        // A site saved before folding existed has no such key.
        var site = Site(key: SiteKey("c.com"), name: "C", pages: [Page(url: u("https://c.com"), name: "C", usage: Usage(at: Date()))])
        site.isFolded = true
        let data = try JSONEncoder().encode(site)
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["isFolded"] = nil
        let old = try JSONDecoder().decode(Site.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.isFolded == false)
    }

    @Test func aSiteHoldingTheSplitCannotFold() {
        let (r, w, a, pages) = rig()
        r.store.split(pages[0], with: pages[1], in: w)
        r.store.toggleFold(a, in: w)
        #expect(r.store.window(w)?.sites[0].isFolded == false)
    }
}
