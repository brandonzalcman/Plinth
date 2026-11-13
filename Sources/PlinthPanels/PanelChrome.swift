import SwiftUI
import AppKit
import PlinthModel

// MARK: - Palette

/// Colours shared by everything that floats above the page, from docs/brand-guide.md.
/// Light is the Sunrise palette (Ink, Stone, Sand, Sky, Haze, Dawn). Dark is not designed yet;
/// it starts from the Dusk colourway (#1B1A2E surfaces, #F4EEE6 text) with the rest derived so
/// that text keeps at least 4.5:1 against the surface it sits on.
public struct PanelPalette: Equatable, Sendable {
    /// Panel background.
    public var surface: Color
    /// Background of the strip that holds a text field.
    public var inputFill: Color
    /// Soft fills: tags, thumbnails, quiet controls.
    public var fill: Color
    public var border: Color
    public var divider: Color
    public var primary: Color
    public var secondary: Color
    /// Hints, timestamps, placeholder text.
    public var tertiary: Color
    /// Behind a hovered row or button (Haze at low opacity).
    public var hover: Color
    /// Text and icons on a row filled with the accent.
    public var onAccent: Color
    /// Sparing warm tint (Dawn) and the text colour that may sit on it.
    public var warmFill: Color
    public var warmText: Color
    /// "Not found" and similar notices, as text.
    public var notice: Color
    /// Letter-square site icons.
    public var iconFill: Color
    public var iconLetter: Color
    public var shadow: Color

    public init(_ scheme: ColorScheme) {
        let ink = Color(panelHex: 0x1C1C1A), stone = Color(panelHex: 0xF6F1E7)
        let haze = Color(panelHex: 0x93AAFF), dawn = Color(panelHex: 0xFFC9A3)
        onAccent = .white
        if scheme == .dark {
            surface = Color(panelHex: 0x1B1A2E)
            inputFill = Color(panelHex: 0x222139)
            fill = Color(panelHex: 0x2A2944)
            border = Color(panelHex: 0x3A3958)
            divider = Color(panelHex: 0x302F4B)
            primary = Color(panelHex: 0xF4EEE6)
            secondary = Color(panelHex: 0xC3BECB)
            tertiary = Color(panelHex: 0x9792AB)
            hover = haze.opacity(0.16)
            warmFill = dawn.opacity(0.18)
            warmText = dawn
            notice = dawn
            iconFill = stone
            iconLetter = ink
            shadow = Color.black.opacity(0.5)
        } else {
            surface = .white
            inputFill = Color(panelHex: 0xFBF8F2)
            fill = stone
            border = Color(panelHex: 0xE3DCCB)
            divider = Color(panelHex: 0xE3DCCB)
            primary = ink
            secondary = Color(panelHex: 0x4A4A45)
            tertiary = Color(panelHex: 0x6E6B63)
            hover = haze.opacity(0.18)
            warmFill = dawn.opacity(0.6)
            warmText = ink
            notice = Color(panelHex: 0xA23B1C)
            iconFill = ink
            iconLetter = stone
            shadow = ink.opacity(0.14)
        }
    }
}

extension Color {
    init(panelHex hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}

// MARK: - Chrome

/// The floating surface: fill, 1 pt border, continuous corners and the bar's soft shadow.
/// Resolves its colours from `colorScheme`.
public struct PanelChrome: ViewModifier {
    public var cornerRadius: CGFloat
    @Environment(\.colorScheme) private var scheme

    public init(cornerRadius: CGFloat = 20) { self.cornerRadius = cornerRadius }

    public func body(content: Content) -> some View {
        let palette = PanelPalette(scheme)
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .clipShape(shape)
            .background(
                // CSS "0 10px 32px" is a blur of 32, which is a SwiftUI radius of 16.
                shape.fill(palette.surface).shadow(color: palette.shadow, radius: 16, x: 0, y: 10)
            )
            .overlay(shape.strokeBorder(palette.border, lineWidth: 1).allowsHitTesting(false))
    }
}

public extension View {
    func panelChrome(cornerRadius: CGFloat = 20) -> some View { modifier(PanelChrome(cornerRadius: cornerRadius)) }
}

// MARK: - Motion

public enum PanelMotion {
    /// A short spring, or a plain fade-length ease when Reduce Motion is on.
    public static func animation(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.26, dampingFraction: 0.8)
    }
}

private struct PanelRise: ViewModifier {
    var hidden: Bool
    var anchor: UnitPoint
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let moves = hidden && !reduceMotion
        content
            .opacity(hidden ? 0 : 1)
            .scaleEffect(moves ? 0.96 : 1, anchor: anchor)
            .offset(y: moves ? (anchor.y < 0.5 ? -8 : 8) : 0)
    }
}

public extension AnyTransition {
    /// Rise out of the bar: fade plus a small scale and slide from `anchor`. Fades only under Reduce Motion.
    static func panelRise(anchor: UnitPoint = .bottom) -> AnyTransition {
        .modifier(active: PanelRise(hidden: true, anchor: anchor), identity: PanelRise(hidden: false, anchor: anchor))
    }
}

// MARK: - Placement

public enum PanelPlacement: Sendable, Equatable {
    /// Centred, just above the bar.
    case commandBar
    /// Above the bar's right end.
    case shelf
    /// Top right corner of the page area.
    case findBar
}

/// Fills the window, puts one panel where it belongs relative to the bar, and animates it in and out.
/// Empty space stays click-through. Usage:
/// `PanelOverlay(isPresented: showShelf, placement: .shelf) { ShelfView(...) }`
public struct PanelOverlay<Panel: View>: View {
    private let isPresented: Bool
    private let placement: PanelPlacement
    private let metrics: BarMetrics
    private let panel: () -> Panel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(isPresented: Bool, placement: PanelPlacement, metrics: BarMetrics = .standard,
                @ViewBuilder panel: @escaping () -> Panel) {
        self.isPresented = isPresented; self.placement = placement; self.metrics = metrics; self.panel = panel
    }

    private var alignment: Alignment {
        switch placement {
        case .commandBar: return .bottom
        case .shelf: return .bottomTrailing
        case .findBar: return .topTrailing
        }
    }
    private var anchor: UnitPoint {
        switch placement {
        case .commandBar: return .bottom
        case .shelf: return .bottomTrailing
        case .findBar: return .topTrailing
        }
    }

    public var body: some View {
        ZStack(alignment: alignment) {
            Color.clear.allowsHitTesting(false)
            if isPresented {
                panel().transition(.panelRise(anchor: anchor))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
        .padding(.horizontal, metrics.sideInset)
        .padding(.top, 12)
        .padding(.bottom, metrics.bottomInset + metrics.barHeight + 8)
        .animation(PanelMotion.animation(reduceMotion: reduceMotion), value: isPresented)
    }
}

// MARK: - Outside clicks

private struct PanelSwallowsOutsideClicksKey: EnvironmentKey {
    static let defaultValue = false
}

public extension EnvironmentValues {
    /// When false (the default) a click outside an open panel dismisses it and is then delivered as
    /// usual. When true the click only dismisses.
    var panelSwallowsOutsideClicks: Bool {
        get { self[PanelSwallowsOutsideClicksKey.self] }
        set { self[PanelSwallowsOutsideClicksKey.self] = newValue }
    }
}

/// Sits behind a panel and reports mouse-downs in the same window that land outside it. Also
/// catches Escape when no text field has focus (the fields handle Escape themselves).
struct OutsideClickMonitor: NSViewRepresentable {
    var onOutside: () -> Void

    func makeNSView(context: Context) -> MonitorView { MonitorView() }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.onOutside = onOutside
        view.swallows = context.environment.panelSwallowsOutsideClicks
    }

    final class MonitorView: NSView {
        var onOutside: (() -> Void)?
        var swallows = false
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                if event.type == .keyDown {
                    // Escape, with no modifiers, while focus is somewhere other than a text field.
                    let plain = event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
                    guard event.keyCode == 53, plain, !(window.firstResponder is NSTextView) else { return event }
                    self.onOutside?()
                    return nil
                }
                let point = self.convert(event.locationInWindow, from: nil)
                guard !self.bounds.contains(point) else { return event }
                self.onOutside?()
                return self.swallows ? nil : event
            }
        }

        private func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        deinit { removeMonitor() }
    }
}
