import Foundation
import PlinthModel

// Private windows (`WindowState.isPrivate`). The store keeps every private page out of anything that
// outlives the window, in one place each:
//   history, last-visit pointers   BrowserStore.openPage / pageDidUpdate / recordHistory callers
//   shelf (closing, fading, "Put Away", closing the window)   `retire` below discards instead
//   closed-page stack (⇧⌘T)        closePage / closeSite / reopenClosedPage
//   site stats (fading, ranking)   `visitStats` / `focus`; `transientStats` for what fading needs
//   co-open time, group suggestions   Groups.swift
//   command bar and semantic results   Search.swift, SuggestionResults.swift, SemanticResults.swift
//   state.json                     `save` and `load` skip private windows
//   iCloud sync                    `syncPayload` carries only pins, shelf and history; `openPagesSummary` skips them
//   pins                           none are shown, selected, made or unpinned in a private window

extension BrowserStore {
    /// File › New Private Window.
    @discardableResult public func createPrivateWindow() -> WindowID {
        createWindow(isPrivate: true)
    }

    public func isPrivate(window id: WindowID) -> Bool {
        window(id)?.isPrivate ?? false
    }

    /// True for a page on a private window's bar.
    public func isPrivate(page id: PageID) -> Bool {
        guard let loc = findPage(id) else { return false }
        return windows[loc.w].isPrivate
    }

    /// The pins a window's bar shows. A private window shows none: a pin is a page of the normal
    /// profile (its cookies, its saved state), and sharing it would mix the two.
    public func pins(in window: WindowID) -> [PinnedSite] {
        isPrivate(window: window) ? [] : pins
    }

    /// Where pages go when they leave a bar for good without being closed by hand: the shelf, or
    /// nowhere for a private window (the shell is told to destroy their views).
    func retire(_ pages: [Page], key: SiteKey, name: String, private isPrivate: Bool) {
        guard isPrivate else { addToShelf(pages, key: key, name: name); return }
        for page in pages {
            latestHistory[page.id] = nil
            emit(.pageClosed(page.id))
        }
    }

    /// A private window is gone: forget what only it kept alive.
    func forgetPrivate(_ window: WindowState) {
        suggestionCache[window.id] = nil
        let stillPrivate = Set(windows.filter(\.isPrivate).flatMap { $0.sites.map(\.key) })
        for key in transientStats where !stillPrivate.contains(key) {
            transientStats.remove(key)
            siteStats[key] = nil
        }
    }
}
