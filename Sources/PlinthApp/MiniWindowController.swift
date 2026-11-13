import AppKit
import SwiftUI
import WebKit
import PlinthModel
import PlinthWeb

/// A transient window for a link opened from another app: the page edge to edge, no bar.
/// It shares cookies with the main windows but not their page list. ⌘⇧↩ (or the pill at the
/// top right) moves the page into the frontmost main window, where it joins its site's capsule.
@MainActor
final class MiniWindowController: NSObject, NSWindowDelegate {
    let window: NSWindow
    let initialURL: URL
    private unowned let app: AppController
    private var webView: WKWebView?
    private let root = NSView()
    private let strip = TitleStripView()
    private var promoteHost: NSHostingView<PromotePill>?
    private var titleObservation: NSKeyValueObservation?
    private var colourObservation: NSKeyValueObservation?
    private var promoted = false

    init(app: AppController, url: URL) {
        self.app = app
        self.initialURL = url
        var frame = NSRect(x: 0, y: 0, width: 980, height: 720)
        if let screen = NSScreen.main?.visibleFrame {
            frame.origin = NSPoint(x: screen.midX - frame.width / 2 + 40, y: screen.midY - frame.height / 2 - 40)
        }
        window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        super.init()
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 420, height: 320)
        window.delegate = self
        window.backgroundColor = .plinthWindowBackground

        root.frame = NSRect(origin: .zero, size: frame.size)
        root.autoresizingMask = [.width, .height]
        window.contentView = root

        let view = app.pool.makeAuxiliaryWebView(url: url)
        view.frame = root.bounds
        view.autoresizingMask = [.width, .height]
        root.addSubview(view)
        webView = view

        strip.wantsLayer = true
        strip.autoresizingMask = [.width, .minYMargin]
        root.addSubview(strip)

        let pill = NSHostingView(rootView: PromotePill(accent: app.accent, action: { [weak self] in
            guard let self else { return }
            self.app.promote(self)
        }))
        pill.sizingOptions = [.intrinsicContentSize]
        pill.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(pill)
        NSLayoutConstraint.activate([
            pill.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            pill.topAnchor.constraint(equalTo: root.topAnchor, constant: 4),
        ])
        promoteHost = pill

        titleObservation = view.observe(\.title, options: [.initial, .new]) { [weak self] view, _ in
            MainActor.assumeIsolated { self?.window.title = view.title?.isEmpty == false ? view.title! : url.host ?? "Plinth" }
        }
        colourObservation = view.observe(\.underPageBackgroundColor, options: [.initial, .new]) { [weak self] view, _ in
            MainActor.assumeIsolated { self?.applyColour(of: view) }
        }
        layoutStrip()
    }

    private var titlebarHeight: CGFloat {
        guard !window.styleMask.contains(.fullScreen) else { return 0 }
        return max(0, window.frame.height - window.contentLayoutRect.maxY)
    }

    private func layoutStrip() {
        let height = titlebarHeight
        strip.frame = NSRect(x: 0, y: root.bounds.height - height, width: root.bounds.width, height: height)
        strip.isHidden = height == 0
        webView?.obscuredContentInsets = NSEdgeInsets(top: height, left: 0, bottom: 0, right: 0)
    }

    private func applyColour(of view: WKWebView) {
        let colour = view.underPageBackgroundColor ?? .windowBackgroundColor
        strip.layer?.backgroundColor = colour.cgColor
        let rgb = colour.usingColorSpace(.sRGB)
        let luminance = rgb.map { 0.2126 * $0.redComponent + 0.7152 * $0.greenComponent + 0.0722 * $0.blueComponent } ?? 1
        promoteHost?.appearance = NSAppearance(named: luminance > 0.5 ? .aqua : .darkAqua)
    }

    /// Hands the web view over (for promotion); the window then closes without destroying it.
    func detachWebView() -> WKWebView {
        promoted = true
        let view = webView!
        titleObservation = nil
        colourObservation = nil
        view.removeFromSuperview()
        webView = nil
        return view
    }

    func windowDidResize(_ notification: Notification) { layoutStrip() }
    func windowDidEnterFullScreen(_ notification: Notification) { layoutStrip() }
    func windowDidExitFullScreen(_ notification: Notification) { layoutStrip() }

    func windowWillClose(_ notification: Notification) {
        if !promoted {
            webView?.stopLoading()
            webView?.removeFromSuperview()
            webView = nil
        }
        app.miniWindowDidClose(self)
    }
}

/// "Open in Plinth ⌘⇧↩" at the top right of a mini window.
struct PromotePill: View {
    let accent: Color
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .font(.system(size: 10, weight: .semibold))
                Text("Move to Main Window")
                    .font(.system(size: 12, weight: .medium))
                Text("⌘⇧↩")
                    .font(.system(size: 11))
                    .opacity(0.6)
            }
            .padding(.horizontal, 10)
            .frame(height: 24)
            .foregroundStyle(hovering ? Color.white : (scheme == .dark ? Color(red: 0xF4 / 255, green: 0xEE / 255, blue: 0xE6 / 255)
                                                                       : Color(red: 0x1C / 255, green: 0x1C / 255, blue: 0x1A / 255)))
            .background(Capsule().fill(hovering ? accent : (scheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.07))))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Move this page into the main window")
    }
}
