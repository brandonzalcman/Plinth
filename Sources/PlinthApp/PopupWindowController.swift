import AppKit
import WebKit

/// A window for a page's `window.open` popup (a sign-in window, a payment step...). The page keeps
/// its link to the page that opened it, so it can finish and close itself.
@MainActor
final class PopupWindowController: NSObject, NSWindowDelegate {
    let window: NSWindow
    private let webView: WKWebView
    private var titleObservation: NSKeyValueObservation?
    private weak var app: AppController?

    init(app: AppController, view: WKWebView, size: CGSize?, near parent: NSWindow?) {
        self.app = app
        self.webView = view
        let width = min(max(size?.width ?? 520, 360), 1100)
        let height = min(max(size?.height ?? 680, 300), 900)
        var frame = NSRect(x: 0, y: 0, width: width, height: height)
        if let parent {
            frame.origin = NSPoint(x: parent.frame.midX - width / 2, y: parent.frame.midY - height / 2)
        } else if let screen = NSScreen.main?.visibleFrame {
            frame.origin = NSPoint(x: screen.midX - width / 2, y: screen.midY - height / 2)
        }
        window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 320, height: 240)
        window.delegate = self
        view.frame = NSRect(origin: .zero, size: frame.size)
        view.autoresizingMask = [.width, .height]
        window.contentView = view
        titleObservation = view.observe(\.title, options: [.initial, .new]) { [weak self] view, _ in
            MainActor.assumeIsolated { self?.window.title = view.title?.isEmpty == false ? view.title! : (view.url?.host ?? "Plinth") }
        }
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        titleObservation?.invalidate()
        titleObservation = nil
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        app?.popupClosed(self)
    }
}
