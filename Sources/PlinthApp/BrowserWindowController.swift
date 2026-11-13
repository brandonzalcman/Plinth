import AppKit
import SwiftUI
import WebKit
import Observation
import PlinthModel
import PlinthSettings
import PlinthRules
import PlinthBarUI
import PlinthPanels

/// What is floating over the page in one window.
@Observable
final class WindowChrome {
    enum Panel: Equatable {
        case none
        case command(text: String, newPage: Bool)
        case shelf
        case history
        case downloads
        case find
        case ask
    }
    var panel: Panel = .none
    /// 0...1 while the focused page is loading, nil otherwise.
    var progress: Double?
    var findNotFound = false

    // Ask page / ask site.
    var askScope: AskScope = .page
    var askAnswer = ""
    var askStreaming = false
    var askMessage: String?
    var askQuestion = ""

    /// The "where you left off" card, shown only after a site comes back from the shelf.
    struct ResumeCard: Equatable {
        var page: PageID
        var key: SiteKey
        var siteName: String
        var pageName: String
        var summary: String?
        var isLoading: Bool
    }
    var resumeCard: ResumeCard?
}

/// One browser window: the page (or a split pair) edge to edge, the bar floating at the bottom,
/// and no toolbar. The traffic lights sit over the top-left of the page.
@MainActor
final class BrowserWindowController: NSObject, NSWindowDelegate {
    let window: NSWindow
    let windowID: WindowID
    let chrome = WindowChrome()
    unowned let app: AppController
    let metrics = BarMetrics.standard
    let root = NSView()
    private let content = ContentAreaView()
    private var emptyHost: NSHostingView<EmptyWindowView>?
    var barHost: NSHostingView<BarHost>!
    var panelHost: NSHostingView<PanelLayer>?
    private var clickMonitor: Any?
    private var shownPages: [PageID] = []
    /// True when the split's trailing page is shown on the left.
    private var splitFlipped = false
    /// Sits behind the traffic lights and takes the page's own background colour.
    private let topStrip = TitleStripView()
    private var stripObservation: NSKeyValueObservation?
    /// nil follows the system (used when the window has no page).
    var chromeAppearance: NSAppearance?
    private var stripColoured = false
    var accessoryHosts: [NSView] = []
    var resumeTask: Task<Void, Never>?
    var askTask: Task<Void, Never>?
    var peekView: WKWebView?
    var peekHost: NSView?
    /// True for a private window; fixed for the window's life.
    let isPrivate: Bool

    init(app: AppController, windowID: WindowID) {
        self.app = app
        self.windowID = windowID
        isPrivate = app.store.isPrivate(window: windowID)
        let saved = app.store.window(windowID)?.frame
        let frame = saved.flatMap { $0.count == 4 ? NSRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) : nil }
            ?? NSRect(x: 0, y: 0, width: 1280, height: 820)
        window = NSWindow(contentRect: frame,
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        super.init()

        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 520, height: 360)
        window.tabbingMode = .disallowed
        window.backgroundColor = isPrivate ? PrivateTint.surface : .plinthWindowBackground
        window.delegate = self
        if saved == nil { window.center() } else { window.setFrame(frame, display: false) }

        root.frame = NSRect(origin: .zero, size: frame.size)
        root.autoresizingMask = [.width, .height]
        window.contentView = root

        content.frame = root.bounds
        content.autoresizingMask = [.width, .height]
        content.onFractionChange = { [weak self] fraction in
            guard let self else { return }
            self.app.store.setSplitFraction(self.splitFlipped ? 1 - fraction : fraction, in: self.windowID)
        }
        root.addSubview(content)

        topStrip.wantsLayer = true
        topStrip.autoresizingMask = [.width, .minYMargin]
        root.addSubview(topStrip)

        if isPrivate { installPrivateBadge() }
        barHost = NSHostingView(rootView: BarHost(app: app, windowID: windowID, chrome: chrome))
        barHost.frame = NSRect(x: metrics.sideInset, y: metrics.bottomInset,
                               width: root.bounds.width - metrics.sideInset * 2, height: metrics.barHeight)
        barHost.autoresizingMask = [.width, .maxYMargin]
        root.addSubview(barHost)
        installAccessories()

        // A click inside the other pane of a split moves focus to that page.
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.focusPane(under: event)
            return event
        }

        observeStore()
        refreshContent()
    }

    deinit { if let clickMonitor { NSEvent.removeMonitor(clickMonitor) } }

    // MARK: Content

    /// Re-runs whenever the window's state in the store changes.
    private func observeStore() {
        withObservationTracking {
            _ = app.store.window(windowID)
            _ = app.store.pins
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.refreshContent()
                self.observeStore()
            }
        }
    }

    /// Debug measurement: how many times `refreshContent` ran and how long it took in all.
    var refreshStats = (count: 0, seconds: 0.0)

    func refreshContent() {
        let started = ContinuousClock.now
        defer {
            let d = ContinuousClock.now - started
            refreshStats.count += 1
            refreshStats.seconds += Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
        }
        guard let state = app.store.window(windowID) else { return }
        var ordered: [PageID] = []
        splitFlipped = false
        if let selected = state.selectedPageID {
            if let split = state.split, split.contains(selected) {
                // Panes sit in the same left-to-right order as their buttons on the bar.
                let order = BarOrder.pageOrder(pins: app.store.pins(in: windowID), sites: state.sites)
                let leadingFirst = (order.firstIndex(of: split.leading) ?? 0) <= (order.firstIndex(of: split.trailing) ?? 0)
                ordered = leadingFirst ? [split.leading, split.trailing] : [split.trailing, split.leading]
                splitFlipped = !leadingFirst
            } else {
                ordered = [selected]
            }
        }
        let pages = ordered.compactMap { app.store.page($0) }
        let views = pages.map { app.pool.webView(for: $0) }
        for view in views {
            // Let pages scroll clear of the floating bar.
            // The page starts below the traffic lights; WebKit fills the strip with the page's own colour.
            // WebKit re-lays the page out on every assignment, so only assign a change.
            let insets = NSEdgeInsets(top: titlebarHeight, left: 0,
                                      bottom: metrics.barHeight + metrics.bottomInset + 8, right: 0)
            let old = view.obscuredContentInsets
            if old.top != insets.top || old.bottom != insets.bottom || old.left != insets.left || old.right != insets.right {
                view.obscuredContentInsets = insets
            }
        }
        let fraction = state.split?.fraction ?? 0.5
        content.show(leading: views.first, trailing: views.count > 1 ? views[1] : nil,
                     fraction: splitFlipped ? 1 - fraction : fraction)
        showEmptyState(pages.isEmpty)
        layoutTopStrip(following: views.first)

        dropResumeCardIfStale()
        let changed = shownPages != pages.map(\.id)
        shownPages = pages.map(\.id)
        window.title = (isPrivate ? "Private — " : "") + (state.selectedPageID.flatMap { app.store.page($0)?.name } ?? "Plinth")
        if changed {
            chrome.progress = nil
            if chrome.panel == .find { chrome.panel = .none; syncPanel() }
        }
        if chrome.panel == .none, let selected = state.selectedPageID,
           let view = app.pool.existingWebView(for: selected), view.window === window,
           changed || !(window.firstResponder is NSView) {
            window.makeFirstResponder(view)
        }
    }

    private func layoutTopStrip(following view: WKWebView?) {
        let height = titlebarHeight
        topStrip.frame = NSRect(x: 0, y: root.bounds.height - height, width: root.bounds.width, height: height)
        topStrip.isHidden = height == 0
        if view == nil { topStrip.layer?.backgroundColor = NSColor.clear.cgColor }
        if view == nil { applyChromeAppearance() }
        stripObservation = view?.observe(\.underPageBackgroundColor, options: [.initial, .new]) { [weak self] view, _ in
            MainActor.assumeIsolated { self?.applyPageColour(of: view) }
        }
    }

    /// The strip behind the traffic lights takes the page's colour. The bar and panels follow the
    /// Appearance setting (nil follows the Mac), so they stay legible and consistent in dark mode.
    private func applyPageColour(of view: WKWebView) {
        // A page that has not drawn anything yet reports a placeholder colour; keep what was there.
        if view.isLoading, view.estimatedProgress < 0.5, stripColoured { return }
        stripColoured = true
        let colour = view.underPageBackgroundColor ?? .windowBackgroundColor
        let cg = colour.cgColor
        if topStrip.layer?.backgroundColor != cg { topStrip.layer?.backgroundColor = cg }
        applyChromeAppearance()
    }

    /// Also called when the Appearance setting changes.
    func applyChromeAppearance() {
        // A private window is always dark, whatever the Mac or the Appearance setting says.
        let appearance = isPrivate ? NSAppearance(named: .darkAqua) : app.settings.value.appearance.nsAppearance
        if isPrivate { window.appearance = appearance }
        // Changing a host's appearance re-renders its whole SwiftUI tree, so only do it when it flips.
        guard chromeAppearance?.name != appearance?.name || barHost.appearance?.name != appearance?.name else { return }
        chromeAppearance = appearance
        barHost.appearance = chromeAppearance
        panelHost?.appearance = chromeAppearance
        applyAccessoryAppearance()
    }

    private var titlebarHeight: CGFloat {
        guard !window.styleMask.contains(.fullScreen) else { return 0 }
        return max(0, window.frame.height - window.contentLayoutRect.maxY)
    }

    func windowDidEnterFullScreen(_ notification: Notification) { refreshContent() }
    func windowDidExitFullScreen(_ notification: Notification) { refreshContent() }

    private func showEmptyState(_ show: Bool) {
        if show, emptyHost == nil {
            let host = NSHostingView(rootView: EmptyWindowView(isPrivate: isPrivate))
            host.frame = root.bounds
            host.autoresizingMask = [.width, .height]
            root.addSubview(host, positioned: .below, relativeTo: topStrip)
            emptyHost = host
        } else if !show, let host = emptyHost {
            host.removeFromSuperview()
            emptyHost = nil
        }
    }

    private func focusPane(under event: NSEvent) {
        guard event.window === window, shownPages.count == 2, chrome.panel == .none,
              let hit = root.hitTest(root.convert(event.locationInWindow, from: nil)) else { return }
        for id in shownPages {
            guard let view = app.pool.existingWebView(for: id), hit.isDescendant(of: view) else { continue }
            if app.store.window(windowID)?.selectedPageID != id { app.store.select(id, in: windowID) }
        }
    }

    func loadingChanged(_ id: PageID, isLoading: Bool, progress: Double) {
        guard app.store.window(windowID)?.selectedPageID == id else { return }
        chrome.progress = isLoading ? progress : nil
        if let view = app.pool.existingWebView(for: id) { applyPageColour(of: view) }
    }

    /// The bar gets out of the way of full-screen video and comes back afterwards.
    func setBarHidden(_ hidden: Bool) {
        barHost.isHidden = hidden
        if hidden { dismissPanel() }
    }

    // MARK: Panels

    func openCommandBar(newPage: Bool) {
        // A new page may open the homepage or a blank page (Settings) instead of the command bar.
        if newPage, case .open(let url) = NewPageAction.decide(app.settings.value) {
            dismissPanel()
            app.store.openPage(url: url, in: windowID)
            refreshContent()
            return
        }
        var text = ""
        if !newPage, let id = app.store.window(windowID)?.selectedPageID, let page = app.store.page(id) {
            text = page.url.absoluteString
        }
        chrome.panel = .command(text: text, newPage: newPage)
        syncPanel()
    }

    func toggleShelf() {
        // The shelf belongs to the normal profile: nothing goes onto it from here or comes off it into here.
        guard !isPrivate else { return }
        chrome.panel = chrome.panel == .shelf ? .none : .shelf
        syncPanel()
    }

    func toggleHistory() {
        chrome.panel = chrome.panel == .history ? .none : .history
        syncPanel()
    }

    func toggleDownloads() {
        chrome.panel = chrome.panel == .downloads ? .none : .downloads
        syncPanel()
    }

    func openFind() {
        guard app.store.window(windowID)?.selectedPageID != nil else { return }
        chrome.findNotFound = false
        chrome.panel = .find
        syncPanel()
    }

    /// Returns true if a panel was showing.
    @discardableResult
    func dismissPanel() -> Bool {
        if closePeek() { return true }
        guard chrome.panel != .none else { return false }
        if chrome.panel == .ask { stopAsk() }
        chrome.panel = .none
        syncPanel()
        return true
    }

    func syncPanel() {
        panelHost?.removeFromSuperview()
        panelHost = nil
        guard chrome.panel != .none else {
            if let id = app.store.window(windowID)?.selectedPageID, let view = app.pool.existingWebView(for: id) {
                window.makeFirstResponder(view)
            }
            return
        }
        let host = NSHostingView(rootView: PanelLayer(app: app, controller: self, chrome: chrome))
        host.appearance = chromeAppearance
        if chrome.panel == .find {
            // Find stays out of the way so the page remains clickable.
            let size = NSSize(width: 372, height: 86)
            host.frame = NSRect(x: root.bounds.width - size.width - 16, y: root.bounds.height - size.height - 12,
                                width: size.width, height: size.height)
            host.autoresizingMask = [.minXMargin, .minYMargin]
        } else {
            host.frame = root.bounds
            host.autoresizingMask = [.width, .height]
        }
        root.addSubview(host, positioned: .above, relativeTo: barHost)
        panelHost = host
        window.makeFirstResponder(host)
    }

    // MARK: Command handling

    func submit(_ submission: CommandSubmission) {
        let store = app.store!
        let selected = store.window(windowID)?.selectedPageID
        dismissPanel()
        switch submission {
        case .text(let text, let newPage):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let url: URL
            switch app.resolver.resolve(trimmed) {
            case .url(let resolved):
                url = resolved
                store.recordSuggestionPick(url: resolved)
            case .search(let query): url = app.resolver.searchURL(for: query)
            }
            open(url, newPage: newPage || selected == nil, replacing: selected)
        case .result(let result):
            store.recordSuggestionPick(result)
            switch result.target {
            case .openPage(let page, let otherWindow):
                store.select(page, in: otherWindow)
                app.controller(for: otherWindow)?.window.makeKeyAndOrderFront(nil)
            case .pin(let pin):
                if isPrivate, let url = store.url(of: result.target) {
                    open(url, newPage: true, replacing: selected)
                } else {
                    store.selectPin(pin, in: windowID)
                }
            case .shelf(let entry, let page):
                if isPrivate {
                    // A private window opens the address; the shelf entry stays where it is.
                    if let url = store.url(of: result.target) { open(url, newPage: true, replacing: selected) }
                } else {
                    let ids = store.restore(entry: entry, page: page, into: windowID)
                    showResumeCard(forRestored: ids)
                }
            case .history(let url):
                open(url, newPage: true, replacing: selected)
            }
        }
        refreshContent()
    }

    private func open(_ url: URL, newPage: Bool, replacing selected: PageID?) {
        if !newPage, let selected {
            app.store.navigate(selected, to: url)
        } else {
            app.store.openPage(url: url, in: windowID, select: true, opener: nil)
        }
    }

    func find(_ text: String, backwards: Bool) {
        guard let id = app.store.window(windowID)?.selectedPageID else { return }
        guard !text.isEmpty else { chrome.findNotFound = false; return }
        Task { @MainActor in
            let found = await app.pool.find(text, in: id, backwards: backwards)
            chrome.findNotFound = !found
        }
    }

    // MARK: Window delegate

    func saveFrame() {
        let frame = window.frame
        app.store.setFrame([frame.origin.x, frame.origin.y, frame.width, frame.height], for: windowID)
    }

    func windowDidEndLiveResize(_ notification: Notification) { saveFrame() }
    func windowDidBecomeKey(_ notification: Notification) { app.mainWindowBecameKey(windowID) }
    func windowDidMove(_ notification: Notification) { saveFrame() }

    func windowWillClose(_ notification: Notification) {
        saveFrame()
        content.show(leading: nil, trailing: nil, fraction: 0.5)
        app.windowDidClose(windowID)
    }
}
