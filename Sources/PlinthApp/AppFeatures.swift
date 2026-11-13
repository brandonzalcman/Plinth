import AppKit
import WebKit
import Observation
import PlinthModel
import PlinthRules
import PlinthStore
import PlinthWeb
import PlinthAI
import PlinthSync

// Version 1 features at the app level: pinned-site link diversion, peek and split requests from
// pages, links from other apps (mini windows), semantic history, the AI switch and iCloud sync.

extension AppController: NSMenuItemValidation, NSMenuDelegate {
    func connectFeatures() {
        pool.callbacks.decideNavigation = { [weak self] id, request in
            guard let self else { return true }
            // A link clicked inside a pin that leaves the pin's site opens as an ordinary page.
            guard let pin = self.store.pins.first(where: { $0.page.id == id }), !request.wantsNewPage,
                  self.pinPolicy.shouldDivert(request, pinKey: pin.key) else { return true }
            if let window = self.store.windows.first(where: { $0.selectedPageID == id })?.id ?? self.keyWindowID {
                self.store.openPage(url: request.url, in: window, select: true, opener: nil)
            }
            return false
        }
        pool.callbacks.peekRequest = { [weak self] url, opener in
            guard let self else { return }
            let window = self.store.windowID(containing: opener)
                ?? self.store.windows.first(where: { $0.selectedPageID == opener })?.id ?? self.keyWindowID
            if let window { self.controller(for: window)?.showPeek(url) }
        }
        pool.callbacks.splitRequest = { [weak self] url, opener in
            guard let self else { return }
            guard let window = self.store.windowID(containing: opener) ?? self.keyWindowID else { return }
            let page = self.store.openPage(url: url, in: window, select: false, opener: opener)
            let base = self.store.window(window)?.page(opener) != nil ? opener : self.store.window(window)?.selectedPageID
            if let base, base != page { self.store.split(base, with: page, in: window) }
            if self.store.window(window)?.selectedPageID != base, let base { self.store.select(base, in: window) }
        }
    }

    /// The next page opened with `url` takes over `view` instead of making a new web view.
    func adoptNextOpen(_ view: WKWebView, url: URL) {
        pendingAdoption = (url, view)
    }

    // MARK: Semantic history

    /// Pages read for 30 s or more are embedded once, locally.
    func indexForMeaningIfNeeded(_ page: PageID) {
        guard ai.availability.isAvailable, let entry = store.latestHistoryEntry(for: page),
              SemanticIndex.shouldIndex(entry), !indexedHistory.contains(entry.id) else { return }
        indexedHistory.insert(entry.id)
        Task { @MainActor [weak self] in
            guard let self, let text = await self.pool.readableText(for: page), text.url == entry.url else {
                self?.indexedHistory.remove(entry.id)
                return
            }
            await self.ai.indexIfNeeded(entry: entry, text: text)
        }
    }

    /// "By meaning" results for the command bar and shelf, after keyword results.
    func semanticResults(for query: String) async -> [SearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3, ai.availability.isAvailable else { return [] }
        let matches = await ai.semanticSearch(trimmed, limit: 8)
        return store.semanticResults(matches, excluding: store.search(trimmed, limit: 16), limit: 4)
    }

    // MARK: Links from other apps

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if didFinishLaunching { openFromOtherApp(url) } else { pendingOpenURLs.append(url) }
        }
    }

    /// A link from another app opens in a transient mini window with no bar.
    func openFromOtherApp(_ url: URL) {
        let mini = MiniWindowController(app: self, url: url)
        miniWindows.append(mini)
        mini.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func miniWindowDidClose(_ mini: MiniWindowController) {
        miniWindows.removeAll { $0 === mini }
    }

    var keyMiniWindow: MiniWindowController? {
        miniWindows.first { $0.window === NSApp.keyWindow }
    }

    /// Moves the mini window's page into the frontmost main window, where it joins its site.
    func promote(_ mini: MiniWindowController) {
        let view = mini.detachWebView()
        let url = view.url ?? mini.initialURL
        mini.window.close()
        let target: WindowID
        if let id = keyWindowID, controller(for: id) != nil {
            target = id
        } else {
            target = store.windows.first?.id ?? store.createWindow()
            showControllerPublic(for: target)
        }
        adoptNextOpen(view, url: url)
        store.openPage(url: url, in: target, select: true, opener: nil)
        if pendingAdoption != nil { pendingAdoption = nil } // not taken (should not happen)
        controller(for: target)?.window.makeKeyAndOrderFront(nil)
        controller(for: target)?.refreshContent()
    }

    // MARK: Menu actions

    @objc func menuAsk(_ sender: Any?) { keyController?.openAsk() }

    @objc func menuToggleAI(_ sender: Any?) {
        ai.setEnabled(!ai.isEnabled)
        ai.refreshAvailability()
    }

    @objc func menuPromoteMini(_ sender: Any?) {
        if let mini = keyMiniWindow { promote(mini) } else { keyController?.promotePeek() }
    }

    @objc func menuSplitWith(_ sender: NSMenuItem) {
        guard let id = keyWindowID, let window = store.window(id), let current = window.selectedPageID,
              let uuid = sender.representedObject as? UUID else { return }
        let other = PageID(uuid)
        if other != current { store.split(current, with: other, in: id) }
    }

    @objc func menuSplitWithNext(_ sender: Any?) {
        guard let id = keyWindowID, let window = store.window(id), let current = window.selectedPageID else { return }
        let order = BarOrder.pageOrder(pins: [], sites: store.visibleSites(in: id))
        guard order.count > 1 else { return }
        let index = order.firstIndex(of: current) ?? -1
        let other = order[(index + 1) % order.count]
        if other != current { store.split(current, with: other, in: id) }
    }

    @objc func menuToggleSync(_ sender: Any?) {
        let settings = SyncSettings()
        if settings.isEnabled {
            settings.isEnabled = false
            sync?.cancelScheduled()
            sync = nil
            return
        }
        guard SyncSettings.isCloudKitConfigured else {
            let alert = NSAlert()
            alert.messageText = "iCloud sync needs a developer team"
            alert.informativeText = "This copy of Plinth is signed without an Apple developer team, so it cannot use iCloud. Sync of pins, the shelf and history is built and ready; see docs/icloud-sync.md for the steps to turn it on."
            alert.runModal()
            return
        }
        settings.isEnabled = true
        startSyncIfConfigured()
    }

    @objc func menuOpenRemotePage(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL, let id = keyWindowID else { return }
        store.openPage(url: url, in: id, select: true, opener: nil)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(menuToggleAI(_:)):
            item.state = ai.isEnabled ? .on : .off
            return true
        case #selector(menuToggleSync(_:)):
            item.state = SyncSettings().isEnabled && sync != nil ? .on : .off
            return true
        case #selector(menuPromoteMini(_:)):
            return keyMiniWindow != nil || keyController?.isPeeking == true
        case #selector(menuAsk(_:)):
            return keyController.flatMap { store.window($0.windowID)?.selectedPageID } != nil
        case #selector(menuSplitWithNext(_:)):
            guard let id = keyWindowID else { return false }
            return store.visibleSites(in: id).reduce(0) { $0 + $1.pages.count } > 1
        default:
            return true
        }
    }

    /// Fills the "Split View With" and "Pages on Other Macs" submenus when they open.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if menu.title == MainMenu.splitMenuTitle {
            guard let id = keyWindowID, let window = store.window(id) else { return }
            for site in store.visibleSites(in: id) {
                for page in site.pages where page.id != window.selectedPageID {
                    let item = NSMenuItem(title: "\(page.name) — \(site.name)", action: #selector(menuSplitWith(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = page.id.raw
                    item.image = pool.favicons.image(for: site.key)
                    menu.addItem(item)
                }
            }
            if menu.items.isEmpty {
                menu.addItem(withTitle: "No Other Pages in This Window", action: nil, keyEquivalent: "").isEnabled = false
            }
        } else if menu.title == MainMenu.remoteMenuTitle {
            for device in otherDevices where !device.pages.isEmpty {
                menu.addItem(withTitle: device.deviceName, action: nil, keyEquivalent: "").isEnabled = false
                for page in device.pages {
                    let item = NSMenuItem(title: page.name, action: #selector(menuOpenRemotePage(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = page.url
                    item.indentationLevel = 1
                    menu.addItem(item)
                }
            }
            if menu.items.isEmpty {
                let text = sync == nil ? "iCloud Sync Is Off" : "No Pages Open on Other Macs"
                menu.addItem(withTitle: text, action: nil, keyEquivalent: "").isEnabled = false
            }
        }
    }

    // MARK: iCloud sync (off by default; needs a developer team to run)

    func startSyncIfConfigured() {
        guard sync == nil,
              let engine = SyncSettings().makeCloudKitEngine(stateURL: storageDirectory.appendingPathComponent("sync-state.json"))
        else { return }
        let coordinator = SyncCoordinator(engine: engine)
        coordinator.onSyncFinished = { [weak self] result in
            if case .success(let devices) = result { self?.otherDevices = devices }
        }
        sync = coordinator
        Task { @MainActor [weak self] in
            guard let self, let sync = self.sync else { return }
            if case .success(let devices) = await sync.syncNow(local: { self.store.syncPayload() },
                                                               openPages: { self.store.openPagesSummary() },
                                                               apply: { self.store.applySynced($0) }) {
                self.otherDevices = devices
            }
            self.observeForSync()
        }
    }

    private func observeForSync() {
        guard sync != nil else { return }
        withObservationTracking {
            _ = store.pins
            _ = store.shelf
            _ = store.history.count
            _ = store.windows.map { $0.sites.count }
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, let sync = self.sync else { return }
                sync.scheduleSync(local: { self.store.syncPayload() }, openPages: { self.store.openPagesSummary() },
                                  apply: { self.store.applySynced($0) })
                self.observeForSync()
            }
        }
    }
}
