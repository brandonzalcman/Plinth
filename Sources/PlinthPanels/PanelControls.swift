import SwiftUI
import AppKit
import PlinthModel

// Small controls shared by the floating cards and pills (resume card, ask panel, group pills,
// peek, downloads). Internal, except for the brand accent constant.

public extension PanelPalette {
    /// Sky (#2F5BEA), the brand accent. A default for views that take an `accent` parameter.
    static let sky = Color(.sRGB, red: 0x2F / 255.0, green: 0x5B / 255.0, blue: 0xEA / 255.0, opacity: 1)
}

// MARK: - Buttons

/// A 22 pt round "×" with a Haze hover wash, optionally followed by a key hint such as "esc".
struct PanelCloseButton: View {
    var label: String
    var hint: String? = nil
    var palette: PanelPalette
    var action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let hint {
                    Text(hint)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(palette.tertiary)
                        .accessibilityHidden(true)
                }
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(palette.secondary)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(hovered ? palette.hover : palette.fill))
            }
            .padding(.leading, hint == nil ? 0 : 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

/// A compact text button: accent-filled (white semibold text) or quiet (no fill, Haze on hover).
struct PanelPillButton: View {
    enum Style { case accent(Color), quiet }
    var title: String
    var systemImage: String? = nil
    /// A key hint drawn after the title, e.g. "⏎".
    var hint: String? = nil
    var style: Style
    var height: CGFloat = 26
    var palette: PanelPalette
    var action: () -> Void
    @State private var hovered = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let isAccent: Bool = { if case .accent = style { return true }; return false }()
        let foreground = isAccent ? palette.onAccent : palette.primary
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 10, weight: .bold))
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(.system(size: 12, weight: isAccent ? .semibold : .medium))
                    .lineLimit(1)
                if let hint {
                    Text(hint)
                        .font(.system(size: 11, weight: .medium))
                        .opacity(0.75)
                        .accessibilityHidden(true)
                }
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 10)
            .frame(height: height)
            .background(background(isAccent: isAccent))
            .contentShape(Rectangle())
            .fixedSize()
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { hovered = $0 }
    }

    @ViewBuilder
    private func background(isAccent: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: min(9, height / 2), style: .continuous)
        switch style {
        case .accent(let color):
            shape.fill(color).overlay(shape.fill(Color.white.opacity(hovered && isEnabled ? 0.12 : 0)))
        case .quiet:
            shape.fill(hovered && isEnabled ? palette.hover : Color.clear)
        }
    }
}

// MARK: - Site icon stack

/// Up to `limit` small site icons, overlapping slightly, each ringed in the surface colour.
struct SiteIconStack: View {
    var keys: [SiteKey]
    var names: [String]
    var icon: (SiteKey) -> NSImage?
    var size: CGFloat = 16
    var limit = 4
    var palette: PanelPalette

    var body: some View {
        HStack(spacing: -size * 0.3) {
            ForEach(Array(keys.prefix(limit).enumerated()), id: \.offset) { index, key in
                SiteIconView(key: key, name: index < names.count ? names[index] : key.host,
                             image: icon(key), size: size)
                    .padding(1.5)
                    .background(RoundedRectangle(cornerRadius: (size + 3) / 4, style: .continuous).fill(palette.surface))
                    .zIndex(Double(limit - index))
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Placeholder shimmer

/// A quiet placeholder line that shimmers while something loads; static under Reduce Motion.
struct ShimmerLine: View {
    var width: CGFloat?
    var height: CGFloat = 9
    var palette: PanelPalette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -1

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: height / 2, style: .continuous)
        shape.fill(palette.fill)
            .overlay {
                if !reduceMotion {
                    GeometryReader { proxy in
                        LinearGradient(colors: [.clear, palette.hover, .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: proxy.size.width * 0.6)
                            .offset(x: phase * proxy.size.width)
                    }
                    .clipShape(shape)
                }
            }
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) { phase = 1.2 }
            }
            .accessibilityHidden(true)
    }
}

// MARK: - Keys without a text field

/// Watches key-downs in its window while it is installed and hands each one to `handle`; an event
/// is swallowed when `handle` returns true. Never takes clicks.
struct PanelKeyMonitor: NSViewRepresentable {
    var handle: (NSEvent, NSWindow) -> Bool

    func makeNSView(context: Context) -> MonitorView { MonitorView() }
    func updateNSView(_ view: MonitorView, context: Context) { view.handle = handle }

    /// No ⌘, ⌥, ⌃ or ⇧ held.
    static func isPlain(_ event: NSEvent) -> Bool {
        event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
    }

    /// A text field or text view is being edited, so Escape and Return belong to it.
    static func isEditingText(in window: NSWindow) -> Bool {
        window.firstResponder is NSTextView
    }

    static let escape: UInt16 = 53
    static func isReturn(_ event: NSEvent) -> Bool { event.keyCode == 36 || event.keyCode == 76 }

    final class MonitorView: NSView {
        var handle: ((NSEvent, NSWindow) -> Bool)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window, event.window === window,
                      let handle = self.handle else { return event }
                return handle(event, window) ? nil : event
            }
        }

        private func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        deinit { removeMonitor() }
    }
}

// MARK: - Text

enum PanelText {
    /// "Docs", "Docs & Mail", "Docs, Mail & Calendar", "Docs, Mail & 3 more".
    static func joinedNames(_ names: [String]) -> String {
        let names = names.filter { !$0.isEmpty }
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2...3: return names.dropLast().joined(separator: ", ") + " & " + names[names.count - 1]
        default: return names.prefix(2).joined(separator: ", ") + " & \(names.count - 2) more"
        }
    }
}
