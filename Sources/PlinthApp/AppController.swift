import AppKit
import SwiftUI
import WebKit
import PlinthModel
import PlinthRules
import PlinthFade
import PlinthLayout
import PlinthStore
import PlinthBarUI
import PlinthWeb
import PlinthAI
import PlinthSync
import PlinthSettings
import PlinthLoyalty

/// Owns the store and the web view pool, and connects the two. One per process.
@MainActor
final class AppController: NSObject, NSApplicationDelegate {
    static var shared: AppController?

    let identity = SiteIdentity()
    var resolver = AddressResolver()
    /// User settings (`settings.json`). Created at launch, before anything that reads it.
    private(set) var settings: SettingsStore!
    /// The one Settings window, created on first use (see SettingsWindowController.swift).
    var settingsWindow: SettingsWindowController?
    let layoutEngine = BarLayoutEngine()
    private(set) var store: BrowserStore!
    /// Bookmarks and their folders (see BookmarkFeatures.swift).
    private(set) var bookmarks: BookmarkStore!
    private(set) var pool: WebViewPool!
    private(set) var ai: AIService!
    let pinPolicy = PinLinkPolicy()
    /// A web view made outside the pool (peek, mini window) that the next matching `.pageOpened` takes over.
    var pendingAdoption: (url: URL, view: WKWebView)?
    var miniWindows: [MiniWindowController] = []
    /// Windows for pages' `window.open` popups (sign-in windows and the like).
    var popups: [PopupWindowController] = []
    /// Each private window's own non-persistent data store (see PrivateWindows.swift).
    var privateStores: [WindowID: WKWebsiteDataStore] = [:]
    /// Links handed to Plinth before it finished launching.
    var pendingOpenURLs: [URL] = []
    var didFinishLaunching = false
    /// The main window most recently made key, so links promoted from a mini window know where to go.
    var lastMainWindowID: WindowID?
    /// History entries already sent to the semantic index this run.
    var indexedHistory = Set<UUID>()
    var sync: SyncCoordinator?
    private var appearanceObservation: NSKeyValueObservation?
    /// Loyalty points and levels (see Loyalty.swift).
    var loyalty: LoyaltyEngine!
    let loyaltyModel = LoyaltyModel()
    /// During the first minute of the first run, level-ups are acknowledged without a card.
    var silentUntil: Date?
    /// Runs the share sheet for the loyalty card; held here so it outlives the Settings window.
    lazy var cardSharer = ShareCardSharer { [weak self] in self?.earn(.share) }
    var otherDevices: [DeviceOpenPages] = []
    /// Ends the shelf's "Clear all" Undo window (see ShelfUndo.swift).
    var shelfUndoTask: Task<Void, Never>?
    var storageDirectory: URL!
    /// The built-in password manager (see PasswordsController.swift).
    var passwords: PasswordsController!
    /// Set by the Xcode app target (Sparkle). nil in the SwiftPM build.
    /// The first-launch animation and guide (see Onboarding.swift).
    var welcome: WelcomeWindowController?
    var checkForUpdates: (@MainActor () -> Void)?
    @objc func menuCheckForUpdates(_ sender: Any?) { checkForUpdates?() }
    /// The accent colour chosen in Settings (SwiftUI views read it, so they follow changes).
    var accent: Color { accent(dark: NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua) }

    /// The accent for a light or dark surface. A brand colour that the current level has not unlocked
    /// falls back to the default blue (it could only be chosen before points were reset or turned off).
    func accent(dark: Bool) -> Color {
        var choice = settings.value.accent
        if let loyalty, choice.unlockLevel > loyalty.totals.level.number { choice = .blue }
        let c = choice.rgb(dark: dark)
        return Color(red: c.r / 255, green: c.g / 255, blue: c.b / 255)
    }

    private var controllers: [WindowID: BrowserWindowController] = [:]
    private var fadeTimer: Timer?
    private var dwellTimer: Timer?
    private let dwellInterval: TimeInterval = 5

    // MARK: Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        // PLINTH_STORAGE points a test run at a throwaway profile; PLINTH_OPEN opens a comma-separated list of URLs.
        let environment = ProcessInfo.processInfo.environment
        let support = environment["PLINTH_STORAGE"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Plinth", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)

        settings = SettingsStore(storageDirectory: support)
        NSApp.appearance = settings.value.appearance.nsAppearance
        resolver.engine = settings.value.searchEngine
        store = BrowserStore(identity: identity, namer: PageNamer(), fader: Self.fader(for: settings.value.fadeBehavior),
                             storageDirectory: support)
        bookmarks = BookmarkStore(storageDirectory: support)
        pool = WebViewPool(storageDirectory: support)
        ai = AIService.makeDefault(storageDirectory: support)
        storageDirectory = support
        setUpPasswords()
        setUpLoyalty()
        applyAppIcon()
        connect()
        connectFeatures()
        pool.apply(settings.value)
        ai.semanticEnabled = settings.value.semanticSearchEnabled
        ai.summariesEnabled = settings.value.pageSummariesEnabled
        settings.observe { [weak self] old, new in self?.settingsDidChange(from: old, to: new) }

        NSApp.mainMenu = MainMenu.build()

        if settings.value.startup == .startFresh { putEverythingAway() }

        // Time passed while Plinth was closed counts: apply fading before anything is shown.
        scheduleFade()
        let profileHadWindows = !store.windows.isEmpty
        if store.windows.isEmpty { store.createWindow() }
        if let list = environment["PLINTH_OPEN"], let first = store.windows.first?.id {
            for text in list.split(separator: ",") {
                if let url = URL(string: text.trimmingCharacters(in: .whitespaces)) { store.openPage(url: url, in: first) }
            }
        }
        for window in store.windows { showController(for: window.id) }
        NSApp.activate(ignoringOtherApps: true)

        dwellTimer = Timer.scheduledTimer(withTimeInterval: dwellInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.recordDwell() }
        }
        didFinishLaunching = true
        startSyncIfConfigured()
        let early = pendingOpenURLs
        pendingOpenURLs = []
        for url in early { openFromOtherApp(url) }
        launchWelcomeIfNeeded(profileHadWindows: profileHadWindows)
        DebugScript.runIfRequested(self)
    }

    /// "Start fresh": every open page goes onto the shelf (nothing is lost), leaving one empty window.
    /// Pins stay. Extra windows are closed the usual way, which shelves their sites too.
    private func putEverythingAway() {
        for window in store.windows.dropFirst() { store.closeWindow(window.id) }
        guard let first = store.windows.first else { return }
        for site in first.sites { store.shelve(site: site.id) }
    }

    static func fader(for behavior: FadeBehavior) -> FadeEngine {
        FadeEngine(policy: FadePolicy.standard.scaled(by: behavior.lifetimeScale))
    }

    /// Everything that follows a settings change besides the web views (see `WebViewPool.apply`).
    private func settingsDidChange(from old: AppSettings, to new: AppSettings) {
        pool.apply(new)
        if old.searchEngine != new.searchEngine { resolver.engine = new.searchEngine }
        if old.appIcon != new.appIcon { applyAppIcon() }
        if old.fadeBehavior != new.fadeBehavior {
            store.setFader(Self.fader(for: new.fadeBehavior))
            scheduleFade()
        }
        ai.semanticEnabled = new.semanticSearchEnabled
        ai.summariesEnabled = new.pageSummariesEnabled
        if old.appearance != new.appearance {
            NSApp.appearance = new.appearance.nsAppearance
            for controller in controllers.values { controller.applyChromeAppearance() }
        }
        if old.accent != new.accent {
            for controller in controllers.values { controller.refreshContent() }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { newWindowOrRestore() }
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        scheduleFade()
        earnDayOfUse()
    }

    func applicationWillTerminate(_ notification: Notification) {
        for controller in controllers.values { controller.saveFrame() }
        store.flush()
        bookmarks.flush()
        let ai = ai
        let done = DispatchSemaphore(value: 0)
        Task.detached { await ai?.flush(); done.signal() }
        _ = done.wait(timeout: .now() + 1)
    }

    // MARK: Store <-> web views

    private func connect() {
        store.onEvent = { [weak self] event in self?.handle(event) }
        let identity = identity
        pool.siteKey = { identity.key(for: $0) }
        pool.dataStoreForPage = { [weak self] id in self?.dataStore(forPage: id) }

        pool.callbacks.didUpdate = { [weak self] id, url, title, hint in
            self?.store.pageDidUpdate(id, url: url, title: title, siteNameHint: hint)
        }
        pool.callbacks.didScroll = { [weak self] id, y in self?.store.pageDidScroll(id, y: y) }
        pool.callbacks.openRequest = { [weak self] url, opener, background in
            guard let self else { return }
            guard let window = self.store.windowID(containing: opener) ?? self.keyWindowID else { return }
            self.store.openPage(url: url, in: window, select: !background, opener: opener)
        }
        pool.callbacks.fullscreenChanged = { [weak self] id, isFullscreen in
            guard let self, let window = self.store.windowID(containing: id) ?? self.keyWindowID else { return }
            self.controllers[window]?.setBarHidden(isFullscreen)
        }
        pool.callbacks.loadingChanged = { [weak self] id, isLoading, progress in
            guard let self else { return }
            for controller in self.controllers.values { controller.loadingChanged(id, isLoading: isLoading, progress: progress) }
        }
        pool.callbacks.didClose = { [weak self] id in self?.store.closePage(id) }
    }

    private func handle(_ event: StoreEvent) {
        switch event {
        case .pageOpened(let id, _):
            // Pages opened in the background still start loading.
            guard let page = store.page(id) else { break }
            if let pending = pendingAdoption, pending.url == page.url {
                pendingAdoption = nil
                pool.adopt(pending.view, as: page)
            } else {
                _ = pool.webView(for: page)
            }
        case .pageClosed(let id):
            pool.close(id)
        case .pagesShelved(let ids, let key):
            pool.suspend(ids, key: key)
        case .pagesRestored(let ids, _):
            pool.resume(ids)
        case .selectionChanged(let window):
            controllers[window]?.refreshContent()
        case .navigate(let id, let url):
            if let page = store.page(id) { _ = pool.webView(for: page) }
            pool.load(url, in: id)
        }
    }

    // MARK: Windows

    var keyWindowID: WindowID? {
        if let key = NSApp.keyWindow ?? NSApp.mainWindow,
           let match = controllers.first(where: { $0.value.window === key }) { return match.key }
        if let last = lastMainWindowID, controllers[last] != nil { return last }
        return controllers.keys.first
    }

    func mainWindowBecameKey(_ id: WindowID) { lastMainWindowID = id }

    var keyController: BrowserWindowController? { keyWindowID.flatMap { controllers[$0] } }

    func controller(for id: WindowID) -> BrowserWindowController? { controllers[id] }

    private func showController(for id: WindowID) {
        if let existing = controllers[id] { existing.window.makeKeyAndOrderFront(nil); return }
        let controller = BrowserWindowController(app: self, windowID: id)
        controllers[id] = controller
        controller.window.makeKeyAndOrderFront(nil)
        if store.window(id)?.selectedPageID == nil { controller.openCommandBar(newPage: true) }
    }

    func showControllerPublic(for id: WindowID) { showController(for: id) }

    func newWindow() {
        let id = store.createWindow()
        showController(for: id)
    }

    /// Dock click with no windows showing: bring back what was there, or start a new window.
    private func newWindowOrRestore() {
        if let existing = store.windows.first(where: { controllers[$0.id] == nil }) {
            showController(for: existing.id)
        } else {
            newWindow()
        }
    }

    /// Closing the last window keeps its bar for next time; closing one of several puts its sites away.
    /// A private window is always discarded, and never counts as "another window" for a normal one.
    func windowDidClose(_ id: WindowID) {
        controllers[id] = nil
        if store.isPrivate(window: id) {
            store.closeWindow(id)
            privateWindowClosed(id)
        } else if controllers.keys.contains(where: { !store.isPrivate(window: $0) }) {
            store.closeWindow(id)
        }
    }

    // MARK: Timers

    func scheduleFade() {
        fadeTimer?.invalidate()
        let next = store.runFade()
        let delay = min(max((next ?? .distantFuture).timeIntervalSinceNow, 30), 15 * 60)
        fadeTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleFade() }
        }
    }

    private func recordDwell() {
        guard NSApp.isActive else { return }
        store.noteCoOpen(seconds: dwellInterval)
        loyaltyTick()
        guard let id = keyWindowID, let window = store.window(id), controllers[id]?.window.isKeyWindow == true else { return }
        for page in window.visiblePageIDs {
            store.recordDwell(page, seconds: dwellInterval)
            indexForMeaningIfNeeded(page)
        }
    }

    // MARK: Bar actions

    func handle(_ action: BarAction, in windowID: WindowID) {
        guard let controller = controllers[windowID] else { return }
        switch action {
        case .selectPage(let id):
            // Clicking the page you are already on opens the address editor with its URL selected.
            if store.window(windowID)?.selectedPageID == id, case .none = controller.chrome.panel {
                controller.openCommandBar(newPage: false)
            } else {
                store.select(id, in: windowID)
            }
        case .closePage(let id): store.closePage(id)
        case .selectPin(let id):
            // Like a page: clicking the pin you are already on opens the address editor.
            if let pin = store.pins.first(where: { $0.id == id }), store.window(windowID)?.selectedPageID == pin.page.id,
               case .none = controller.chrome.panel {
                controller.openCommandBar(newPage: false)
            } else {
                store.selectPin(id, in: windowID)
            }
        case .selectSite(let id): store.selectSite(id, in: windowID)
        case .toggleFold(let id): store.toggleFold(id, in: windowID)
        case .newPage: controller.openCommandBar(newPage: true)
        case .goBack: if let page = store.window(windowID)?.selectedPageID { pool.goBack(page) }
        case .goForward: if let page = store.window(windowID)?.selectedPageID { pool.goForward(page) }
        case .reload: if let page = store.window(windowID)?.selectedPageID { pool.reload(page) }
        case .stopLoading: if let page = store.window(windowID)?.selectedPageID { pool.stopLoading(page) }
        case .openCommandBar: controller.openCommandBar(newPage: false)
        case .openShelf: controller.toggleShelf()
        case .openDownloads: controller.toggleDownloads()
        case .setKept(let id, let kept): store.setKept(id, kept)
        case .pinSite(let id): store.pin(site: id)
        case .unpin(let id): store.unpin(id, into: windowID)
        case .movePinToFolder(let id, let folder):
            if let folder { store.movePin(id, toFolder: folder) } else { store.createPinFolder(with: id) }
        case .removePinFromFolder(let id): store.removePinFromFolder(id)
        case .renamePinFolder(let id, let name): store.renamePinFolder(id, to: name)
        case .ungroupPinFolder(let id): store.ungroupPinFolder(id)
        case .resetPin(let id): store.resetPin(id)
        case .shelveSite(let id): store.shelve(site: id)
        case .closeSite(let id): store.closeSite(id)
        case .renamePage(let id, let name): store.rename(id, to: name)
        case .splitWithCurrent(let id):
            if let current = store.window(windowID)?.selectedPageID, current != id {
                store.split(current, with: id, in: windowID)
            }
        case .endSplit: store.endSplit(in: windowID)
        case .moveSite(let id, let index): store.moveSite(id, toIndex: realSiteIndex(index, moving: id, in: windowID), in: windowID)
        case .movePage(let id, let index): store.movePage(id, toIndex: index)
        case .splitPages(let dragged, let target):
            if dragged != target { store.split(target, with: dragged, in: windowID) }
        }
        controller.refreshContent()
    }

    // MARK: Menu actions (sent to the key window)

    @objc func menuShowWelcome(_ sender: Any?) { showWelcomeGuide() }
    @objc func menuNewWindow(_ sender: Any?) { newWindow() }
    @objc func menuNewPage(_ sender: Any?) { keyController?.openCommandBar(newPage: true) }
    @objc func menuOpenLocation(_ sender: Any?) { keyController?.openCommandBar(newPage: false) }
    @objc func menuShelf(_ sender: Any?) { keyController?.toggleShelf() }
    @objc func menuHistory(_ sender: Any?) { keyController?.toggleHistory() }
    @objc func menuFind(_ sender: Any?) { keyController?.openFind() }
    @objc func menuClosePage(_ sender: Any?) {
        guard let id = keyWindowID, let controller = controllers[id], controller.window === NSApp.keyWindow else {
            NSApp.keyWindow?.performClose(nil); return
        }
        if controller.dismissPanel() { return }
        if let page = store.window(id)?.selectedPageID, store.window(id)?.page(page) != nil {
            store.closePage(page)
        } else {
            controller.window.performClose(nil)
        }
    }
    @objc func menuCloseWindow(_ sender: Any?) { NSApp.keyWindow?.performClose(nil) }
    @objc func menuReopen(_ sender: Any?) { if let id = keyWindowID { store.reopenClosedPage(in: id) } }
    @objc func menuNextPage(_ sender: Any?) { if let id = keyWindowID { store.selectAdjacent(offset: 1, in: id) } }
    @objc func menuPreviousPage(_ sender: Any?) { if let id = keyWindowID { store.selectAdjacent(offset: -1, in: id) } }
    @objc func menuSelectNumbered(_ sender: NSMenuItem) { if let id = keyWindowID { store.selectByShortcut(sender.tag, in: id) } }
    @objc func menuReload(_ sender: Any?) { withSelectedPage { pool.reload($0) } }
    @objc func menuBack(_ sender: Any?) { withSelectedPage { pool.goBack($0) } }
    @objc func menuForward(_ sender: Any?) { withSelectedPage { pool.goForward($0) } }
    @objc func menuZoomIn(_ sender: Any?) { withSelectedPage { pool.zoomIn($0) } }
    @objc func menuZoomOut(_ sender: Any?) { withSelectedPage { pool.zoomOut($0) } }
    @objc func menuZoomReset(_ sender: Any?) { withSelectedPage { pool.resetZoom($0) } }
    @objc func menuKeepSite(_ sender: Any?) {
        guard let id = keyWindowID, let window = store.window(id), let page = window.selectedPageID,
              let site = window.site(containing: page) else { return }
        store.setKept(site.id, !site.isKept)
    }
    @objc func menuPinSite(_ sender: Any?) {
        guard let id = keyWindowID, let window = store.window(id), let page = window.selectedPageID,
              let site = window.site(containing: page) else { return }
        store.pin(site: site.id)
    }
    @objc func menuPutAway(_ sender: Any?) {
        guard let id = keyWindowID, let window = store.window(id), let page = window.selectedPageID,
              let site = window.site(containing: page) else { return }
        store.shelve(site: site.id)
    }
    @objc func menuEndSplit(_ sender: Any?) { if let id = keyWindowID { store.endSplit(in: id) } }

    /// The bar counts only visible sites when a group is focused; the store counts all of them.
    private func realSiteIndex(_ visibleIndex: Int, moving id: SiteID, in windowID: WindowID) -> Int {
        guard let all = store.window(windowID)?.sites else { return visibleIndex }
        let visible = store.visibleSites(in: windowID).filter { $0.id != id }
        let rest = all.filter { $0.id != id }
        guard visible.count != rest.count else { return visibleIndex }
        if visibleIndex < visible.count, let at = rest.firstIndex(where: { $0.id == visible[visibleIndex].id }) { return at }
        if let last = visible.last, let at = rest.firstIndex(where: { $0.id == last.id }) { return at + 1 }
        return visibleIndex
    }

    private func withSelectedPage(_ body: (PageID) -> Void) {
        guard let id = keyWindowID, let page = store.window(id)?.selectedPageID else { return }
        body(page)
    }
}
