import Foundation
import Testing
import PlinthModel
import PlinthRules
import PlinthFade
import PlinthLayout
import PlinthStore
@testable import PlinthShell

/// A real store (the same one the Mac app uses) with a window, in memory.
@MainActor
struct Rig {
    let store = BrowserStore(identity: SiteIdentity(), namer: PageNamer(), fader: FadeEngine(), storageDirectory: nil)
    let window: WindowID

    init() { window = store.createWindow() }

    @discardableResult
    func open(_ url: String) -> PageID { store.openPage(url: URL(string: url)!, in: window) }

    func site(_ host: String) -> Site { store.window(window)!.sites.first { $0.key.host == host }! }
    func pin(_ host: String) -> SiteID { store.pins.first { $0.key.host == host }!.id }

    var input: BarInput {
        let state = store.window(window)!
        return BarInput(pins: store.pins(in: window), sites: store.visibleSites(in: window),
                        selected: state.selectedPageID, split: state.split)
    }
    var model: SidebarModel { SidebarModel(input) }
}

@MainActor
@Suite struct SidebarModelTests {
    @Test func pagesAreGroupedUnderTheirSite() {
        let r = Rig()
        r.open("https://example.com/a")
        r.open("https://swift.org/blog")
        r.open("https://example.com/b")
        let m = r.model
        #expect(m.sites.map(\.key.host) == ["example.com", "swift.org"])
        #expect(m.sites[0].pages.count == 2)
        #expect(m.sites[1].isSingle)
        #expect(m.sites[1].visiblePages.isEmpty)   // a one-page site is a single row
        #expect(m.sites[0].visiblePages.count == 2)
    }

    @Test func currentPageAndShortcutsMatchTheBar() {
        let r = Rig()
        r.open("https://example.com/a")
        r.open("https://swift.org/blog")
        let last = r.open("https://example.com/b")
        r.store.pin(site: r.site("swift.org").id)
        let m = r.model
        let layout = BarLayoutEngine().layout(r.input, barWidth: 100_000, metrics: .standard) { s, _ in CGFloat(s.count * 7) }

        #expect(m.selected == last)
        // Same pins, same order, same current flags and ⌘-number shortcuts as the bar.
        #expect(m.allPins.map(\.id) == layout.pins.map(\.id))
        #expect(m.allPins.map(\.shortcut) == layout.pins.map(\.shortcut))
        let barPages = layout.sites.flatMap(\.pages)
        let sidebarPages = m.sites.flatMap(\.pages)
        #expect(sidebarPages.map(\.id) == barPages.map(\.id))
        #expect(sidebarPages.map(\.isCurrent) == barPages.map(\.isCurrent))
        #expect(sidebarPages.map(\.shortcut) == barPages.map(\.shortcut))
    }

    @Test func pinFoldersBecomeOneSlotInBarOrder() {
        let r = Rig()
        for host in ["a.com", "b.com", "c.com"] {
            r.open("https://\(host)/")
            r.store.pin(site: r.site(host).id)
        }
        let folder = r.store.createPinFolder(with: r.pin("a.com"))!
        r.store.movePin(r.pin("c.com"), toFolder: folder.id)
        let m = r.model
        #expect(m.pins.count == 2)
        guard case .folder(let f) = m.pins[0] else { Issue.record("expected a folder first"); return }
        #expect(f.members.map(\.key.host) == ["a.com", "c.com"])
        #expect(f.name == "Folder")
        guard case .pin(let p) = m.pins[1] else { Issue.record("expected a pin"); return }
        #expect(p.key.host == "b.com")
        #expect(m.allPins.map(\.key.host) == BarOrder.arranged(r.store.pins).map(\.key.host))
    }

    @Test func splitMarksBothPagesCurrent() {
        let r = Rig()
        let a = r.open("https://example.com/a")
        let b = r.open("https://swift.org/")
        r.store.split(a, with: b, in: r.window)
        let pages = r.model.sites.flatMap(\.pages)
        let current = Set(pages.filter(\.isCurrent).map(\.id))
        #expect(current == Set([a, b]))
        #expect(Set(pages.compactMap(\.splitRole)) == [.leading, .trailing])
    }

    @Test func foldedSiteHidesItsPagesUntilOneIsSelected() {
        let r = Rig()
        r.open("https://example.com/a")
        r.open("https://example.com/b")
        r.open("https://swift.org/")
        let site = r.site("example.com")
        r.store.toggleFold(site.id, in: r.window)
        var card = r.model.sites.first { $0.id == site.id }!
        #expect(card.isFolded)
        #expect(card.visiblePages.isEmpty)
        r.store.select(site.pages[0].id, in: r.window)
        card = r.model.sites.first { $0.id == site.id }!
        #expect(!card.visiblePages.isEmpty)
    }

    @Test func keptSitesNeverShowAsFading() {
        let r = Rig()
        r.open("https://example.com/a")
        r.store.setKept(r.site("example.com").id, true)
        let card = r.model.sites[0]
        #expect(card.isKept)
        #expect(card.fade == .live)
        #expect(card.pages.allSatisfy { $0.fade == .live })
    }

    @Test func railListsPinsThenSites() {
        let r = Rig()
        r.open("https://a.com/")
        r.store.pin(site: r.site("a.com").id)
        r.open("https://b.com/1")
        r.open("https://b.com/2")
        let rail = r.model.rail
        #expect(rail.map(\.key.host) == ["a.com", "b.com"])
        #expect(rail[1].pageCount == 2)
        #expect(rail[1].isCurrent)
    }

    @Test func groupFocusOnlyShowsTheGroupsSites() {
        let r = Rig()
        r.open("https://a.com/")
        r.open("https://b.com/")
        r.open("https://c.com/")
        r.store.select(r.site("a.com").pages[0].id, in: r.window)
        let group = r.store.acceptSuggestion(GroupSuggestion(window: r.window, keys: [SiteKey("a.com"), SiteKey("b.com")],
                                                             siteNames: ["A", "B"]))
        r.store.setFocus(group, in: r.window)
        // The same filtered list the bar gets.
        #expect(r.model.sites.map(\.key.host) == r.store.visibleSites(in: r.window).map(\.key.host))
        #expect(!r.model.sites.map(\.key.host).contains("c.com"))
    }

    @Test func intentsMapToTheBarsActions() {
        let site = SiteID(), page = PageID(), folder = UUID()
        #expect(SidebarIntent.tapSiteHeader(site).action == .selectSite(site))
        #expect(SidebarIntent.tapPage(page).action == .selectPage(page))
        #expect(SidebarIntent.tapRail(.pin(site)).action == .selectPin(site))
        #expect(SidebarIntent.tapRail(.site(site)).action == .selectSite(site))
        #expect(SidebarIntent.putAway(site).action == .shelveSite(site))
        #expect(SidebarIntent.movePinToFolder(site, folder: folder).action == .movePinToFolder(site, folder: folder))
        #expect(SidebarIntent.search.action == .openCommandBar)
    }

    @Test func freshnessEasesFromAnHourToADay() {
        let now = Date()
        #expect(Freshness.value(lastUsed: now, now: now) == 1)
        #expect(Freshness.value(lastUsed: now - 3000, now: now) == 1)
        let mid = Freshness.value(lastUsed: now - 12 * 3600, now: now)
        #expect(mid > 0.3 && mid < 0.7)
        #expect(Freshness.value(lastUsed: now - 30 * 3600, now: now) == 0)
        #expect(Freshness.opacity(lastUsed: .distantPast, now: now, isCurrent: false, kept: false) == 0.5)
        #expect(Freshness.opacity(lastUsed: .distantPast, now: now, isCurrent: true, kept: false) == 1)
        #expect(Freshness.opacity(lastUsed: .distantPast, now: now, isCurrent: false, kept: true) == 1)
    }

    @Test func pagesCarryWhenTheyWereLastUsed() {
        let r = Rig()
        r.open("https://example.com/")
        let page = r.model.sites[0].pages[0]
        #expect(abs(page.lastUsed.timeIntervalSinceNow) < 60)
    }

    @Test func siteTintIsStablePerHost() {
        #expect(SiteTint.hue(for: "example.com") == SiteTint.hue(for: "EXAMPLE.com"))
        #expect(SiteTint.hue(for: "example.com") != SiteTint.hue(for: "swift.org"))
        #expect((0..<1).contains(SiteTint.hue(for: "a.com")))
    }
}
