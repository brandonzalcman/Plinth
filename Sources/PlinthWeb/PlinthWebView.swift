import AppKit
import WebKit

/// The pool's web view: adds "Peek Link" and "Open Link in Split View" to WebKit's link menu.
/// The link URL comes from the page script's `contextmenu` listener, which posts before WebKit
/// builds the menu (both travel over the same ordered connection from the web process).
public final class PlinthWebView: WKWebView {
    /// Test hook (PLINTH_STEPS `contextmenu`): called with the finished menu just before it shows.
    nonisolated(unsafe) public static var menuObserver: ((NSMenu) -> Void)?

    enum LinkAction { case peek, split }

    /// Set by the pool for pooled pages; nil for auxiliary views (no link items then).
    var linkMenuAction: (@MainActor (URL, LinkAction) -> Void)?
    /// Set for auxiliary views: their navigation/UI delegate and observable state.
    var auxiliary: AuxiliaryController?

    private var contextLink: URL?
    private var contextLinkAt: Date = .distantPast

    func noteContextLink(_ url: URL?) {
        contextLink = url
        contextLinkAt = Date()
    }

    public override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        defer { Self.menuObserver?(menu) }
        // A right-click in a subframe posts nothing, so only trust a capture from just now.
        let link = Date().timeIntervalSince(contextLinkAt) < 2 ? contextLink : nil
        contextLink = nil
        guard linkMenuAction != nil, let link,
              ["http", "https", "file"].contains(link.scheme?.lowercased() ?? "") else { return }

        let peek = NSMenuItem(title: "Peek Link", action: #selector(peekLink(_:)), keyEquivalent: "")
        let split = NSMenuItem(title: "Open Link in Split View", action: #selector(splitLink(_:)), keyEquivalent: "")
        for item in [peek, split] {
            item.target = self
            item.representedObject = link
        }

        let anchors = ["WKMenuItemIdentifierOpenLinkInNewWindow", "WKMenuItemIdentifierOpenLink"]
        if let index = anchors.lazy.compactMap({ id in menu.items.firstIndex { $0.identifier?.rawValue == id } }).first {
            menu.insertItem(split, at: index + 1)
            menu.insertItem(peek, at: index + 1)
        } else {
            menu.insertItem(.separator(), at: 0)
            menu.insertItem(split, at: 0)
            menu.insertItem(peek, at: 0)
        }
    }

    @objc private func peekLink(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        linkMenuAction?(url, .peek)
    }

    @objc private func splitLink(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        linkMenuAction?(url, .split)
    }
}
