import SwiftUI
import AppKit
import PlinthModel

/// A floating link preview. The shell passes the page's `NSView` (a `WKWebView`) as `content`
/// and places the card, typically at `PeekCardView.cardSize(in:)` (about 70% of the window),
/// centred over a backdrop; clicking outside the card is the shell's job.
///
/// The header shows the page title, its shortened address, a thin accent progress line while
/// loading, an accent "Open as Page" button (⏎) and a close button (esc).
/// - Return calls `onOpen`, unless the preview's content or a text field has keyboard focus
///   (so typing into a form inside the preview still works).
/// - Escape calls `onClose`, unless a text field (outside the content) is being edited.
///
/// The card fills whatever frame it is given.
public struct PeekCardView: View {
    private let title: String
    private let url: URL?
    private let isLoading: Bool
    private let progress: Double
    private let content: NSView
    private let accent: Color
    private let onOpen: () -> Void
    private let onClose: () -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public static let cornerRadius: CGFloat = 16
    public static let headerHeight: CGFloat = 50

    public init(title: String,
                url: URL?,
                isLoading: Bool,
                progress: Double,
                content: NSView,
                accent: Color,
                onOpen: @escaping () -> Void,
                onClose: @escaping () -> Void) {
        self.title = title; self.url = url; self.isLoading = isLoading; self.progress = progress
        self.content = content; self.accent = accent; self.onOpen = onOpen; self.onClose = onClose
    }

    /// About 70% of `container`, kept between 480 × 360 pt and the container itself.
    public static func cardSize(in container: CGSize) -> CGSize {
        func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat { min(max(value, min(low, high)), high) }
        return CGSize(width: clamp(container.width * 0.7, 480, container.width - 32),
                      height: clamp(container.height * 0.7, 360, container.height - 32))
    }

    private var address: String { url.map(ShelfView.location) ?? "" }

    public var body: some View {
        let palette = PanelPalette(scheme)
        VStack(spacing: 0) {
            header(palette: palette)
            Rectangle().fill(palette.divider).frame(height: 1)
                .overlay(alignment: .leading) { progressLine }
            PeekContentHost(content: content)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(palette.inputFill)
        }
        .frame(minWidth: 320, maxWidth: .infinity, minHeight: 240, maxHeight: .infinity)
        .panelChrome(cornerRadius: Self.cornerRadius)
        .background(PanelKeyMonitor { event, window in handleKey(event, window: window) })
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title.isEmpty ? "Preview" : "Preview of \(title)")
        .accessibilityAction(.escape, onClose)
    }

    private func header(palette: PanelPalette) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "eye")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(palette.tertiary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title.isEmpty ? (isLoading ? "Loading…" : address) : title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if !address.isEmpty {
                    Text(address)
                        .font(.system(size: 11))
                        .foregroundStyle(palette.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 12)
            PanelPillButton(title: "Open as Page", hint: "⏎", style: .accent(accent), height: 28,
                            palette: palette, action: onOpen)
                .help("Open this preview as a page (Return)")
            PanelCloseButton(label: "Close preview", hint: "esc", palette: palette, action: onClose)
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .frame(height: Self.headerHeight)
    }

    @ViewBuilder
    private var progressLine: some View {
        GeometryReader { proxy in
            Rectangle()
                .fill(accent)
                .frame(width: proxy.size.width * min(max(progress, 0.05), 1), height: 2)
                .opacity(isLoading ? 1 : 0)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: progress)
                .animation(.easeOut(duration: 0.3), value: isLoading)
        }
        .frame(height: 2)
        .offset(y: 0.5)
        .accessibilityHidden(true)
    }

    private func handleKey(_ event: NSEvent, window: NSWindow) -> Bool {
        guard PanelKeyMonitor.isPlain(event) else { return false }
        let responder = window.firstResponder as? NSView
        let inContent = responder.map { $0 === content || $0.isDescendant(of: content) } ?? false
        if event.keyCode == PanelKeyMonitor.escape {
            if PanelKeyMonitor.isEditingText(in: window), !inContent { return false }
            onClose()
            return true
        }
        if PanelKeyMonitor.isReturn(event) {
            guard !inContent, !PanelKeyMonitor.isEditingText(in: window) else { return false }
            onOpen()
            return true
        }
        return false
    }
}

/// Hosts the shell's view inside a container so SwiftUI only ever sizes the container, and the
/// same web view can move between the peek card and a page without being torn down.
/// The card's own clip shape rounds its bottom corners.
private struct PeekContentHost: NSViewRepresentable {
    var content: NSView

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        install(in: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if content.superview !== container { install(in: container) }
    }

    static func dismantleNSView(_ container: NSView, coordinator: ()) {
        // Hand the content back untouched: the shell may reuse it as a page.
        for view in container.subviews { view.removeFromSuperview() }
    }

    private func install(in container: NSView) {
        for view in container.subviews where view !== content { view.removeFromSuperview() }
        content.removeFromSuperview()
        content.translatesAutoresizingMaskIntoConstraints = true
        content.frame = container.bounds
        content.autoresizingMask = [.width, .height]
        container.addSubview(content)
    }
}
