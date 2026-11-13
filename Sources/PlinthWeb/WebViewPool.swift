import AppKit
import WebKit
import PlinthModel
import PlinthSettings
import os

/// Owns every page's `WKWebView`: creation, navigation plumbing, suspension on the shelf,
/// demotion to a snapshot, and the snapshot cache.
@MainActor
public final class WebViewPool: NSObject {
    public struct Callbacks {
        public var didUpdate: @MainActor (PageID, _ url: URL?, _ title: String?, _ siteNameHint: String?) -> Void
        public var didScroll: @MainActor (PageID, _ y: Double) -> Void
        /// A link wants a new page (target=_blank, window.open, ⌘-click, middle-click). background = don't select it.
        public var openRequest: @MainActor (_ url: URL, _ opener: PageID, _ background: Bool) -> Void
        /// Return false to cancel a main-frame navigation (the shell uses this to divert off-site links out of pinned pages).
        public var shouldNavigate: @MainActor (PageID, URL) -> Bool
        public var fullscreenChanged: @MainActor (PageID, Bool) -> Void
        public var loadingChanged: @MainActor (PageID, _ isLoading: Bool, _ progress: Double) -> Void
        /// The page called `window.close()`.
        public var didClose: @MainActor (PageID) -> Void
        /// Consulted (with `shouldNavigate`; either returning false cancels) for main-frame http/https/file
        /// navigations the pool did not start itself, and for target=_blank / window.open requests
        /// (`wantsNewPage: true`) before `openRequest`. The pool only reports; the shell decides.
        public var decideNavigation: @MainActor (PageID, NavigationRequest) -> Bool
        /// ⇧-click on a link, or "Peek Link" in the context menu: show the URL in a peek card.
        public var peekRequest: @MainActor (URL, _ opener: PageID) -> Void
        /// "Open Link in Split View" in the context menu.
        public var splitRequest: @MainActor (URL, _ opener: PageID) -> Void

        public init(
            didUpdate: @escaping @MainActor (PageID, _ url: URL?, _ title: String?, _ siteNameHint: String?) -> Void = { _, _, _, _ in },
            didScroll: @escaping @MainActor (PageID, _ y: Double) -> Void = { _, _ in },
            openRequest: @escaping @MainActor (_ url: URL, _ opener: PageID, _ background: Bool) -> Void = { _, _, _ in },
            shouldNavigate: @escaping @MainActor (PageID, URL) -> Bool = { _, _ in true },
            fullscreenChanged: @escaping @MainActor (PageID, Bool) -> Void = { _, _ in },
            loadingChanged: @escaping @MainActor (PageID, _ isLoading: Bool, _ progress: Double) -> Void = { _, _, _ in },
            didClose: @escaping @MainActor (PageID) -> Void = { _ in },
            decideNavigation: @escaping @MainActor (PageID, NavigationRequest) -> Bool = { _, _ in true },
            peekRequest: @escaping @MainActor (URL, _ opener: PageID) -> Void = { _, _ in },
            splitRequest: @escaping @MainActor (URL, _ opener: PageID) -> Void = { _, _ in }
        ) {
            self.didUpdate = didUpdate
            self.didScroll = didScroll
            self.openRequest = openRequest
            self.shouldNavigate = shouldNavigate
            self.fullscreenChanged = fullscreenChanged
            self.loadingChanged = loadingChanged
            self.didClose = didClose
            self.decideNavigation = decideNavigation
            self.peekRequest = peekRequest
            self.splitRequest = splitRequest
        }
    }

    public var callbacks = Callbacks()
    public let favicons: FaviconStore
    public let storageDirectory: URL
    public let suspendedSiteLimit: Int

    /// Maps a page URL to the site its icon is filed under. The shell should set this to
    /// `SiteIdentity.key(for:)` so icons land under the same keys the store uses.
    public var siteKey: @MainActor (URL) -> SiteKey = { url in
        var host = (url.host ?? url.scheme ?? "").lowercased()
        for prefix in ["www.", "m."] where host.hasPrefix(prefix) && host.count > prefix.count + 2 {
            host.removeFirst(prefix.count)
            break
        }
        return SiteKey(host)
    }

    // MARK: State

    final class Entry {
        let id: PageID
        let webView: WKWebView
        var observations: [NSKeyValueObservation] = []
        /// Offset to restore once the current load finishes. Scroll reports are held back until then.
        var pendingScrollY: Double?
        var siteNameHint: String?
        /// The next main-frame navigation was asked for through the pool, so `shouldNavigate` is not consulted.
        var poolInitiatedLoad = false
        var reloadedAfterCrash = false
        var suspendedKey: SiteKey?
        var isDemoting = false
        var lastFullscreen = false
        /// The user zoomed this page by hand, so the default zoom no longer applies to it.
        var manualZoom = false
        /// https URL -> the http URL it was upgraded from (HTTPS-only), for the fallback prompt.
        var upgrades: [URL: URL] = [:]
        /// Hosts the user chose to open over http despite HTTPS-only (this page only).
        var httpAllowedHosts: Set<String> = []
        /// The URL whose error page is being shown (not rewritten by HTTPS-only / GPC).
        var errorPageURL: URL?

        init(id: PageID, webView: WKWebView) {
            self.id = id
            self.webView = webView
        }
    }

    var entries: [PageID: Entry] = [:]
    private var idsByView: [ObjectIdentifier: PageID] = [:]
    /// Suspended sites, least recently shelved first.
    private var suspendedOrder: [SiteKey] = []
    var ruleList: WKContentRuleList?
    var cookieRuleList: WKContentRuleList?
    /// The settings last handed to `apply(_:)`.
    var settings = AppSettings.defaults
    /// Bumped on every blocker/cookie-list sync so a slow compile cannot undo a newer decision.
    var blockerGeneration = 0
    var cookieGeneration = 0
    /// Downloads still running, by `WKDownload`.
    var activeDownloads: [ObjectIdentifier: DownloadRecord] = [:]
    /// Every download this session, newest first, for the downloads indicator.
    public let downloads = DownloadsModel()
    /// The same list as `downloads.items` (observable through it).
    public var downloadItems: [DownloadItem] { downloads.items }

    let userContent = WKUserContentController()
    private let snapshotDirectory: URL
    private let snapshotCache = NSCache<NSUUID, NSImage>()
    let log = Logger(subsystem: "Plinth", category: "web")

    nonisolated static let messageName = "plinth"
    static let zoomSteps: [Double] = [0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3]

    // MARK: Lifecycle

    public init(storageDirectory: URL, suspendedSiteLimit: Int = 10) {
        self.storageDirectory = storageDirectory
        self.suspendedSiteLimit = max(0, suspendedSiteLimit)
        self.favicons = FaviconStore(storageDirectory: storageDirectory)
        self.snapshotDirectory = storageDirectory.appendingPathComponent("snapshots", isDirectory: true)
        super.init()

        try? FileManager.default.createDirectory(at: snapshotDirectory, withIntermediateDirectories: true)
        snapshotCache.countLimit = 60

        let relay = MessageRelay()
        relay.pool = self
        userContent.add(relay, contentWorld: .defaultClient, name: Self.messageName)
        rebuildUserScripts()
        syncContentBlocker()
    }

    /// True once the block list is compiled and attached.
    public var isContentBlockerActive: Bool { ruleList != nil }

    /// Every view (pooled or auxiliary) gets one of these: same data store, content controller,
    /// user agent and preferences.
    func makeConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.userContentController = userContent
        configuration.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15"
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.preferences.isFraudulentWebsiteWarningEnabled = true
        configuration.allowsAirPlayForMediaPlayback = true
        // Inline playback is the only mode on macOS; `allowsInlineMediaPlayback` exists on iOS alone.
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.suppressesIncrementalRendering = false
        configuration.preferences.minimumFontSize = CGFloat(settings.minimumFontSize)
        return configuration
    }

    func makeWebView() -> PlinthWebView {
        let webView = PlinthWebView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800), configuration: makeConfiguration())
        webView.autoresizingMask = [.width, .height]
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsLinkPreview = true
        webView.allowsMagnification = true
        webView.isInspectable = true
        webView.pageZoom = CGFloat(Self.clampedZoom(settings.defaultZoom))
        return webView
    }

    private func makeEntry(for id: PageID) -> Entry {
        register(makeWebView(), as: id)
    }

    /// Makes `webView` the pool's view for `id`: delegates, observations and the link menu.
    @discardableResult
    func register(_ webView: WKWebView, as id: PageID) -> Entry {
        webView.navigationDelegate = self
        webView.uiDelegate = self
        if let plinthView = webView as? PlinthWebView {
            plinthView.linkMenuAction = { [weak self, weak plinthView] url, action in
                guard let self, let plinthView, self.entries[id]?.webView === plinthView else { return }
                switch action {
                case .peek: self.callbacks.peekRequest(url, id)
                case .split: self.callbacks.splitRequest(url, id)
                }
            }
        }

        let entry = Entry(id: id, webView: webView)
        entries[id] = entry
        idsByView[ObjectIdentifier(webView)] = id

        entry.observations = [
            webView.observe(\.title) { [weak self] _, _ in MainActor.assumeIsolated { self?.reportUpdate(id) } },
            webView.observe(\.url) { [weak self] _, _ in MainActor.assumeIsolated { self?.reportUpdate(id) } },
            webView.observe(\.isLoading) { [weak self] _, _ in MainActor.assumeIsolated { self?.reportLoading(id) } },
            webView.observe(\.estimatedProgress) { [weak self] _, _ in MainActor.assumeIsolated { self?.reportLoading(id) } },
            webView.observe(\.fullscreenState) { [weak self] _, _ in MainActor.assumeIsolated { self?.reportFullscreen(id) } },
        ]
        return entry
    }

    func destroy(_ id: PageID) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        entry.observations.forEach { $0.invalidate() }
        entry.observations = []
        let webView = entry.webView
        idsByView[ObjectIdentifier(webView)] = nil
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        (webView as? PlinthWebView)?.linkMenuAction = nil
        webView.stopLoading()
        webView.removeFromSuperview()
        pruneSuspendedOrder()
    }

    func forgetView(_ webView: WKWebView) {
        idsByView[ObjectIdentifier(webView)] = nil
    }

    func entry(for webView: WKWebView?) -> Entry? {
        guard let webView, let id = idsByView[ObjectIdentifier(webView)] else { return nil }
        return entries[id]
    }

    // MARK: Views

    /// Returns the live view for a page, creating it (and loading `page.url`, then restoring
    /// `page.scrollY`) if needed. Asking for a suspended page's view resumes it.
    public func webView(for page: Page) -> WKWebView {
        if let entry = entries[page.id] {
            if entry.suspendedKey != nil { resume([page.id]) }
            return entry.webView
        }
        let entry = makeEntry(for: page.id)
        entry.pendingScrollY = page.scrollY > 0 ? page.scrollY : nil
        startLoad(page.url, in: entry)
        return entry.webView
    }

    public func existingWebView(for id: PageID) -> WKWebView? { entries[id]?.webView }

    public func isLive(_ id: PageID) -> Bool { entries[id] != nil }

    /// Loads a URL in a page that already has a view. A page without one picks the URL up from
    /// its model the next time `webView(for:)` is called.
    public func load(_ url: URL, in id: PageID) {
        guard let entry = entries[id] else { return }
        entry.pendingScrollY = nil
        startLoad(url, in: entry)
    }

    private func startLoad(_ url: URL, in entry: Entry) {
        entry.poolInitiatedLoad = true
        if url.isFileURL {
            entry.webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            entry.webView.load(URLRequest(url: url))
        }
    }

    /// Destroys the page's view and deletes its snapshot.
    public func close(_ id: PageID) {
        destroy(id)
        snapshotCache.removeObject(forKey: id.raw as NSUUID)
        try? FileManager.default.removeItem(at: snapshotURL(for: id))
    }

    // MARK: Suspension

    /// The pages dropped onto the shelf: media is paused, the views leave their window but stay
    /// alive. Only `suspendedSiteLimit` sites stay that way; the least recently shelved beyond
    /// that are snapshotted and destroyed.
    public func suspend(_ ids: [PageID], key: SiteKey) {
        var any = false
        for id in ids {
            guard let entry = entries[id] else { continue }
            any = true
            entry.suspendedKey = key
            entry.isDemoting = false
            let webView = entry.webView
            webView.pauseAllMediaPlayback(completionHandler: nil)
            webView.setAllMediaPlaybackSuspended(true, completionHandler: nil)
            // Snapshot while the view is still in its window when it has one, then detach.
            if webView.window != nil {
                Task { [weak self] in
                    _ = await self?.captureSnapshot(id)
                    guard let self, let current = self.entries[id], current === entry, current.suspendedKey != nil else { return }
                    webView.removeFromSuperview()
                }
            } else {
                webView.removeFromSuperview()
                if !FileManager.default.fileExists(atPath: snapshotURL(for: id).path) {
                    Task { [weak self] in _ = await self?.captureSnapshot(id) }
                }
            }
        }
        guard any else { return }
        suspendedOrder.removeAll { $0 == key }
        suspendedOrder.append(key)
        enforceSuspendedLimit()
    }

    /// The pages came back from the shelf: they no longer count toward the limit.
    public func resume(_ ids: [PageID]) {
        for id in ids {
            guard let entry = entries[id] else { continue }
            entry.suspendedKey = nil
            entry.isDemoting = false
            entry.webView.setAllMediaPlaybackSuspended(false, completionHandler: nil)
        }
        pruneSuspendedOrder()
    }

    /// Site keys currently held suspended, least recently shelved first.
    public var suspendedSites: [SiteKey] { suspendedOrder }

    private func pruneSuspendedOrder() {
        let held = Set(entries.values.compactMap { $0.isDemoting ? nil : $0.suspendedKey })
        suspendedOrder.removeAll { !held.contains($0) }
    }

    private func enforceSuspendedLimit() {
        pruneSuspendedOrder()
        while suspendedOrder.count > suspendedSiteLimit {
            let key = suspendedOrder.removeFirst()
            let victims = entries.values.filter { $0.suspendedKey == key && !$0.isDemoting }
            for entry in victims { entry.isDemoting = true }
            Task { [weak self] in
                for entry in victims {
                    guard let self else { return }
                    _ = await self.captureSnapshot(entry.id)
                    // Resumed, re-shelved or closed while the snapshot was being taken.
                    guard self.entries[entry.id] === entry, entry.isDemoting else { continue }
                    self.destroy(entry.id)
                }
            }
        }
    }

    // MARK: Snapshots

    /// Whether a snapshot exists, without loading it.
    public func hasSnapshot(for id: PageID) -> Bool {
        snapshotCache.object(forKey: id.raw as NSUUID) != nil || FileManager.default.fileExists(atPath: snapshotURL(for: id).path)
    }

    /// The last saved snapshot, from memory or the disk cache.
    public func snapshot(for id: PageID) -> NSImage? {
        let cacheKey = id.raw as NSUUID
        if let image = snapshotCache.object(forKey: cacheKey) { return image }
        guard let image = NSImage(contentsOf: snapshotURL(for: id)), image.isValid else { return nil }
        snapshotCache.setObject(image, forKey: cacheKey)
        return image
    }

    /// Takes a snapshot of the live view now (at most 640 pt wide) and stores it. Returns nil
    /// when the page has no live view, or the view has never been given a size.
    @discardableResult
    public func captureSnapshot(_ id: PageID) async -> NSImage? {
        guard let webView = entries[id]?.webView, webView.bounds.width >= 1, webView.bounds.height >= 1 else { return nil }
        let configuration = WKSnapshotConfiguration()
        configuration.snapshotWidth = NSNumber(value: Double(min(webView.bounds.width, 640)))
        configuration.afterScreenUpdates = webView.window != nil
        guard let image = try? await webView.takeSnapshot(configuration: configuration) else { return nil }

        snapshotCache.setObject(image, forKey: id.raw as NSUUID)
        if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let destination = snapshotURL(for: id)
            let size = image.size
            await Task.detached(priority: .utility) {
                let rep = NSBitmapImageRep(cgImage: cgImage)
                rep.size = size
                guard let data = rep.representation(using: .png, properties: [:]) else { return }
                try? data.write(to: destination, options: .atomic)
            }.value
        }
        // Closed while the PNG was being written.
        if entries[id] == nil, !FileManager.default.fileExists(atPath: snapshotURL(for: id).path) {
            snapshotCache.removeObject(forKey: id.raw as NSUUID)
        }
        return image
    }

    private func snapshotURL(for id: PageID) -> URL {
        snapshotDirectory.appendingPathComponent(id.raw.uuidString.lowercased() + ".png")
    }

    // MARK: Navigation commands

    public func goBack(_ id: PageID) { entries[id]?.webView.goBack() }
    public func goForward(_ id: PageID) { entries[id]?.webView.goForward() }
    public func reload(_ id: PageID) { entries[id]?.webView.reload() }
    public func stopLoading(_ id: PageID) { entries[id]?.webView.stopLoading() }
    public func canGoBack(_ id: PageID) -> Bool { entries[id]?.webView.canGoBack ?? false }
    public func canGoForward(_ id: PageID) -> Bool { entries[id]?.webView.canGoForward ?? false }

    /// Selects and scrolls to the next (or previous) match, wrapping around. False when nothing matches.
    public func find(_ text: String, in id: PageID, backwards: Bool = false) async -> Bool {
        guard let webView = entries[id]?.webView, !text.isEmpty else { return false }
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        configuration.wraps = true
        configuration.caseSensitive = false
        return (try? await webView.find(text, configuration: configuration))?.matchFound ?? false
    }

    // MARK: Zoom

    public func zoom(_ id: PageID) -> Double { entries[id].map { Double($0.webView.pageZoom) } ?? 1 }

    static func clampedZoom(_ zoom: Double) -> Double {
        min(max(zoom, zoomSteps[0]), zoomSteps[zoomSteps.count - 1])
    }

    /// A zoom the user chose: the page keeps it even when the default zoom changes.
    public func setZoom(_ zoom: Double, for id: PageID) {
        guard let entry = entries[id] else { return }
        entry.manualZoom = true
        entry.webView.pageZoom = CGFloat(Self.clampedZoom(zoom))
    }

    public func zoomIn(_ id: PageID) {
        let current = zoom(id)
        setZoom(Self.zoomSteps.first { $0 > current + 0.001 } ?? current, for: id)
    }

    public func zoomOut(_ id: PageID) {
        let current = zoom(id)
        setZoom(Self.zoomSteps.last { $0 < current - 0.001 } ?? current, for: id)
    }

    /// "Actual Size": back to the default zoom from Settings, which the page follows again.
    public func resetZoom(_ id: PageID) {
        guard let entry = entries[id] else { return }
        entry.manualZoom = false
        entry.webView.pageZoom = CGFloat(Self.clampedZoom(settings.defaultZoom))
    }

    // MARK: Reporting

    func reportUpdate(_ id: PageID) {
        guard let entry = entries[id] else { return }
        let title = entry.webView.title.flatMap { $0.isEmpty ? nil : $0 }
        callbacks.didUpdate(id, entry.webView.url, title, entry.siteNameHint)
    }

    func reportLoading(_ id: PageID) {
        guard let entry = entries[id] else { return }
        callbacks.loadingChanged(id, entry.webView.isLoading, entry.webView.estimatedProgress)
    }

    /// `fullscreenState` only changes for element full screen (a video or any element calling
    /// `requestFullscreen`, which is also what the native video controls use on macOS); putting the
    /// window itself into full screen leaves it `.notInFullscreen`, so this never fires for that.
    func reportFullscreen(_ id: PageID) {
        guard let entry = entries[id] else { return }
        let state = entry.webView.fullscreenState
        let isFullscreen = state == .inFullscreen || state == .enteringFullscreen
        guard isFullscreen != entry.lastFullscreen else { return }
        entry.lastFullscreen = isFullscreen
        callbacks.fullscreenChanged(id, isFullscreen)
    }

    // MARK: Page script messages

    fileprivate func handle(_ message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame else { return }
        // Context-menu links are captured for auxiliary views too.
        if let body = message.body as? [String: Any], body["type"] as? String == "contextLink",
           let view = message.webView as? PlinthWebView {
            view.noteContextLink((body["href"] as? String).flatMap { URL(string: $0) })
            return
        }
        guard let entry = entry(for: message.webView),
              let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "scroll":
            guard entry.pendingScrollY == nil, let y = (body["y"] as? NSNumber)?.doubleValue, y.isFinite else { return }
            callbacks.didScroll(entry.id, max(0, y))
        case "meta":
            // A message from a document that has since been navigated away from.
            guard let pageURL = entry.webView.url,
                  let sender = (body["url"] as? String).flatMap({ URL(string: $0) }),
                  sender.host == pageURL.host else { return }
            let hint = (body["siteName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let siteName = hint.flatMap { $0.isEmpty || $0.count > 80 ? nil : $0 }
            if siteName != entry.siteNameHint {
                entry.siteNameHint = siteName
                reportUpdate(entry.id)
            }
            guard ["http", "https"].contains(pageURL.scheme?.lowercased() ?? "") else { return }
            let icons = (body["icons"] as? [[String: Any]]) ?? []
            favicons.noteIcon(candidates: Self.rankedIcons(icons), pageURL: pageURL, key: siteKey(pageURL))
        default:
            break
        }
    }

    /// Orders icon links best first: the smallest one that is still at least 64 px, else the largest.
    static func rankedIcons(_ icons: [[String: Any]]) -> [URL] {
        var scored: [(url: URL, size: Int)] = []
        for icon in icons {
            guard let href = icon["href"] as? String, let url = URL(string: href) else { continue }
            let rel = (icon["rel"] as? String ?? "").lowercased()
            let sizes = (icon["sizes"] as? String ?? "").lowercased()
            let type = (icon["type"] as? String ?? "").lowercased()
            var size = 0
            for token in sizes.split(separator: " ") {
                if token == "any" { size = max(size, 128); continue }
                let parts = token.split(separator: "x")
                if parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]) { size = max(size, min(w, h)) }
            }
            if size == 0 {
                if rel.contains("apple-touch-icon") { size = 180 }
                else if type.contains("svg") || url.pathExtension.lowercased() == "svg" { size = 128 }
                else if url.pathExtension.lowercased() == "ico" { size = 16 }
                else { size = 32 }
            }
            scored.append((url, size))
        }
        scored.sort { a, b in
            let aBig = a.size >= 64, bBig = b.size >= 64
            if aBig != bBig { return aBig }
            return aBig ? a.size < b.size : a.size > b.size
        }
        var seen = Set<URL>()
        return scored.compactMap { seen.insert($0.url).inserted ? $0.url : nil }
    }
}

/// `WKUserContentController` holds its handlers strongly; this keeps the pool out of that cycle.
private final class MessageRelay: NSObject, WKScriptMessageHandler {
    weak var pool: WebViewPool?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        pool?.handle(message)
    }
}

enum PageScript {
    /// Runs at document end in the main frame, in the pool's own content world (pages cannot see
    /// or forge its messages). Reports the site name and icon links, then scroll offsets at most
    /// twice a second, and the link under each right-click.
    static let source = """
    (function () {
      if (window.__plinthInstalled) { return; }
      window.__plinthInstalled = true;
      var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(WebViewPool.messageName);
      if (!handler) { return; }

      function metaContent(selector) {
        var el = document.querySelector(selector);
        var value = el && el.getAttribute('content');
        return value ? value.trim() : null;
      }
      var lastMeta = null;
      function postMeta() {
        var icons = [];
        var links = document.querySelectorAll('link[rel][href]');
        for (var i = 0; i < links.length && icons.length < 24; i++) {
          var rel = (links[i].getAttribute('rel') || '').toLowerCase();
          var tokens = rel.split(/\\s+/);
          if (tokens.indexOf('icon') < 0 && rel.indexOf('apple-touch-icon') < 0) { continue; }
          if (!links[i].href || links[i].href.indexOf('http') !== 0) { continue; }
          icons.push({ href: links[i].href, rel: rel,
                       sizes: links[i].getAttribute('sizes') || '', type: links[i].getAttribute('type') || '' });
        }
        var message = { type: 'meta', url: location.href,
                        siteName: metaContent('meta[property="og:site_name"]') || metaContent('meta[name="application-name"]'),
                        icons: icons };
        var encoded = JSON.stringify(message);
        if (encoded === lastMeta) { return; }
        lastMeta = encoded;
        handler.postMessage(message);
      }
      postMeta();
      // Sites that fill in their head late (single-page apps).
      window.addEventListener('load', function () { setTimeout(postMeta, 300); }, { once: true });

      // The link under a right-click, for the native menu's "Peek Link" / "Open Link in Split View".
      window.addEventListener('contextmenu', function (event) {
        var target = event.target;
        if (target && target.nodeType !== 1) { target = target.parentElement; }
        var link = target && target.closest ? target.closest('a[href]') : null;
        handler.postMessage({ type: 'contextLink', href: link ? link.href : null });
      }, true);

      var lastSent = 0, timer = null;
      function postScroll() {
        timer = null;
        lastSent = Date.now();
        handler.postMessage({ type: 'scroll', y: window.scrollY });
      }
      window.addEventListener('scroll', function () {
        if (timer !== null) { return; }
        timer = setTimeout(postScroll, Math.max(0, 500 - (Date.now() - lastSent)));
      }, { passive: true });
    })();
    """
}
