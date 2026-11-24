import Foundation
import Testing
import PlinthModel
import PlinthRules
import PlinthFade
import PlinthStore
@testable import PlinthShell

/// Records what the router asked of the page engine and the window.
@MainActor
final class Recorder: PageNavigating, WindowPanels {
    var calls: [String] = []
    var hasNoPanel = true
    func goBack(_ page: PageID) { calls.append("back") }
    func goForward(_ page: PageID) { calls.append("forward") }
    func reload(_ page: PageID) { calls.append("reload") }
    func stopLoading(_ page: PageID) { calls.append("stop") }
    func openCommandBar(newPage: Bool) { calls.append(newPage ? "command:new" : "command:edit") }
    func toggleShelf() { calls.append("shelf") }
    func toggleDownloads() { calls.append("downloads") }
}

@MainActor
@Suite struct ActionRouterTests {
    let store = BrowserStore(identity: SiteIdentity(), namer: PageNamer(), fader: FadeEngine(), storageDirectory: nil)
    let rec = Recorder()
    let window: WindowID

    init() { window = store.createWindow() }

    @discardableResult func open(_ url: String) -> PageID { store.openPage(url: URL(string: url)!, in: window) }
    func send(_ action: BarAction) { ActionRouter.handle(action, in: window, store: store, pages: rec, panels: rec) }
    func site(_ host: String) -> Site { store.window(window)!.sites.first { $0.key.host == host }! }
    var selected: PageID? { store.window(window)?.selectedPageID }

    @Test func selectingAnotherPageSelectsItButTheCurrentOneOpensTheAddressEditor() {
        let a = open("https://example.com/a")
        let b = open("https://swift.org/")
        send(.selectPage(a))
        #expect(selected == a)
        #expect(rec.calls.isEmpty)
        send(.selectPage(a))
        #expect(rec.calls == ["command:edit"])
        // With a panel open, clicking the current page just selects it again.
        rec.hasNoPanel = false
        send(.selectPage(a))
        #expect(rec.calls == ["command:edit"])
        _ = b
    }

    @Test func navigationGoesToTheSelectedPage() {
        open("https://example.com/")
        send(.goBack); send(.goForward); send(.reload); send(.stopLoading)
        #expect(rec.calls == ["back", "forward", "reload", "stop"])
    }

    @Test func navigationWithoutAPageDoesNothing() {
        send(.goBack); send(.reload)
        #expect(rec.calls.isEmpty)
    }

    @Test func newPageAndPanels() {
        send(.newPage); send(.openCommandBar); send(.openShelf); send(.openDownloads)
        #expect(rec.calls == ["command:new", "command:edit", "shelf", "downloads"])
    }

    @Test func pinUnpinAndFolders() {
        open("https://a.com/"); open("https://b.com/"); open("https://c.com/")
        for host in ["a.com", "b.com", "c.com"] { send(.pinSite(site(host).id)) }
        #expect(store.pins.map(\.key.host) == ["a.com", "b.com", "c.com"])
        let pin = { (host: String) in store.pins.first { $0.key.host == host }!.id }
        send(.groupPins(pin("c.com"), onto: pin("a.com")))
        let folder = try! #require(store.pins.first { $0.key.host == "a.com" }?.folder)
        #expect(store.pins.first { $0.key.host == "c.com" }?.folder?.id == folder.id)
        send(.renamePinFolder(folder.id, "Work"))
        #expect(store.pins.first { $0.key.host == "a.com" }?.folder?.name == "Work")
        send(.movePinToFolder(pin("b.com"), folder: folder.id))
        #expect(store.pins.allSatisfy { $0.folder?.id == folder.id })
        send(.removePinFromFolder(pin("b.com")))
        #expect(store.pins.first { $0.key.host == "b.com" }?.folder == nil)
        send(.ungroupPinFolder(folder.id))
        #expect(store.pins.allSatisfy { $0.folder == nil })
        send(.unpin(pin("b.com")))
        #expect(!store.pins.contains { $0.key.host == "b.com" })
    }

    @Test func clickingTheCurrentPinOpensTheAddressEditor() {
        open("https://a.com/")
        send(.pinSite(site("a.com").id))
        open("https://b.com/")           // something else is selected now
        let pin = store.pins[0]
        send(.selectPin(pin.id))
        #expect(selected == pin.page.id)
        send(.selectPin(pin.id))
        #expect(rec.calls == ["command:edit"])
    }

    @Test func keepPutAwayAndClose() {
        open("https://a.com/1"); open("https://a.com/2"); open("https://b.com/")
        send(.setKept(site("a.com").id, true))
        #expect(site("a.com").isKept)
        send(.shelveSite(site("b.com").id))
        #expect(store.shelf.map(\.key.host) == ["b.com"])
        send(.closeSite(site("a.com").id))
        #expect(store.window(window)!.sites.isEmpty)
    }

    @Test func foldAndRename() {
        let p = open("https://a.com/1"); open("https://a.com/2"); open("https://b.com/")
        send(.toggleFold(site("a.com").id))
        #expect(site("a.com").isFolded)
        send(.renamePage(p, "Mine"))
        #expect(store.page(p)?.name == "Mine")
    }

    @Test func splitWithCurrentAndEnd() {
        let a = open("https://a.com/")
        let b = open("https://b.com/")
        send(.splitWithCurrent(a))
        #expect(store.window(window)?.split.map { Set([$0.leading, $0.trailing]) } == Set([a, b]))
        send(.endSplit)
        #expect(store.window(window)?.split == nil)
        send(.splitPages(b, onto: a))
        #expect(store.window(window)?.split != nil)
    }

    @Test func movingASiteWhileAGroupIsFocusedUsesTheStoresOrder() {
        open("https://a.com/"); open("https://b.com/"); open("https://c.com/"); open("https://d.com/")
        let group = store.acceptSuggestion(GroupSuggestion(window: window, keys: [SiteKey("a.com"), SiteKey("c.com")],
                                                           siteNames: ["A", "C"]))
        store.select(site("a.com").pages[0].id, in: window)
        store.setFocus(group, in: window)
        // The bar shows a.com, c.com: dropping c.com first puts it before a.com in the full list.
        send(.moveSite(site("c.com").id, toIndex: 0))
        #expect(store.window(window)!.sites.map(\.key.host) == ["c.com", "a.com", "b.com", "d.com"])
    }

    @Test func closingThePageYouAreOnGoesBackToTheOneUsedBefore() {
        let a = open("https://a.com/1")
        open("https://a.com/2")
        let c = open("https://a.com/3")
        store.select(a, in: window)
        store.select(c, in: window)
        // A neighbour would be a.com/2; the page used just before was a.com/1.
        send(.closePage(c))
        #expect(selected == a)
    }

    @Test func closingTheLastPageOfASiteCanReturnToAPin() {
        open("https://pin.com/")
        send(.pinSite(site("pin.com").id))
        let pin = store.pins[0].page.id
        let b = open("https://b.com/")
        store.select(pin, in: window)
        store.select(b, in: window)
        send(.closePage(b))
        #expect(selected == pin)
    }

    @Test func closingAPageInTheBackgroundKeepsTheSelection() {
        let a = open("https://a.com/")
        let b = open("https://b.com/")
        send(.closePage(a))
        #expect(selected == b)
    }

    @Test func closingTheCurrentSiteGoesToTheMostRecentOtherPage() {
        let a = open("https://a.com/")
        open("https://b.com/")
        let c1 = open("https://c.com/1")
        store.select(a, in: window)
        store.select(c1, in: window)
        send(.closeSite(site("c.com").id))
        #expect(selected == a)
    }
}
