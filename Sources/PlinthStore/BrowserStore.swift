import Foundation
import Observation
import PlinthModel

/// The single source of truth for browser state. No WebKit, no UI: the app shell calls the
/// actions below and reacts to `onEvent`.
///
/// Events are delivered after the action that caused them has finished, so a handler always
/// sees a consistent store.
@MainActor @Observable
public final class BrowserStore {
    public internal(set) var windows: [WindowState] = []
    /// Global.
    public internal(set) var pins: [PinnedSite] = []
    /// Global, newest first.
    public internal(set) var shelf: [ShelfEntry] = []
    /// What "Clear all" just took off the shelf, waiting on Undo. Not saved. See ShelfClear.swift.
    public internal(set) var clearedShelf: [ShelfEntry] = []
    /// Global, newest first.
    public internal(set) var history: [HistoryEntry] = []
    /// Lifetime usage per site key.
    public private(set) var siteStats: [SiteKey: Usage] = [:]
    /// Global, in the order they were created. See Groups.swift.
    public internal(set) var groups: [SiteGroup] = []
    @ObservationIgnored public var onEvent: ((StoreEvent) -> Void)?

    /// Accumulated co-open time per pair of site keys (Groups.swift). Not observed: it changes on
    /// every tick. `qualifiedPairs` (observed) changes only when a pair crosses the threshold.
    @ObservationIgnored var coOpen: [CoOpenPair: CoOpenStat] = [:]
    var qualifiedPairs: Set<CoOpenPair> = []
    /// Suggested sets the user dismissed, each sorted by host, oldest first.
    var dismissedSuggestions: [[SiteKey]] = []
    @ObservationIgnored var coOpenUnsaved: TimeInterval = 0
    @ObservationIgnored var suggestionCache: [WindowID: (signature: Int, result: GroupSuggestion?)] = [:]

    static let historyCap = 20_000
    static let closedCap = 50

    @ObservationIgnored let identity: any SiteIdentifying
    @ObservationIgnored let namer: any PageNaming
    @ObservationIgnored private var fader: any FadeEvaluating
    @ObservationIgnored private let storageDirectory: URL?
    @ObservationIgnored let now: @Sendable () -> Date

    /// Pages closed by hand, oldest first.
    @ObservationIgnored private(set) var closed: [ClosedPage] = []
    /// The history entry for each page's current visit.
    @ObservationIgnored var latestHistory: [PageID: UUID] = [:]
    @ObservationIgnored private var pendingEvents: [StoreEvent] = []
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    /// How long a change may wait before it is written to disk.
    @ObservationIgnored var autosaveDelay: Duration = .seconds(1)
    /// Where a corrupt or unknown-version state file was moved to during `init`, if that happened.
    @ObservationIgnored public private(set) var recoveredCorruptFile: URL?

    public init(identity: any SiteIdentifying, namer: any PageNaming, fader: any FadeEvaluating,
                storageDirectory: URL?, now: @escaping @Sendable () -> Date = { Date() }) {
        self.identity = identity
        self.namer = namer
        self.fader = fader
        self.storageDirectory = storageDirectory
        self.now = now
        load()
    }

    // MARK: - Windows

    @discardableResult public func createWindow() -> WindowID {
        let window = WindowState()
        windows.append(window)
        commit()
        return window.id
    }

    /// Closes a window. Its sites go to the shelf (one `.pagesShelved` per site).
    public func closeWindow(_ id: WindowID) {
        guard let wi = windows.firstIndex(where: { $0.id == id }) else { return }
        let window = windows.remove(at: wi)
        for site in window.sites {
            addToShelf(site.pages, key: site.key, name: site.name)
        }
        commit()
    }

    public func window(_ id: WindowID) -> WindowState? {
        windows.first { $0.id == id }
    }

    public func setFrame(_ frame: [Double], for id: WindowID) {
        guard let wi = windows.firstIndex(where: { $0.id == id }), windows[wi].frame != frame else { return }
        windows[wi].frame = frame
        commit()
    }

    // MARK: - Pages

    /// Opens a page. Emits `.pageOpened` (the shell loads `page.url`), then `.selectionChanged`
    /// when the page was selected. A page opened into a window with nothing selected is always
    /// selected. An unknown window is ignored and the returned id refers to nothing.
    @discardableResult
    public func openPage(url: URL, in window: WindowID, select: Bool = true, opener: PageID? = nil) -> PageID {
        let page = Page(url: url, name: "", usage: Usage(at: now()))
        guard let wi = windows.firstIndex(where: { $0.id == window }) else { return page.id }
        var w = windows[wi]
        let key = identity.key(for: url)
        insert(page, key: key, siteName: nil, into: &w, at: opener.map { .after($0) } ?? .end)
        emit(.pageOpened(page.id, window: window))
        if select || w.selectedPageID == nil {
            focus(page.id, in: &w, countPageVisit: false)
            emit(.selectionChanged(window))
        }
        windows[wi] = w
        if let stored = w.page(page.id) { recordHistory(for: stored, key: key, title: stored.rawTitle) }
        commit()
        return page.id
    }

    /// Closes a page by hand. It stays in history and can be reopened, but does not go to the shelf.
    /// A pin's page cannot be closed (unpin it first); shelved pages are removed with `removeFromShelf`.
    public func closePage(_ id: PageID) {
        guard let loc = findPage(id) else { return }
        var w = windows[loc.w]
        guard let d = detach(id, from: &w) else { return }
        pushClosed(d, window: w.id)
        emit(.pageClosed(id))
        repair(&w, removed: [id], sameSite: d.siteRemoved ? nil : (d.siteID, d.pageIndex))
        windows[loc.w] = w
        commit()
    }

    /// Closes every page of a site by hand, as `closePage` would one at a time.
    public func closeSite(_ id: SiteID) {
        guard let loc = findSite(id) else { return }
        var w = windows[loc.w]
        let site = w.sites.remove(at: loc.s)
        for (index, page) in site.pages.enumerated() {
            pushClosed(Detached(page: page, siteIndex: loc.s, pageIndex: index, siteID: site.id, key: site.key,
                                siteName: site.name, siteRemoved: true), window: w.id)
            emit(.pageClosed(page.id))
        }
        repair(&w, removed: Set(site.pages.map(\.id)))
        windows[loc.w] = w
        commit()
    }

    /// Brings back the most recently closed page, with the same id, into `window`: at its old
    /// position when its old site is still on that window's bar, otherwise where a newly opened
    /// page would go. Emits `.pageOpened`, `.navigate`, `.selectionChanged`.
    @discardableResult public func reopenClosedPage(in window: WindowID) -> PageID? {
        guard let wi = windows.firstIndex(where: { $0.id == window }), let entry = closed.popLast() else { return nil }
        var w = windows[wi]
        var page = entry.page
        page.fade = .live
        insert(page, key: entry.key, siteName: entry.siteName, into: &w, at: .exact(site: entry.siteID, index: entry.index))
        emit(.pageOpened(page.id, window: window))
        emit(.navigate(page.id, page.url))
        focus(page.id, in: &w)
        emit(.selectionChanged(window))
        windows[wi] = w
        if let stored = w.page(page.id) { recordHistory(for: stored, key: entry.key, title: stored.rawTitle) }
        commit()
        return page.id
    }

    /// Selects a page on this window's bar, or a pin's page. Records a visit. Selecting the page
    /// that is already selected does nothing.
    public func select(_ page: PageID, in window: WindowID) {
        guard let wi = windows.firstIndex(where: { $0.id == window }) else { return }
        var w = windows[wi]
        guard w.selectedPageID != page else { return }
        guard w.page(page) != nil || pins.contains(where: { $0.page.id == page }) else { return }
        focus(page, in: &w)
        emit(.selectionChanged(window))
        windows[wi] = w
        commit()
    }

    /// Selects the site's current page.
    public func selectSite(_ site: SiteID, in window: WindowID) {
        guard let s = self.window(window)?.sites.first(where: { $0.id == site }) else { return }
        select(s.currentPage.id, in: window)
    }

    public func selectPin(_ pin: SiteID, in window: WindowID) {
        guard let p = pins.first(where: { $0.id == pin }) else { return }
        select(p.page.id, in: window)
    }

    /// ⌘1…⌘9: the number-th page in `BarOrder.pageOrder`. Out of range does nothing.
    /// While a group is focused only `visibleSites(in:)` count (pins still first).
    public func selectByShortcut(_ number: Int, in window: WindowID) {
        guard (1...9).contains(number), self.window(window) != nil else { return }
        let order = BarOrder.pageOrder(pins: pins, sites: visibleSites(in: window))
        guard number <= order.count else { return }
        select(order[number - 1], in: window)
    }

    /// Moves the selection through `BarOrder.pageOrder` (pins included), wrapping at both ends.
    /// While a group is focused only `visibleSites(in:)` count.
    public func selectAdjacent(offset: Int, in window: WindowID) {
        guard offset != 0, let w = self.window(window) else { return }
        let order = BarOrder.pageOrder(pins: pins, sites: visibleSites(in: window))
        guard !order.isEmpty else { return }
        let target: Int
        if let selected = w.selectedPageID, let index = order.firstIndex(of: selected) {
            target = (((index + offset) % order.count) + order.count) % order.count
        } else {
            target = offset > 0 ? 0 : order.count - 1
        }
        select(order[target], in: window)
    }

    /// The page reports where it is and what it is called. A URL on a different site moves the
    /// page to that site's place on the bar; a pin's page accepts any URL and stays a pin.
    public func pageDidUpdate(_ id: PageID, url: URL?, title: String?, siteNameHint: String?) {
        let hint = siteNameHint.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }

        if let loc = findPage(id) {
            var w = windows[loc.w]
            var page = w.sites[loc.s].pages[loc.p]
            let oldKey = w.sites[loc.s].key
            var urlChanged = false
            if let url, url != page.url { page.url = url; urlChanged = true }
            if let title { page.rawTitle = title }
            let key = urlChanged ? identity.key(for: page.url) : oldKey
            w.sites[loc.s].pages[loc.p] = page
            if key != oldKey, let d = detach(id, from: &w) {
                // Same bar position where that makes sense: in place of the old site when the page
                // was its only one, otherwise right after it. An existing site for the key wins.
                insert(d.page, key: key, siteName: nil, into: &w, at: .newSiteAt(d.siteRemoved ? d.siteIndex : d.siteIndex + 1))
                if w.selectedPageID == id, let at = indices(of: id, in: w) {
                    w.sites[at.s].currentPageID = id
                    w.sites[at.s].fade = .live
                    visitStats(key)
                }
            }
            if let at = indices(of: id, in: w) {
                if let hint, hint != w.sites[at.s].name {
                    w.sites[at.s].name = hint
                    for pi in w.sites[at.s].pages.indices {
                        w.sites[at.s].pages[pi].name = displayName(w.sites[at.s].pages[pi], siteName: hint)
                    }
                } else {
                    w.sites[at.s].pages[at.p].name = displayName(w.sites[at.s].pages[at.p], siteName: w.sites[at.s].name)
                }
                let stored = w.sites[at.s].pages[at.p]
                if urlChanged {
                    recordHistory(for: stored, key: key, title: title ?? "")
                } else if title != nil {
                    syncHistoryTitle(stored, siteName: w.sites[at.s].name)
                }
            }
            windows[loc.w] = w
            commit()
        } else if let pi = pins.firstIndex(where: { $0.page.id == id }) {
            var pin = pins[pi]
            var urlChanged = false
            if let url, url != pin.page.url { pin.page.url = url; urlChanged = true }
            if let title { pin.page.rawTitle = title }
            let key = identity.key(for: pin.page.url)
            if let hint, key == pin.key { pin.name = hint }
            pin.page.name = displayName(pin.page, siteName: pin.name)
            pins[pi] = pin
            if urlChanged {
                recordHistory(for: pin.page, key: key, title: title ?? "")
            } else if title != nil {
                syncHistoryTitle(pin.page, siteName: pin.name)
            }
            commit()
        } else if let loc = findShelved(id) {
            // A suspended page may still report. It never changes site while on the shelf.
            var entry = shelf[loc.e]
            if let url, identity.key(for: url) == entry.key { entry.pages[loc.p].url = url }
            if let title { entry.pages[loc.p].rawTitle = title }
            entry.pages[loc.p].name = displayName(entry.pages[loc.p], siteName: entry.name)
            shelf[loc.e] = entry
            commit()
        }
    }

    public func pageDidScroll(_ id: PageID, y: Double) {
        guard y.isFinite else { return }
        if let loc = findPage(id) {
            guard windows[loc.w].sites[loc.s].pages[loc.p].scrollY != y else { return }
            windows[loc.w].sites[loc.s].pages[loc.p].scrollY = y
        } else if let pi = pins.firstIndex(where: { $0.page.id == id }) {
            guard pins[pi].page.scrollY != y else { return }
            pins[pi].page.scrollY = y
        } else {
            return
        }
        commit()
    }

    /// Adds frontmost time to the page and to the history entry for its current visit.
    public func recordDwell(_ id: PageID, seconds: TimeInterval) {
        guard seconds.isFinite, seconds > 0 else { return }
        if let loc = findPage(id) {
            windows[loc.w].sites[loc.s].pages[loc.p].dwell += seconds
        } else if let pi = pins.firstIndex(where: { $0.page.id == id }) {
            pins[pi].page.dwell += seconds
        } else {
            return
        }
        if let entryID = latestHistory[id], let hi = history.firstIndex(where: { $0.id == entryID }) {
            history[hi].dwell += seconds
        }
        commit()
    }

    /// Gives a page a name of the user's own. nil or blank goes back to the derived name.
    public func rename(_ id: PageID, to name: String?) {
        let custom = name.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        if let loc = findPage(id) {
            var page = windows[loc.w].sites[loc.s].pages[loc.p]
            page.customName = custom
            page.name = displayName(page, siteName: windows[loc.w].sites[loc.s].name)
            windows[loc.w].sites[loc.s].pages[loc.p] = page
        } else if let pi = pins.firstIndex(where: { $0.page.id == id }) {
            pins[pi].page.customName = custom
            pins[pi].page.name = displayName(pins[pi].page, siteName: pins[pi].name)
        } else if let loc = findShelved(id) {
            shelf[loc.e].pages[loc.p].customName = custom
            shelf[loc.e].pages[loc.p].name = displayName(shelf[loc.e].pages[loc.p], siteName: shelf[loc.e].name)
        } else {
            return
        }
        commit()
    }

    /// Asks the shell to load `url` in an existing page. State changes when the page reports
    /// back through `pageDidUpdate`.
    public func navigate(_ id: PageID, to url: URL) {
        guard page(id) != nil else { return }
        emit(.navigate(id, url))
        commit(mutated: false)
    }

    /// A page on any window's bar, or a pin's page. Shelved pages are not found here.
    public func page(_ id: PageID) -> Page? {
        if let loc = findPage(id) { return windows[loc.w].sites[loc.s].pages[loc.p] }
        return pins.first { $0.page.id == id }?.page
    }

    /// The window whose bar holds the page. For a pin's page: the first window showing it, if any.
    public func windowID(containing page: PageID) -> WindowID? {
        if let loc = findPage(page) { return windows[loc.w].id }
        if pins.contains(where: { $0.page.id == page }) {
            return windows.first { $0.selectedPageID == page }?.id
        }
        return nil
    }

    // MARK: - Sites

    public func setKept(_ site: SiteID, _ kept: Bool) {
        guard let loc = findSite(site) else { return }
        var s = windows[loc.w].sites[loc.s]
        s.isKept = kept
        if kept {
            s.fade = .live
            for pi in s.pages.indices { s.pages[pi].fade = .live }
        }
        windows[loc.w].sites[loc.s] = s
        commit()
    }

    /// `toIndex` is the site's index in the bar once the move is done; it is clamped.
    public func moveSite(_ site: SiteID, toIndex: Int, in window: WindowID) {
        guard let wi = windows.firstIndex(where: { $0.id == window }),
              let si = windows[wi].sites.firstIndex(where: { $0.id == site }) else { return }
        var sites = windows[wi].sites
        let moved = sites.remove(at: si)
        sites.insert(moved, at: min(max(toIndex, 0), sites.count))
        windows[wi].sites = sites
        commit()
    }

    /// Reorders a page inside its own site. `toIndex` is the page's index in the site's `pages`
    /// once the move is done; it is clamped. Pins and shelved pages are ignored.
    public func movePage(_ page: PageID, toIndex: Int) {
        guard let loc = findPage(page) else { return }
        var pages = windows[loc.w].sites[loc.s].pages
        let moved = pages.remove(at: loc.p)
        let target = min(max(toIndex, 0), pages.count)
        guard target != loc.p else { return }
        pages.insert(moved, at: target)
        windows[loc.w].sites[loc.s].pages = pages
        commit()
    }

    /// The site's current page becomes a pin (same page id, new site id); its other pages stay
    /// as an ordinary site. Does nothing when the site's key is already pinned.
    public func pin(site: SiteID) {
        guard let loc = findSite(site) else { return }
        var w = windows[loc.w]
        let s = w.sites[loc.s]
        guard !pins.contains(where: { $0.key == s.key }) else { return }
        let pageID = s.currentPage.id
        guard let d = detach(pageID, from: &w) else { return }
        var page = d.page
        page.fade = .live
        pins.append(PinnedSite(key: s.key, name: s.name, homeURL: page.url, page: page))
        if let split = w.split, split.contains(pageID) {
            // A pin cannot be half of a split.
            if let selected = w.selectedPageID, split.contains(selected) { emit(.selectionChanged(w.id)) }
            w.split = nil
        }
        windows[loc.w] = w
        commit()
    }

    /// The pin becomes an ordinary site at the start of `window`'s bar (or joins the site with
    /// its key). Other windows that were showing the pin fall back to their most recent page.
    public func unpin(_ pin: SiteID, into window: WindowID) {
        guard let pi = pins.firstIndex(where: { $0.id == pin }),
              let wi = windows.firstIndex(where: { $0.id == window }) else { return }
        let removed = pins.remove(at: pi)
        let pageID = removed.page.id
        var w = windows[wi]
        // The page may have wandered (a sign-in host, say): file it under where it actually is.
        let key = identity.key(for: removed.page.url)
        insert(removed.page, key: key, siteName: key == removed.key ? removed.name : nil, into: &w, at: .start)
        if w.selectedPageID == nil {
            focus(pageID, in: &w)
            emit(.selectionChanged(w.id))
        } else if w.selectedPageID == pageID, let at = indices(of: pageID, in: w) {
            w.sites[at.s].currentPageID = pageID
        }
        windows[wi] = w
        for oi in windows.indices where oi != wi && windows[oi].selectedPageID == pageID {
            var other = windows[oi]
            other.selectedPageID = nil
            if let next = mostRecentPage(in: other) { focus(next, in: &other) }
            emit(.selectionChanged(other.id))
            windows[oi] = other
        }
        commit()
    }

    /// Sends the pin back to its home URL (emits `.navigate`).
    public func resetPin(_ pin: SiteID) {
        guard let p = pins.first(where: { $0.id == pin }) else { return }
        emit(.navigate(p.page.id, p.homeURL))
        commit(mutated: false)
    }

    // MARK: - Split view

    /// Shows two pages of this window's bar side by side, `page` leading. Focus stays where it
    /// is when it is on one of the two, otherwise moves to `page`. Pins cannot be split.
    public func split(_ page: PageID, with other: PageID, in window: WindowID) {
        guard page != other, let wi = windows.firstIndex(where: { $0.id == window }) else { return }
        var w = windows[wi]
        guard w.page(page) != nil, w.page(other) != nil else { return }
        w.split = SplitPair(leading: page, trailing: other, fraction: w.split?.fraction ?? 0.5)
        if let selected = w.selectedPageID, selected == page || selected == other {
            // Focus stays; the partner is now on screen too.
        } else {
            focus(page, in: &w)
        }
        for id in [page, other] {
            if let at = indices(of: id, in: w) {
                w.sites[at.s].pages[at.p].fade = .live
                w.sites[at.s].fade = .live
            }
        }
        emit(.selectionChanged(window))
        windows[wi] = w
        commit()
    }

    public func endSplit(in window: WindowID) {
        guard let wi = windows.firstIndex(where: { $0.id == window }), windows[wi].split != nil else { return }
        windows[wi].split = nil
        emit(.selectionChanged(window))
        commit()
    }

    /// Clamped to 0.2...0.8.
    public func setSplitFraction(_ f: Double, in window: WindowID) {
        guard f.isFinite, let wi = windows.firstIndex(where: { $0.id == window }), windows[wi].split != nil else { return }
        windows[wi].split?.fraction = min(max(f, 0.2), 0.8)
        commit()
    }

    // MARK: - Fading and the shelf

    /// Replaces the fader (a settings change). Call `runFade()` afterwards to apply it.
    public func setFader(_ fader: any FadeEvaluating) { self.fader = fader }

    /// Evaluates every window, applies the verdicts and returns the earliest `nextCheck`.
    /// Whatever the fader says, a page that is on screen (and the site holding it) is never shelved.
    @discardableResult public func runFade() -> Date? {
        var next: Date?
        let t = now()
        for wi in windows.indices {
            var w = windows[wi]
            let visible = w.visiblePageIDs
            let verdict = fader.evaluate(sites: w.sites, stats: siteStats, visible: visible, now: t)
            if let check = verdict.nextCheck { next = next.map { min($0, check) } ?? check }

            for si in w.sites.indices {
                if let stage = verdict.siteStages[w.sites[si].id] { w.sites[si].fade = stage }
                for pi in w.sites[si].pages.indices {
                    if let stage = verdict.pageStages[w.sites[si].pages[pi].id] { w.sites[si].pages[pi].fade = stage }
                }
            }

            var removed = Set<PageID>()
            for siteID in verdict.sitesToShelve {
                guard let si = w.sites.firstIndex(where: { $0.id == siteID }),
                      !w.sites[si].pages.contains(where: { visible.contains($0.id) }) else { continue }
                let site = w.sites.remove(at: si)
                removed.formUnion(site.pages.map(\.id))
                addToShelf(site.pages, key: site.key, name: site.name)
            }
            let wanted = Set(verdict.pagesToShelve).subtracting(visible)
            if !wanted.isEmpty {
                for site in w.sites {
                    let leaving = site.pages.filter { wanted.contains($0.id) }
                    guard !leaving.isEmpty else { continue }
                    for page in leaving { _ = detach(page.id, from: &w) }
                    removed.formUnion(leaving.map(\.id))
                    addToShelf(leaving, key: site.key, name: site.name)
                }
            }
            repair(&w, removed: removed)
            windows[wi] = w
        }
        commit()
        return next
    }

    /// Puts a whole site away by hand, kept or not, on screen or not.
    public func shelve(site: SiteID) {
        guard let loc = findSite(site) else { return }
        var w = windows[loc.w]
        let s = w.sites.remove(at: loc.s)
        addToShelf(s.pages, key: s.key, name: s.name)
        repair(&w, removed: Set(s.pages.map(\.id)))
        windows[loc.w] = w
        commit()
    }

    /// Brings shelved pages back onto `window`'s bar, live, with the same ids. `page` nil restores
    /// the whole entry. The restored page (or the most recently used of them) is selected.
    /// Emits `.pagesRestored` then `.selectionChanged`.
    @discardableResult public func restore(entry: SiteID, page: PageID?, into window: WindowID) -> [PageID] {
        guard let ei = shelf.firstIndex(where: { $0.id == entry }),
              let wi = windows.firstIndex(where: { $0.id == window }) else { return [] }
        var e = shelf[ei]
        var pages: [Page]
        if let page {
            guard let pi = e.pages.firstIndex(where: { $0.id == page }) else { return [] }
            pages = [e.pages.remove(at: pi)]
        } else {
            pages = e.pages
            e.pages = []
        }
        if e.pages.isEmpty { shelf.remove(at: ei) } else { shelf[ei] = e }

        var w = windows[wi]
        for i in pages.indices {
            pages[i].fade = .live
            insert(pages[i], key: e.key, siteName: e.name, into: &w, at: .end)
        }
        let ids = pages.map(\.id)
        emit(.pagesRestored(ids, window: window))
        var best = pages[0]
        for p in pages.dropFirst() where p.usage.lastUsed > best.usage.lastUsed { best = p }
        focus(best.id, in: &w)
        emit(.selectionChanged(window))
        windows[wi] = w
        commit()
        return ids
    }

    /// Deletes shelved pages for good (`page` nil = the whole entry). Emits `.pageClosed` for each
    /// so their suspended web views are destroyed. They cannot be reopened.
    public func removeFromShelf(entry: SiteID, page: PageID?) {
        guard let ei = shelf.firstIndex(where: { $0.id == entry }) else { return }
        var e = shelf[ei]
        let gone: [Page]
        if let page {
            guard let pi = e.pages.firstIndex(where: { $0.id == page }) else { return }
            gone = [e.pages.remove(at: pi)]
        } else {
            gone = e.pages
            e.pages = []
        }
        if e.pages.isEmpty { shelf.remove(at: ei) } else { shelf[ei] = e }
        for p in gone {
            latestHistory[p.id] = nil
            emit(.pageClosed(p.id))
        }
        commit()
    }

    // MARK: - Persistence

    /// Writes `state.json` now. Does nothing without a storage directory.
    public func save() throws {
        saveTask?.cancel()
        saveTask = nil
        guard let storageDirectory else { return }
        var stats: [String: Usage] = [:]
        for (key, usage) in siteStats { stats[key.host] = usage }
        var latest: [String: UUID] = [:]
        for (page, entry) in latestHistory { latest[page.raw.uuidString] = entry }
        let snapshot = StoreSnapshot(version: StoreSnapshot.currentVersion, windows: windows, pins: pins, shelf: shelf,
                                     history: history, siteStats: stats, closed: closed, latestHistory: latest,
                                     groups: groups, coOpen: coOpenRecordsForSaving(),
                                     dismissedSuggestions: dismissedSuggestions.map { $0.map(\.host) })
        let data = try snapshot.encoded()
        try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
        try data.write(to: storageDirectory.appendingPathComponent(StoreSnapshot.fileName), options: .atomic)
    }

    /// Synchronous save for app termination. Errors are swallowed.
    public func flush() {
        try? save()
    }

    private func load() {
        guard let storageDirectory else { return }
        let file = storageDirectory.appendingPathComponent(StoreSnapshot.fileName)
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        let snapshot: StoreSnapshot
        do {
            snapshot = try StoreSnapshot.decode(try Data(contentsOf: file))
        } catch {
            recoveredCorruptFile = StoreSnapshot.moveAside(file, now: now())
            return
        }
        windows = snapshot.windows
        pins = snapshot.pins
        shelf = snapshot.shelf
        history = snapshot.history
        closed = snapshot.closed
        var stats: [SiteKey: Usage] = [:]
        for (host, usage) in snapshot.siteStats { stats[SiteKey(host)] = usage }
        siteStats = stats
        for (page, entry) in snapshot.latestHistory ?? [:] {
            if let uuid = UUID(uuidString: page) { latestHistory[PageID(uuid)] = entry }
        }
        groups = snapshot.groups ?? []
        dismissedSuggestions = (snapshot.dismissedSuggestions ?? []).map { $0.map(SiteKey.init) }
        loadCoOpen(snapshot.coOpen ?? [])
        sanitize()
    }

    /// Makes loaded state obey the invariants without throwing anything away that can be kept:
    /// a file written under older site rules, or edited by hand, must still open.
    func sanitize() {
        var seenPages = Set<PageID>()
        var seenSites = Set<SiteID>()
        var seenWindows = Set<WindowID>()

        var keptPins: [PinnedSite] = []
        for var pin in pins where seenPages.insert(pin.page.id).inserted && !keptPins.contains(where: { $0.key == pin.key }) {
            if !seenSites.insert(pin.id).inserted {
                pin = PinnedSite(key: pin.key, name: pin.name, homeURL: pin.homeURL, page: pin.page)
                seenSites.insert(pin.id)
            }
            pin.page.fade = .live
            if pin.page.name.isEmpty { pin.page.name = displayName(pin.page, siteName: pin.name) }
            keptPins.append(pin)
        }
        if keptPins != pins { pins = keptPins }

        var keptWindows: [WindowState] = []
        for old in windows where seenWindows.insert(old.id).inserted {
            var w = old
            w.sites = []
            for site in old.sites {
                for page in site.pages where seenPages.insert(page.id).inserted {
                    let key = identity.key(for: page.url)
                    if key == site.key, !w.sites.contains(where: { $0.key == key }) {
                        // First page of a site that is where it belongs: the site keeps its identity.
                        let id = seenSites.insert(site.id).inserted ? site.id : SiteID()
                        seenSites.insert(id)
                        var p = page
                        if p.name.isEmpty { p.name = displayName(p, siteName: site.name) }
                        w.sites.append(Site(id: id, key: key, name: site.name, pages: [p], currentPageID: site.currentPageID,
                                            isKept: site.isKept, fade: site.fade))
                    } else {
                        insert(page, key: key, siteName: key == site.key ? site.name : nil, into: &w, at: .end)
                    }
                }
            }
            for si in w.sites.indices {
                if !seenSites.contains(w.sites[si].id) { seenSites.insert(w.sites[si].id) }
                if !w.sites[si].pages.contains(where: { $0.id == w.sites[si].currentPageID }) {
                    w.sites[si].currentPageID = w.sites[si].pages[w.sites[si].pages.count - 1].id
                }
            }
            if let split = w.split {
                if split.leading == split.trailing || w.page(split.leading) == nil || w.page(split.trailing) == nil {
                    w.split = nil
                } else {
                    w.split?.fraction = split.fraction.isFinite ? min(max(split.fraction, 0.2), 0.8) : 0.5
                }
            }
            if let selected = w.selectedPageID, w.page(selected) == nil, !pins.contains(where: { $0.page.id == selected }) {
                w.selectedPageID = nil
            }
            if w.selectedPageID == nil, let next = mostRecentPage(in: w) {
                w.selectedPageID = next
            }
            if let selected = w.selectedPageID, let at = indices(of: selected, in: w) {
                w.sites[at.s].currentPageID = selected
            }
            keptWindows.append(w)
        }
        if keptWindows != windows { windows = keptWindows }

        var keptShelf: [ShelfEntry] = []
        for entry in shelf {
            for page in entry.pages where seenPages.insert(page.id).inserted {
                let key = identity.key(for: page.url)
                if let i = keptShelf.firstIndex(where: { $0.key == key }) {
                    keptShelf[i].pages.append(page)
                    keptShelf[i].shelvedAt = max(keptShelf[i].shelvedAt, entry.shelvedAt)
                } else {
                    let reuse = key == entry.key && seenSites.insert(entry.id).inserted
                    let fresh = ShelfEntry(id: reuse ? entry.id : SiteID(), key: key,
                                           name: key == entry.key ? entry.name : identity.siteName(for: key),
                                           pages: [page], shelvedAt: entry.shelvedAt)
                    seenSites.insert(fresh.id)
                    keptShelf.append(fresh)
                }
            }
        }
        if keptShelf != shelf { shelf = keptShelf }

        if history.count > Self.historyCap { history.removeLast(history.count - Self.historyCap) }
        closed.removeAll { !seenPages.insert($0.page.id).inserted }
        if closed.count > Self.closedCap { closed.removeFirst(closed.count - Self.closedCap) }
        sanitizeGroups()
        normalizeFocus()
        ensureStats()
    }

    // MARK: - Invariants

    /// Every rule the state must obey. Empty means all is well.
    public func checkInvariants() -> [String] {
        var problems: [String] = []
        var pageIDs = Set<PageID>()
        var siteIDs = Set<SiteID>()
        var windowIDs = Set<WindowID>()
        var pinKeys = Set<SiteKey>()

        for pin in pins {
            if !pageIDs.insert(pin.page.id).inserted { problems.append("duplicate page id (pin \(pin.name))") }
            if !siteIDs.insert(pin.id).inserted { problems.append("duplicate site id (pin \(pin.name))") }
            if !pinKeys.insert(pin.key).inserted { problems.append("two pins for \(pin.key.host)") }
            if pin.page.name.isEmpty { problems.append("pin page with empty name") }
            if pin.page.fade != .live { problems.append("pin \(pin.name) is fading") }
            if siteStats[pin.key] == nil { problems.append("no stats for pin \(pin.key.host)") }
        }
        let pinPages = Set(pins.map(\.page.id))

        for w in windows {
            if !windowIDs.insert(w.id).inserted { problems.append("duplicate window id") }
            var keys = Set<SiteKey>()
            var local = Set<PageID>()
            for site in w.sites {
                if !siteIDs.insert(site.id).inserted { problems.append("duplicate site id (\(site.name))") }
                if !keys.insert(site.key).inserted { problems.append("two sites for \(site.key.host) in one window") }
                if site.pages.isEmpty { problems.append("empty site \(site.name)") }
                if !site.pages.contains(where: { $0.id == site.currentPageID }) { problems.append("site \(site.name): currentPageID is not one of its pages") }
                if site.name.isEmpty { problems.append("site with empty name (\(site.key.host))") }
                if siteStats[site.key] == nil { problems.append("no stats for \(site.key.host)") }
                for page in site.pages {
                    if !pageIDs.insert(page.id).inserted { problems.append("duplicate page id (\(page.name))") }
                    local.insert(page.id)
                    if page.name.isEmpty { problems.append("page with empty name (\(page.url.absoluteString))") }
                    if let custom = page.customName, custom != page.name { problems.append("page name ignores its custom name") }
                    if identity.key(for: page.url) != site.key { problems.append("page \(page.url.absoluteString) sits in site \(site.key.host)") }
                }
            }
            if let selected = w.selectedPageID {
                if !local.contains(selected) && !pinPages.contains(selected) { problems.append("selectedPageID refers to no page") }
                if let site = w.site(containing: selected), site.currentPageID != selected { problems.append("selected page is not its site's current page") }
            } else if !w.sites.isEmpty {
                problems.append("window has pages but nothing selected")
            }
            if let split = w.split {
                if !local.contains(split.leading) || !local.contains(split.trailing) { problems.append("split refers to a page not in the window") }
                if split.leading == split.trailing { problems.append("split of a page with itself") }
                if !(0.2...0.8).contains(split.fraction) { problems.append("split fraction out of range") }
            }
            if let frame = w.frame, frame.count != 4 { problems.append("window frame is not four numbers") }
        }

        var shelfKeys = Set<SiteKey>()
        for entry in shelf {
            if !siteIDs.insert(entry.id).inserted { problems.append("duplicate site id (shelf \(entry.name))") }
            if !shelfKeys.insert(entry.key).inserted { problems.append("two shelf entries for \(entry.key.host)") }
            if entry.pages.isEmpty { problems.append("empty shelf entry \(entry.name)") }
            for page in entry.pages {
                if !pageIDs.insert(page.id).inserted { problems.append("duplicate page id (shelved \(page.name))") }
                if identity.key(for: page.url) != entry.key { problems.append("shelved page \(page.url.absoluteString) sits in entry \(entry.key.host)") }
            }
        }

        for entry in closed where !pageIDs.insert(entry.page.id).inserted {
            problems.append("closed page is also somewhere else")
        }
        if closed.count > Self.closedCap { problems.append("closed stack over its cap") }
        if history.count > Self.historyCap { problems.append("history over its cap") }
        problems += groupProblems()
        return problems
    }

    // MARK: - Internals: finding

    func findPage(_ id: PageID) -> (w: Int, s: Int, p: Int)? {
        for wi in windows.indices {
            if let at = indices(of: id, in: windows[wi]) { return (wi, at.s, at.p) }
        }
        return nil
    }

    private func findSite(_ id: SiteID) -> (w: Int, s: Int)? {
        for wi in windows.indices {
            if let si = windows[wi].sites.firstIndex(where: { $0.id == id }) { return (wi, si) }
        }
        return nil
    }

    func findShelved(_ id: PageID) -> (e: Int, p: Int)? {
        for ei in shelf.indices {
            if let pi = shelf[ei].pages.firstIndex(where: { $0.id == id }) { return (ei, pi) }
        }
        return nil
    }

    func indices(of id: PageID, in w: WindowState) -> (s: Int, p: Int)? {
        for si in w.sites.indices {
            if let pi = w.sites[si].pages.firstIndex(where: { $0.id == id }) { return (si, pi) }
        }
        return nil
    }

    /// The most recently used page on the window's bar. Ties go to the one furthest right.
    func mostRecentPage(in w: WindowState) -> PageID? {
        var best: Page?
        for site in w.sites {
            for page in site.pages where best == nil || page.usage.lastUsed >= best!.usage.lastUsed {
                best = page
            }
        }
        return best?.id
    }

    // MARK: - Internals: placing and removing pages

    private enum Placement {
        /// A new site goes at the end of the bar.
        case end
        /// A new site goes at the start of the bar.
        case start
        /// Next to the opener: right after it within its own site, or a new site right after the opener's.
        case after(PageID)
        /// A new site goes at this index.
        case newSiteAt(Int)
        /// Back into this site at this page index, when the site is still there.
        case exact(site: SiteID, index: Int)
    }

    private struct Detached {
        var page: Page
        var siteIndex: Int
        var pageIndex: Int
        var siteID: SiteID
        var key: SiteKey
        var siteName: String
        var siteRemoved: Bool
    }

    func displayName(_ page: Page, siteName: String) -> String {
        if let custom = page.customName, !custom.isEmpty { return custom }
        let derived = namer.name(title: page.rawTitle, url: page.url, siteName: siteName)
        return derived.isEmpty ? page.url.absoluteString : derived
    }

    /// Puts a page on a window's bar: into the site with its key when there is one, otherwise
    /// into a new site. Does not touch selection.
    private func insert(_ page: Page, key: SiteKey, siteName: String?, into w: inout WindowState, at placement: Placement) {
        var page = page
        if let si = w.sites.firstIndex(where: { $0.key == key }) {
            page.name = displayName(page, siteName: w.sites[si].name)
            var at = w.sites[si].pages.count
            switch placement {
            case .after(let opener):
                if let oi = w.sites[si].pages.firstIndex(where: { $0.id == opener }) { at = oi + 1 }
            case .exact(let siteID, let index):
                if w.sites[si].id == siteID { at = min(max(index, 0), at) }
            default:
                break
            }
            w.sites[si].pages.insert(page, at: at)
            return
        }
        var name = siteName ?? identity.siteName(for: key)
        if name.isEmpty { name = key.host.isEmpty ? "Site" : key.host }
        page.name = displayName(page, siteName: name)
        var at = w.sites.count
        switch placement {
        case .start:
            at = 0
        case .after(let opener):
            if let oi = w.sites.firstIndex(where: { site in site.pages.contains { $0.id == opener } }) { at = oi + 1 }
        case .newSiteAt(let index):
            at = min(max(index, 0), at)
        case .end, .exact:
            break
        }
        w.sites.insert(Site(key: key, name: name, pages: [page]), at: at)
    }

    /// Takes a page off a window's bar, removing its site when that leaves it empty.
    /// Does not touch selection or split: follow with `repair`.
    private func detach(_ id: PageID, from w: inout WindowState) -> Detached? {
        guard let at = indices(of: id, in: w) else { return nil }
        let site = w.sites[at.s]
        let page = w.sites[at.s].pages.remove(at: at.p)
        let emptied = w.sites[at.s].pages.isEmpty
        if emptied {
            w.sites.remove(at: at.s)
        } else if site.currentPageID == id {
            let pages = w.sites[at.s].pages
            w.sites[at.s].currentPageID = pages[min(at.p, pages.count - 1)].id
        }
        return Detached(page: page, siteIndex: at.s, pageIndex: at.p, siteID: site.id, key: site.key,
                        siteName: site.name, siteRemoved: emptied)
    }

    /// Makes a page the window's selection and records the visit.
    func focus(_ id: PageID, in w: inout WindowState, countPageVisit: Bool = true) {
        let t = now()
        if let at = indices(of: id, in: w) {
            if countPageVisit { w.sites[at.s].pages[at.p].usage.recordVisit(at: t) }
            w.sites[at.s].pages[at.p].fade = .live
            w.sites[at.s].fade = .live
            w.sites[at.s].currentPageID = id
            visitStats(w.sites[at.s].key)
        } else if let pi = pins.firstIndex(where: { $0.page.id == id }) {
            if countPageVisit { pins[pi].page.usage.recordVisit(at: t) }
            visitStats(pins[pi].key)
        } else {
            return
        }
        w.selectedPageID = id
    }

    /// After pages have left a window's bar: ends a split that lost a page and moves the
    /// selection off a page that is gone. Preference: the split partner, then a neighbour in
    /// the same site, then the most recently used page in the window.
    func repair(_ w: inout WindowState, removed: Set<PageID>, sameSite: (site: SiteID, index: Int)? = nil) {
        guard !removed.isEmpty else { return }
        var changed = false
        var partner: PageID?
        if let split = w.split, removed.contains(split.leading) || removed.contains(split.trailing) {
            if let selected = w.selectedPageID, split.contains(selected) {
                changed = true
                partner = split.other(than: selected)
            }
            w.split = nil
        }
        if let selected = w.selectedPageID, removed.contains(selected) {
            var next: PageID?
            if let partner, !removed.contains(partner), w.page(partner) != nil {
                next = partner
            } else if let sameSite, let site = w.sites.first(where: { $0.id == sameSite.site }) {
                next = site.pages[min(max(sameSite.index, 0), site.pages.count - 1)].id
            } else {
                next = mostRecentPage(in: w)
            }
            w.selectedPageID = nil
            if let next { focus(next, in: &w) }
            changed = true
        }
        if changed { emit(.selectionChanged(w.id)) }
    }

    private func pushClosed(_ d: Detached, window: WindowID) {
        latestHistory[d.page.id] = nil
        closed.append(ClosedPage(page: d.page, key: d.key, siteName: d.siteName, siteID: d.siteID, index: d.pageIndex, window: window))
        if closed.count > Self.closedCap { closed.removeFirst(closed.count - Self.closedCap) }
    }

    /// One shelf entry per site key; the entry that just received pages moves to the front.
    private func addToShelf(_ pages: [Page], key: SiteKey, name: String) {
        guard !pages.isEmpty else { return }
        let t = now()
        if let i = shelf.firstIndex(where: { $0.key == key }) {
            var entry = shelf.remove(at: i)
            entry.pages.insert(contentsOf: pages, at: 0)
            entry.shelvedAt = t
            entry.name = name
            shelf.insert(entry, at: 0)
        } else {
            shelf.insert(ShelfEntry(key: key, name: name, pages: pages, shelvedAt: t), at: 0)
        }
        emit(.pagesShelved(pages.map(\.id), key: key))
    }

    // MARK: - Internals: usage and history

    private func visitStats(_ key: SiteKey) {
        let t = now()
        if var usage = siteStats[key] {
            usage.recordVisit(at: t)
            siteStats[key] = usage
        } else {
            siteStats[key] = Usage(at: t)
        }
    }

    /// Every site on a bar and every pin has a usage record, visited yet or not.
    private func ensureStats() {
        let t = now()
        for w in windows {
            for site in w.sites where siteStats[site.key] == nil { siteStats[site.key] = Usage(at: t) }
        }
        for pin in pins where siteStats[pin.key] == nil { siteStats[pin.key] = Usage(at: t) }
    }

    private func recordHistory(for page: Page, key: SiteKey, title: String) {
        // Blank pages are not somewhere the user has been.
        guard page.url.scheme?.lowercased() != "about" else {
            latestHistory[page.id] = nil
            return
        }
        let entry = HistoryEntry(url: page.url, title: title, name: page.name, key: key, visitedAt: now())
        history.insert(entry, at: 0)
        if history.count > Self.historyCap { history.removeLast(history.count - Self.historyCap) }
        latestHistory[page.id] = entry.id
    }

    private func syncHistoryTitle(_ page: Page, siteName: String) {
        guard let entryID = latestHistory[page.id], let hi = history.firstIndex(where: { $0.id == entryID }) else { return }
        guard history[hi].title != page.rawTitle || history[hi].name != page.name else { return }
        history[hi].title = page.rawTitle
        history[hi].name = page.name
    }

    // MARK: - Internals: events and autosave

    func emit(_ event: StoreEvent) {
        pendingEvents.append(event)
    }

    /// Ends every action: tops up stats, schedules a save and delivers the events it queued.
    func commit(mutated: Bool = true) {
        if mutated {
            normalizeFocus()
            ensureStats()
            scheduleAutosave()
        }
        guard !pendingEvents.isEmpty else { return }
        let events = pendingEvents
        pendingEvents = []
        guard let onEvent else { return }
        for event in events { onEvent(event) }
    }

    /// At most one save is ever pending, so steady activity (scrolling) cannot starve it.
    func scheduleAutosave() {
        guard storageDirectory != nil, saveTask == nil else { return }
        let delay = autosaveDelay
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }
}

// MARK: - Clearing history

extension BrowserStore {
    /// Removes history entries from `date` on (all of them when nil). Open pages are untouched.
    /// Returns how many entries were removed.
    @discardableResult
    public func clearHistory(since date: Date?) -> Int {
        let before = history.count
        if let date { history.removeAll { $0.visitedAt >= date } } else { history.removeAll() }
        let alive = Set(history.map(\.id))
        latestHistory = latestHistory.filter { alive.contains($0.value) }
        commit()
        return before - history.count
    }
}
