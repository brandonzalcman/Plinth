import AppKit
import SwiftUI
import WebKit
import PlinthModel
import PlinthStore
import PlinthPanels
import PlinthWeb
import PlinthAI

// Version 1 features that float over one window: group prompt and chips, the resume card,
// peek, and ask page / ask site.

/// The row just above the bar's left end: group chips or a group suggestion, then the resume card.
struct AccessoryRow: View {
    let app: AppController
    let controller: BrowserWindowController
    let chrome: WindowChrome

    var body: some View {
        let store = app.store!
        let windowID = controller.windowID
        let focused = store.window(windowID)?.focusedGroup
        let groups = store.groups(in: windowID)
        HStack(alignment: .bottom, spacing: 10) {
            if !groups.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(groups) { group in
                        GroupChipView(group: group, isFiltering: focused == group.id, accent: app.accent,
                                      icon: { app.pool.favicons.image(for: $0) },
                                      onToggle: { store.setFocus(focused == group.id ? nil : group.id, in: windowID) },
                                      onRemove: { store.deleteGroup(group.id) })
                    }
                }
            } else if let suggestion = store.groupSuggestion(for: windowID) {
                GroupSuggestionView(suggestion: suggestion, accent: app.accent,
                                    icon: { app.pool.favicons.image(for: $0) },
                                    onGroup: {
                                        let id = store.acceptSuggestion(suggestion)
                                        store.setFocus(id, in: windowID)
                                    },
                                    onNotNow: { store.dismissSuggestion(suggestion) })
            }
            if let card = chrome.resumeCard {
                ResumeCardView(siteKey: card.key, siteName: card.siteName, pageName: card.pageName,
                               summary: card.summary, isLoading: card.isLoading, accent: app.accent,
                               icon: { app.pool.favicons.image(for: $0) },
                               onDismiss: { chrome.resumeCard = nil })
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.easeOut(duration: 0.2), value: chrome.resumeCard)
        .fixedSize()
    }
}

/// A link preview over the page. Clicking outside closes it.
struct PeekLayer: View {
    let controller: BrowserWindowController
    let webView: WKWebView
    let state: AuxiliaryPageState?
    let accent: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.opacity(0.18).onTapGesture { controller.closePeek() }
                let size = PeekCardView.cardSize(in: proxy.size)
                PeekCardView(title: state?.title ?? "", url: state?.url ?? webView.url,
                             isLoading: state?.isLoading ?? false, progress: state?.progress ?? 0,
                             content: webView, accent: accent,
                             onOpen: { controller.promotePeek() }, onClose: { controller.closePeek() })
                    .frame(width: size.width, height: size.height)
                    // Keep clear of the bar.
                    .offset(y: -20)
            }
        }
    }
}

extension BrowserWindowController {
    // MARK: Floating accessories

    func installAccessories() {
        let accessory = NSHostingView(rootView: AccessoryRow(app: app, controller: self, chrome: chrome))
        accessory.sizingOptions = [.intrinsicContentSize]
        accessory.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(accessory, positioned: .below, relativeTo: barHost)
        let lift = metrics.bottomInset + metrics.barHeight + 10
        NSLayoutConstraint.activate([
            accessory.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: metrics.sideInset),
            accessory.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -lift),
        ])
        accessoryHosts = [accessory]
    }

    func applyAccessoryAppearance() {
        for host in accessoryHosts { host.appearance = chromeAppearance }
        peekHost?.appearance = chromeAppearance
    }

    // MARK: Resume cards

    /// Called after pages come back from the shelf into this window (and only then).
    func showResumeCard(forRestored ids: [PageID]) {
        let summaries = app.settings.value.pageSummariesEnabled
        guard let selected = app.store.window(windowID)?.selectedPageID, ids.contains(selected),
              let page = app.store.page(selected), let site = app.store.window(windowID)?.site(containing: selected),
              summaries ? app.ai.availability.isAvailable : app.ai.isEnabled else { return }
        resumeTask?.cancel()
        if !summaries {
            // Summaries are off: the card still marks where you left off, with no summary.
            chrome.resumeCard = .init(page: selected, key: site.key, siteName: site.name, pageName: page.name,
                                      summary: nil, isLoading: false)
            resumeTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(8))
                if let self, !Task.isCancelled, self.chrome.resumeCard?.page == selected { self.chrome.resumeCard = nil }
            }
            return
        }
        chrome.resumeCard = .init(page: selected, key: site.key, siteName: site.name, pageName: page.name,
                                  summary: nil, isLoading: true)
        resumeTask?.cancel()
        resumeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var text: PageText?
            // A page that was discarded reloads first; give it a moment.
            for attempt in 0..<8 where text == nil {
                if attempt > 0 { try? await Task.sleep(for: .seconds(1)) }
                if Task.isCancelled { return }
                if let view = self.app.pool.existingWebView(for: selected), !view.isLoading || attempt >= 4 {
                    text = await self.app.pool.readableText(for: selected)
                }
            }
            guard !Task.isCancelled, self.chrome.resumeCard?.page == selected else { return }
            guard let text, let summary = await self.app.ai.resumeCard(for: selected, text: text) else {
                self.chrome.resumeCard = nil
                return
            }
            guard !Task.isCancelled, self.chrome.resumeCard?.page == selected else { return }
            self.chrome.resumeCard?.summary = summary
            self.chrome.resumeCard?.isLoading = false
            try? await Task.sleep(for: .seconds(14))
            if self.chrome.resumeCard?.page == selected { self.chrome.resumeCard = nil }
        }
    }

    /// The card belongs to the page it describes: moving elsewhere puts it away.
    func dropResumeCardIfStale() {
        guard let card = chrome.resumeCard else { return }
        if app.store.window(windowID)?.selectedPageID != card.page {
            chrome.resumeCard = nil
            resumeTask?.cancel()
        }
    }

    // MARK: Peek

    func showPeek(_ url: URL) {
        closePeek()
        dismissPanel()
        let view = app.pool.makeAuxiliaryWebView(url: url)
        peekView = view
        let host = NSHostingView(rootView: PeekLayer(controller: self, webView: view,
                                                     state: app.pool.auxiliaryState(of: view), accent: app.accent))
        host.frame = root.bounds
        host.autoresizingMask = [.width, .height]
        host.appearance = chromeAppearance
        root.addSubview(host, positioned: .above, relativeTo: barHost)
        peekHost = host
        window.makeFirstResponder(host)
    }

    @discardableResult
    func closePeek() -> Bool {
        guard let host = peekHost else { return false }
        host.removeFromSuperview()
        peekHost = nil
        peekView?.removeFromSuperview()
        peekView = nil
        if let id = app.store.window(windowID)?.selectedPageID, let view = app.pool.existingWebView(for: id) {
            window.makeFirstResponder(view)
        }
        return true
    }

    /// The preview becomes a real page in this window, keeping its state.
    func promotePeek() {
        guard let view = peekView else { return }
        let url = view.url ?? app.pool.auxiliaryState(of: view)?.url
        peekHost?.removeFromSuperview()
        peekHost = nil
        peekView = nil
        view.removeFromSuperview()
        guard let url else { return }
        app.adoptNextOpen(view, url: url)
        app.store.openPage(url: url, in: windowID, select: true, opener: app.store.window(windowID)?.selectedPageID)
        refreshContent()
    }

    var isPeeking: Bool { peekHost != nil }

    // MARK: Ask page / ask site

    func openAsk() {
        guard let selected = app.store.window(windowID)?.selectedPageID else { return }
        closePeek()
        app.ai.refreshAvailability()
        let scopes = askScopes()
        if !scopes.contains(where: { $0.scope == chrome.askScope }) { chrome.askScope = scopes.first?.scope ?? .page }
        if let state = app.store.window(windowID), let split = state.split, split.contains(selected) {
            chrome.askScope = .split
        }
        chrome.askMessage = Self.message(for: app.ai.availability)
        chrome.panel = .ask
        syncPanel()
    }

    func askScopes() -> [AskScopeOption] {
        guard let state = app.store.window(windowID), let selected = state.selectedPageID else { return [] }
        var options = [AskScopeOption(scope: .page, label: "This page")]
        if let site = state.site(containing: selected), site.pages.count > 1 {
            options.append(.init(scope: .site, label: "All \(site.name) pages (\(site.pages.count))"))
        }
        if let split = state.split, split.contains(selected) {
            options.append(.init(scope: .split, label: "Compare split"))
        }
        return options
    }

    static func message(for availability: AIAvailability) -> String? {
        switch availability {
        case .available: return nil
        case .turnedOff: return "On-device AI is turned off. Turn it on here or from the Plinth menu."
        case .unavailable(let reason): return reason
        }
    }

    func ask(_ question: String) {
        guard let state = app.store.window(windowID), let selected = state.selectedPageID else { return }
        chrome.askQuestion = question
        let ids: [PageID]
        switch chrome.askScope {
        case .page: ids = [selected]
        case .site: ids = state.site(containing: selected)?.pages.map(\.id) ?? [selected]
        case .split:
            if let split = state.split { ids = [split.leading, split.trailing] } else { ids = [selected] }
        }
        let scope = chrome.askScope
        app.ai.refreshAvailability()
        if let message = Self.message(for: app.ai.availability) {
            chrome.askMessage = message
            return
        }
        askTask?.cancel()
        chrome.askAnswer = ""
        chrome.askMessage = nil
        chrome.askStreaming = true
        askTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var texts: [PageText] = []
            for id in ids {
                if self.app.pool.existingWebView(for: id) == nil, let page = self.app.store.page(id) {
                    _ = self.app.pool.webView(for: page)
                }
                if let text = await self.app.pool.readableText(for: id) { texts.append(text) }
            }
            do {
                for try await partial in self.app.ai.ask(question, pages: texts, scope: scope) {
                    if Task.isCancelled { break }
                    self.chrome.askAnswer = partial
                }
            } catch {
                if !Task.isCancelled { self.chrome.askMessage = error.localizedDescription }
            }
            self.chrome.askStreaming = false
        }
    }

    func stopAsk() {
        askTask?.cancel()
        askTask = nil
        chrome.askStreaming = false
    }
}
