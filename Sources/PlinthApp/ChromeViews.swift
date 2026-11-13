import SwiftUI
import AppKit
import PlinthModel
import PlinthBarUI
import PlinthPanels
import PlinthStore

/// The bottom bar for one window, fed from the store.
struct BarHost: View {
    let app: AppController
    let windowID: WindowID
    let chrome: WindowChrome

    var body: some View {
        let state = app.store.window(windowID)
        let selected = state?.selectedPageID
        // The bracket is drawn only while the split is on screen.
        let split = state?.split.flatMap { pair in selected.map(pair.contains) == true ? pair : nil }
        // A focused group hides the window's other sites from the bar (nothing is closed).
        let isPrivate = state?.isPrivate ?? false
        let input = BarInput(pins: app.store.pins(in: windowID), sites: app.store.visibleSites(in: windowID), selected: selected, split: split)
        let engine = app.layoutEngine

        let items = app.pool.downloads.items
        let running = items.filter { $0.state == .running }
        let known = running.compactMap(\.progress)
        let downloads = items.isEmpty ? nil
            : BarDownloadsState(runningCount: running.count,
                                progress: known.isEmpty ? nil : min(max(known.reduce(0, +) / Double(known.count), 0), 1))

        // Reading `chrome.progress` keeps the buttons in step while a page loads; navigation changes
        // the page's address, which the store reports, so back and forward follow too.
        let nav = BarNavState(hasPage: selected != nil,
                              canGoBack: selected.map(app.pool.canGoBack) ?? false,
                              canGoForward: selected.map(app.pool.canGoForward) ?? false,
                              isLoading: chrome.progress != nil)

        BottomBarView(
            layoutForWidth: { width in
                engine.layout(input, barWidth: width, metrics: .standard, measure: BarTextMeasurer.width)
            },
            accent: app.accent,
            icon: { app.pool.favicons.image(for: $0) },
            downloads: downloads,
            nav: nav,
            onAction: { app.handle($0, in: windowID) }
        )
        // Midnight over the dark bar, so a private window is not mistaken for a normal one in dark mode.
        .colorMultiply(isPrivate ? PrivateTint.barTint : .white)
        .overlay(alignment: .top) {
            if let progress = chrome.progress {
                GeometryReader { proxy in
                    Capsule()
                        .fill(app.accent)
                        .frame(width: max(8, (proxy.size.width - 40) * progress), height: 2)
                        .padding(.leading, 20)
                        .animation(.easeOut(duration: 0.2), value: progress)
                }
                .frame(height: 2)
                .allowsHitTesting(false)
            }
        }
    }
}

/// The command bar, shelf or find strip, floating above the bar.
struct PanelLayer: View {
    let app: AppController
    let controller: BrowserWindowController
    let chrome: WindowChrome

    var body: some View {
        let metrics = BarMetrics.standard
        let lift = metrics.bottomInset + metrics.barHeight + 12
        switch chrome.panel {
        case .none:
            EmptyView()
        case .command(let text, let newPage):
            ZStack(alignment: .bottom) {
                Color.black.opacity(0.001).onTapGesture { controller.dismissPanel() }
                CommandBarView(
                    initialText: text,
                    opensNewPage: newPage,
                    accent: app.accent,
                    results: { query in
                        if query.isEmpty {
                            _ = app.store.suggestions(for: "") // forgets the last typed query
                            return controller.isPrivate ? [] : recentShelf()
                        }
                        // Ranked by frecency and past choices, one row per page, a few per site.
                        return app.store.suggestions(for: query, limit: 7)
                    },
                    semanticResults: { query in await app.semanticResults(for: query) },
                    searchSuggestions: { query in await app.searchSuggestions(for: query) },
                    icon: { app.pool.favicons.image(for: $0) },
                    onSubmit: { controller.submit($0) },
                    onDismiss: { controller.dismissPanel() }
                )
                .padding(.bottom, lift)
            }
        case .shelf:
            ZStack(alignment: .bottomTrailing) {
                Color.black.opacity(0.001).onTapGesture { controller.dismissPanel() }
                ShelfView(
                    entries: app.store.shelf,
                    accent: app.accent,
                    icon: { app.pool.favicons.image(for: $0) },
                    snapshot: { app.pool.snapshot(for: $0) },
                    hasSnapshot: { app.pool.hasSnapshot(for: $0) },
                    onRestore: { entry, page in
                        let ids = app.store.restore(entry: entry, page: page, into: controller.windowID)
                        controller.dismissPanel()
                        controller.refreshContent()
                        controller.showResumeCard(forRestored: ids)
                    },
                    onRemove: { entry, page in app.store.removeFromShelf(entry: entry, page: page) },
                    onDismiss: { controller.dismissPanel() },
                    semanticResults: { query in await app.semanticResults(for: query) },
                    onOpenResult: { controller.submit(.result($0)) },
                    onClearAll: { app.clearShelf() },
                    undoCount: app.store.clearedShelfPageCount,
                    onUndoClear: { app.undoClearShelf() }
                )
                .padding(.trailing, metrics.sideInset)
                .padding(.bottom, lift)
            }
        case .downloads:
            ZStack(alignment: .bottomTrailing) {
                Color.black.opacity(0.001).onTapGesture { controller.dismissPanel() }
                DownloadsTrayView(
                    items: app.pool.downloads.items,
                    accent: app.accent,
                    onOpen: { app.pool.openDownload(id: $0) },
                    onReveal: { app.pool.revealDownload(id: $0) },
                    onCancel: { app.pool.cancelDownload(id: $0) },
                    onRemove: { app.pool.removeDownload(id: $0) },
                    onClear: { app.pool.clearFinishedDownloads() },
                    onDismiss: { controller.dismissPanel() }
                )
                .padding(.trailing, metrics.sideInset)
                .padding(.bottom, lift)
            }
        case .history:
            ZStack(alignment: .bottomTrailing) {
                Color.black.opacity(0.001).onTapGesture { controller.dismissPanel() }
                HistoryView(
                    accent: app.accent,
                    icon: { app.pool.favicons.image(for: $0) },
                    prepare: {
                        // Built off the main thread from a snapshot of the history.
                        let entries = app.store.history
                        let index = await Task.detached(priority: .userInitiated) { HistoryIndex(entries) }.value
                        return { filter in index.page(for: filter) }
                    },
                    onOpen: { row in
                        controller.submit(.result(SearchResult(id: "history-\(row.id.uuidString)", target: .history(row.url),
                                                               title: row.title, subtitle: row.url.absoluteString, key: row.key)))
                    },
                    onDismiss: { controller.dismissPanel() }
                )
                .padding(.trailing, metrics.sideInset)
                .padding(.bottom, lift)
            }
        case .ask:
            ZStack(alignment: .bottom) {
                Color.black.opacity(0.001).onTapGesture { controller.dismissPanel() }
                AskPanelView(
                    scopes: controller.askScopes(),
                    selectedScope: Binding(get: { chrome.askScope }, set: { chrome.askScope = $0 }),
                    answer: chrome.askAnswer,
                    isStreaming: chrome.askStreaming,
                    message: chrome.askMessage,
                    canTurnOn: app.ai.availability == .turnedOff,
                    accent: app.accent,
                    initialQuestion: chrome.askQuestion,
                    onAsk: { controller.ask($0) },
                    onStop: { controller.stopAsk() },
                    onTurnOn: {
                        app.ai.setEnabled(true)
                        chrome.askMessage = BrowserWindowController.message(for: app.ai.availability)
                    },
                    onDismiss: { controller.dismissPanel() }
                )
                .padding(.bottom, lift)
            }
        case .find:
            FindBarView(
                accent: app.accent,
                notFound: Binding(get: { chrome.findNotFound }, set: { chrome.findNotFound = $0 }),
                onFind: { text, backwards in controller.find(text, backwards: backwards) },
                onDismiss: { controller.dismissPanel() }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
    }

    /// With nothing typed, offer what was most recently put away.
    private func recentShelf() -> [SearchResult] {
        app.store.shelf.prefix(4).flatMap { entry in
            entry.pages.prefix(2).map { page in
                SearchResult(id: "shelf-\(page.id.raw.uuidString)", target: .shelf(entry: entry.id, page: page.id),
                             title: page.name, subtitle: page.url.host ?? page.url.absoluteString, key: entry.key)
            }
        }
    }
}

/// Shown in a window with no pages.
struct EmptyWindowView: View {
    var isPrivate = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        VStack(spacing: 10) {
            Text(isPrivate ? "Private window" : "Plinth")
                .font(.system(size: 34, weight: .semibold))
                .kerning(-1.2)
            Text(isPrivate ? "Nothing here is remembered. Press ⌘L to search or enter an address."
                           : "Press ⌘L to search or enter an address.")
                .font(.system(size: 13))
                .opacity(0.7)
        }
        .foregroundStyle(isPrivate ? PrivateTint.text
                         : dark ? Color(red: 0xF4 / 255, green: 0xEE / 255, blue: 0xE6 / 255)
                                : Color(red: 0x1C / 255, green: 0x1C / 255, blue: 0x1A / 255))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(isPrivate ? Color(nsColor: PrivateTint.surface)
                    : dark ? Color(red: 0x1B / 255, green: 0x1A / 255, blue: 0x2E / 255)
                           : Color(red: 0xFB / 255, green: 0xF8 / 255, blue: 0xF2 / 255))
    }
}

/// The strip behind the traffic lights: the window's only drag area. Dragging moves the window and
/// a double-click does what the user chose in System Settings (zoom by default, minimise, or nothing).
final class TitleStripView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        if event.clickCount == 2 {
            switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize" {
            case "Minimize": window.performMiniaturize(nil)
            case "None": break
            default: window.performZoom(nil)
            }
            return
        }
        window.performDrag(with: event)
    }
}
