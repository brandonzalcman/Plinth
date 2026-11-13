import SwiftUI
import AppKit
import PlinthModel

/// What every piece of the bar needs to draw itself and report back.
struct BarContext {
    var metrics: BarMetrics
    var palette: BarPalette
    var accent: Color
    var icon: (SiteKey) -> NSImage?
    var onAction: (BarAction) -> Void
    var reduceMotion: Bool
    var drag: BarDragModel

    var hoverAnimation: Animation? { reduceMotion ? nil : .easeOut(duration: 0.12) }

    func font(_ style: BarTextStyle) -> Font { Font(BarTextMeasurer.font(for: style) as CTFont) }
}

/// Bar buttons draw themselves; this only adds the pressed state.
struct BarPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.78 : 1)
    }
}

// MARK: - Site icon

/// A favicon, or a rounded square in the site's colour until one loads.
struct SiteIconView: View {
    let key: SiteKey
    /// Fading: tinted Dawn instead of the site's own colours.
    var greyed: Bool = false
    /// On the accent fill: a light hairline so a blue or dark icon still reads.
    var onAccent: Bool = false
    let ctx: BarContext

    var body: some View {
        let size = ctx.metrics.iconSize
        let shape = RoundedRectangle(cornerRadius: ctx.metrics.iconCornerRadius, style: .continuous)
        Group {
            if let image = ctx.icon(key) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .saturation(greyed ? 0 : 1)
                    .colorMultiply(greyed ? ctx.palette.fadingIcon : .white)
            } else {
                shape.fill(greyed ? ctx.palette.fadingIcon : SiteTint.color(for: key))
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay { if onAccent { shape.strokeBorder(Color.white.opacity(0.55), lineWidth: 1) } }
        .accessibilityHidden(true)
    }
}

// MARK: - Middle click

/// Calls `action` when the middle mouse button is released while `isActive`.
/// SwiftUI has no gesture for this. The view itself never takes part in hit testing;
/// the owner says when the pointer is over it (via `onHover`, which respects clipping).
struct MiddleClickCatcher: NSViewRepresentable {
    var isActive: Bool
    var action: () -> Void

    func makeNSView(context: Context) -> CatcherView { CatcherView() }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.isActive = isActive
        view.action = action
    }

    static func dismantleNSView(_ view: CatcherView, coordinator: ()) { view.removeMonitor() }

    final class CatcherView: NSView {
        var isActive = false
        var action: () -> Void = {}
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseUp) { [weak self] event in
                guard let self, self.isActive, event.buttonNumber == 2, event.window === self.window else { return event }
                self.action()
                return nil
            }
        }

        func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}

// MARK: - Split bracket

/// Bounds of the page buttons that are in the split, so the sites row can tie them together.
struct SplitAnchorKey: PreferenceKey {
    static var defaultValue: [Anchor<CGRect>] = []
    static func reduce(value: inout [Anchor<CGRect>], nextValue: () -> [Anchor<CGRect>]) {
        value.append(contentsOf: nextValue())
    }
}

/// One line running under both split pages with its ends turned up towards them:
/// a shallow tray that holds the pair, whether or not they share a capsule.
struct SplitBracket: Shape {
    var rects: [CGRect]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard let left = rects.map(\.minX).min(), let right = rects.map(\.maxX).max(),
              let bottom = rects.map(\.maxY).max() else { return path }
        let x0 = left + 8, x1 = right - 8
        guard x1 - x0 > 8 else { return path }
        let top = bottom + 2, line = bottom + 5.5
        path.move(to: CGPoint(x: x0, y: top))
        path.addArc(tangent1End: CGPoint(x: x0, y: line), tangent2End: CGPoint(x: x1, y: line), radius: 3.5)
        path.addArc(tangent1End: CGPoint(x: x1, y: line), tangent2End: CGPoint(x: x1, y: top), radius: 3.5)
        path.addLine(to: CGPoint(x: x1, y: top))
        return path
    }
}

// MARK: - Animation identity

/// What has to change for the bar to animate. Label widths are left out on purpose,
/// so resizing the window re-lays the bar without springing.
struct BarLayoutSignature: Hashable {
    struct PageSig: Hashable { var id: PageID; var name: String; var current: Bool; var fading: Bool; var split: Bool }
    struct SiteSig: Hashable { var id: SiteID; var form: Int; var fading: Bool; var pages: [PageSig] }
    struct PinSig: Hashable { var id: SiteID; var current: Bool }

    var pins: [PinSig]
    var sites: [SiteSig]

    init(_ layout: BarLayout) {
        pins = layout.pins.map { PinSig(id: $0.id, current: $0.isCurrent) }
        sites = layout.sites.map { site in
            let form: Int
            switch site.form {
            case .single: form = 0
            case .capsule: form = 1
            case .collapsed: form = 2
            }
            return SiteSig(id: site.id, form: form, fading: site.fade == .fading, pages: site.pages.map {
                PageSig(id: $0.id, name: $0.name, current: $0.isCurrent, fading: $0.fade == .fading, split: $0.splitRole != nil)
            })
        }
    }
}

func shortcutSuffix(_ shortcut: Int?) -> String {
    guard let shortcut else { return "" }
    return "  ⌘\(shortcut)"
}
