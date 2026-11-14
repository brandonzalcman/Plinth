import Foundation
import PlinthModel

extension BrowserStore {
    /// The synced part of the store: pins, shelf and history. Windows never sync.
    public func syncPayload() -> SyncPayload {
        SyncPayload(pins: pins, shelf: shelf, history: history)
    }

    /// Replaces pins, shelf and history with the merged result from sync, keeping local state that
    /// is not synced:
    /// - Pins are matched by key. A matched pin keeps its local id and page (id, URL, scroll, usage,
    ///   custom name) and takes the remote name and home URL. A pin missing remotely is removed
    ///   (`.pageClosed`; windows showing it move to their most recent page with `.selectionChanged`).
    ///   A new remote pin gets a fresh page at its home URL and emits nothing: the web view is made
    ///   when it is first selected.
    /// - Shelf pages are matched by page id and keep their local fields. A local shelf page missing
    ///   remotely is removed (`.pageClosed`). A remote shelf page whose id is on a local bar (or is a
    ///   pin's page) is dropped from the shelf side.
    /// - History is replaced; each page's pointer to its current visit is kept while the entry exists.
    /// Then the same repairs as loading a file run.
    public func applySynced(_ payload: SyncPayload) {
        // Pins
        var localPins: [SiteKey: PinnedSite] = [:]
        for pin in pins where localPins[pin.key] == nil { localPins[pin.key] = pin }
        var localSiteIDs = Set(windows.flatMap { $0.sites.map(\.id) })
        localSiteIDs.formUnion(shelf.map(\.id))
        localSiteIDs.formUnion(pins.map(\.id))
        var newPins: [PinnedSite] = []
        for remote in payload.pins where !newPins.contains(where: { $0.key == remote.key }) {
            if var local = localPins[remote.key] {
                let name = remote.name.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { local.name = name }
                local.homeURL = remote.homeURL
                local.folder = remote.folder
                local.page.name = displayName(local.page, siteName: local.name)
                newPins.append(local)
            } else {
                var page = Page(url: remote.homeURL, name: "", customName: remote.page.customName, usage: Usage(at: now()))
                let name = remote.name.isEmpty ? identity.siteName(for: remote.key) : remote.name
                page.name = displayName(page, siteName: name)
                let id = localSiteIDs.contains(remote.id) || newPins.contains(where: { $0.id == remote.id }) ? SiteID() : remote.id
                newPins.append(PinnedSite(id: id, key: remote.key, name: name, homeURL: remote.homeURL, page: page, folder: remote.folder))
            }
        }
        let keptPinKeys = Set(newPins.map(\.key))
        let removedPinPages = pins.filter { !keptPinKeys.contains($0.key) }.map(\.page.id)
        pins = newPins
        pruneAndTidyPinFolders()

        // Shelf
        var onBar = Set<PageID>()
        for w in windows { for site in w.sites { onBar.formUnion(site.pages.map(\.id)) } }
        onBar.formUnion(newPins.map(\.page.id))
        var localShelved: [PageID: Page] = [:]
        for entry in shelf { for page in entry.pages { localShelved[page.id] = page } }
        var keptShelved = Set<PageID>()
        var newShelf: [ShelfEntry] = []
        for remote in payload.shelf {
            var entry = remote
            entry.pages = remote.pages.compactMap { page in
                guard !onBar.contains(page.id), keptShelved.insert(page.id).inserted else { return nil }
                return localShelved[page.id] ?? page
            }
            if !entry.pages.isEmpty { newShelf.append(entry) }
        }
        let removedShelfPages = shelf.flatMap(\.pages).map(\.id).filter { !keptShelved.contains($0) }
        shelf = newShelf

        // History
        history = payload.history
        let historyIDs = Set(history.map(\.id))
        latestHistory = latestHistory.filter { historyIDs.contains($0.value) }

        for id in removedPinPages + removedShelfPages {
            latestHistory[id] = nil
            emit(.pageClosed(id))
        }
        let goneSelections = Set(removedPinPages)
        for wi in windows.indices {
            guard let selected = windows[wi].selectedPageID, goneSelections.contains(selected) else { continue }
            var w = windows[wi]
            w.selectedPageID = nil
            if let next = mostRecentPage(in: w) { focus(next, in: &w) }
            emit(.selectionChanged(w.id))
            windows[wi] = w
        }

        sanitize()
        // Sanitising may drop duplicates; forget pointers for pages that no longer exist anywhere.
        var everywhere = Set(pins.map(\.page.id))
        for w in windows { for site in w.sites { everywhere.formUnion(site.pages.map(\.id)) } }
        for entry in shelf { everywhere.formUnion(entry.pages.map(\.id)) }
        latestHistory = latestHistory.filter { everywhere.contains($0.key) }
        commit()
    }

    /// This Mac's open pages for other devices: every page on every window's bar, in window then
    /// bar order, one per URL. Blank (`about:`) pages are left out. Pins are synced separately.
    public func openPagesSummary() -> [OpenPageSummary] {
        var seen = Set<URL>()
        var result: [OpenPageSummary] = []
        for w in windows where !w.isPrivate {
            for site in w.sites {
                for page in site.pages where page.url.scheme?.lowercased() != "about" && seen.insert(page.url).inserted {
                    result.append(OpenPageSummary(url: page.url, name: page.name, title: page.rawTitle, key: site.key))
                }
            }
        }
        return result
    }
}
