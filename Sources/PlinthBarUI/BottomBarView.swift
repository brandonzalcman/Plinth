import SwiftUI
import AppKit
import PlinthModel

/// Plinth's only chrome: the floating bar that lists open pages by name, grouped by website.
///
/// The view draws a `BarLayout`; it never decides what overflows. Place it at the bottom of the
/// window with `metrics.sideInset` / `metrics.bottomInset` padding. It fills the width it is
/// given and is `metrics.barHeight` tall.
public struct BottomBarView: View {
    private let layoutForWidth: (CGFloat) -> BarLayout
    private let metrics: BarMetrics
    private let accent: Color
    private let icon: (SiteKey) -> NSImage?
    private let onAction: (BarAction) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drag: BarDragModel

    /// - Parameters:
    ///   - layoutForWidth: returns the layout for a bar of the given outer width. It is called with the
    ///     view's width less `BottomBarView.reservedWidth(metrics:)`, the room the shelf button takes,
    ///     which the layout engine does not know about.
    ///   - icon: the site's favicon if it has loaded, else nil.
    public init(layoutForWidth: @escaping (CGFloat) -> BarLayout,
                metrics: BarMetrics = .standard,
                accent: Color,
                icon: @escaping (SiteKey) -> NSImage?,
                onAction: @escaping (BarAction) -> Void) {
        self.layoutForWidth = layoutForWidth
        self.metrics = metrics
        self.accent = accent
        self.icon = icon
        self.onAction = onAction
        _drag = State(initialValue: BarDragModel(itemGap: metrics.itemGap))
    }

    static let shelfWidth: CGFloat = 32
    static let shelfGap: CGFloat = 4

    /// Width the bar keeps back from the layout engine: the shelf button, its gap, and the
    /// gap on the far side of the flexible space.
    public static func reservedWidth(metrics: BarMetrics = .standard) -> CGFloat {
        shelfWidth + shelfGap + metrics.itemGap
    }

    /// Wires drops to actions. The model's closure is not observed, so setting it here is harmless.
    private func configureDrag() {
        let onAction = onAction
        drag.dropAnimation = reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.86)
        drag.onDrop = { outcome in
            switch outcome {
            case .none: break
            case .moveSite(let id, let index): onAction(.moveSite(id, toIndex: index))
            case .movePage(let id, let index): onAction(.movePage(id, toIndex: index))
            case .split(let page, let target): onAction(.splitPages(page, onto: target))
            }
        }
    }

    public var body: some View {
        let palette = BarPalette.resolve(colorScheme)
        let ctx = BarContext(metrics: metrics, palette: palette, accent: accent, icon: icon,
                             onAction: onAction, reduceMotion: reduceMotion, drag: drag)
        let _ = configureDrag()
        let shape = RoundedRectangle(cornerRadius: metrics.barCornerRadius, style: .continuous)
        GeometryReader { geo in
            let width = geo.size.width
            if width > 1 {
                BarContent(layout: layoutForWidth(max(0, width - Self.reservedWidth(metrics: metrics))),
                           width: width, ctx: ctx)
            }
        }
        .frame(height: metrics.barHeight)
        .background {
            shape.fill(palette.bar)
                .shadow(color: palette.shadow, radius: 16, x: 0, y: 10)   // CSS 0 10px 32px: blur 32 = radius 16
        }
        .overlay { shape.strokeBorder(palette.barBorder, lineWidth: 1).allowsHitTesting(false) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Open pages")
    }
}

/// The row inside the bar's chrome.
private struct BarContent: View {
    let layout: BarLayout
    let width: CGFloat
    let ctx: BarContext

    @State private var moreBefore = false
    @State private var moreAfter = false

    private var searchWidth: CGFloat {
        ctx.metrics.searchPadding * 2 + BarTextMeasurer.width("Search", style: .regular)
            + ctx.metrics.searchGap + BarTextMeasurer.width("⌘L", style: .regular)
    }

    /// Room actually left for the sites region, from this view's own arithmetic.
    private var sitesRoom: CGFloat {
        let m = ctx.metrics
        let pins = CGFloat(layout.pins.count)
        var fixed = m.barPadding * 2
        fixed += pins * (m.tile + m.itemGap)                                   // pins, each with its gap
        if !layout.pins.isEmpty { fixed += m.dividerWidth + m.itemGap }        // divider
        fixed += m.itemGap + m.tile                                            // gap, new page
        fixed += m.itemGap * 2                                                 // either side of the flexible space
        fixed += BottomBarView.shelfWidth + BottomBarView.shelfGap + searchWidth
        return max(0, width - fixed)
    }

    private var currentPage: PageID? {
        for site in layout.sites { if let page = site.pages.first(where: \.isCurrent) { return page.id } }
        return nil
    }

    var body: some View {
        let m = ctx.metrics
        let room = sitesRoom
        // The layout says whether to scroll; if its idea of the room and ours ever differ,
        // scrolling is also the fallback, so nothing can push the search button off the bar.
        let scrolls = layout.scrolls || layout.sitesWidth > room + 0.5
        let viewport = min(layout.sitesWidth, room)
        let _ = { ctx.drag.layout = layout }()
        HStack(spacing: m.itemGap) {
            ForEach(layout.pins) { pin in
                PinTileView(pin: pin, ctx: ctx).transition(itemTransition)
            }
            if !layout.pins.isEmpty {
                Rectangle()
                    .fill(ctx.palette.divider)
                    .frame(width: m.dividerWidth, height: m.dividerHeight)
                    .accessibilityHidden(true)
            }
            if !layout.sites.isEmpty {
                sitesRegion(scrolls: scrolls)
                    .frame(width: viewport, height: m.barHeight, alignment: .leading)
                    .zIndex(ctx.drag.isDragging ? 1 : 0)   // a dragged item passes over the new-page button
            }
            NewPageButton(ctx: ctx)
            Spacer(minLength: 0)
            HStack(spacing: BottomBarView.shelfGap) {
                ShelfButton(ctx: ctx)
                SearchButton(width: searchWidth, ctx: ctx)
            }
        }
        .padding(.horizontal, m.barPadding)
        .frame(width: width, height: m.barHeight, alignment: .leading)
        .animation(ctx.reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.86),
                   value: BarLayoutSignature(layout))
    }

    private var itemTransition: AnyTransition {
        ctx.reduceMotion ? .opacity : .scale(scale: 0.9).combined(with: .opacity)
    }

    /// The sites, full bar height so the split bracket has room beneath the buttons.
    private var sitesRow: some View {
        HStack(spacing: ctx.metrics.itemGap) {
            ForEach(layout.sites) { site in
                SiteItemView(site: site, ctx: ctx)
                    .transition(itemTransition)
                    .zIndex(ctx.drag.contains(site: site.id) ? 1 : 0)
            }
        }
        .frame(height: ctx.metrics.barHeight)
        .coordinateSpace(.named(BarDragModel.space))
        .overlay(alignment: .topLeading) { insertionMarker }
        .overlayPreferenceValue(SplitAnchorKey.self) { anchors in
            GeometryReader { proxy in
                if !anchors.isEmpty {
                    SplitBracket(rects: anchors.map { proxy[$0] })
                        .stroke(ctx.palette.accentLine(ctx.accent),
                                style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    /// Where a dragged site or page would land.
    @ViewBuilder
    private var insertionMarker: some View {
        if let x = ctx.drag.markerX {
            let height = ctx.metrics.dividerHeight + 8
            Capsule()
                .fill(ctx.palette.accentLine(ctx.accent))
                .frame(width: 3, height: height)
                .offset(x: x - 1.5, y: (ctx.metrics.barHeight - height) / 2)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .transition(.opacity)
        }
    }

    @ViewBuilder
    private func sitesRegion(scrolls: Bool) -> some View {
        if scrolls {
            ScrollViewReader { reader in
                ScrollView(.horizontal) {
                    sitesRow   // page buttons carry `.id(page.id)` for `scrollTo`
                }
                .scrollIndicators(.hidden)
                .onScrollGeometryChange(for: [Bool].self) { geo in
                    [geo.contentOffset.x > 1,
                     geo.contentOffset.x + geo.containerSize.width < geo.contentSize.width - 1]
                } action: { _, edges in
                    moreBefore = edges[0]
                    moreAfter = edges[1]
                }
                .mask(edgeMask)
                .onChange(of: currentPage) { _, page in reveal(page, in: reader, animated: true) }
                .onAppear { reveal(currentPage, in: reader, animated: false) }
            }
        } else {
            sitesRow
        }
    }

    private func reveal(_ page: PageID?, in reader: ScrollViewProxy, animated: Bool) {
        guard let page else { return }
        if animated && !ctx.reduceMotion {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) { reader.scrollTo(page, anchor: .center) }
        } else {
            reader.scrollTo(page, anchor: .center)
        }
    }

    /// Soft fades on whichever edges have more to scroll to.
    private var edgeMask: some View {
        HStack(spacing: 0) {
            LinearGradient(colors: [.black.opacity(moreBefore ? 0 : 1), .black], startPoint: .leading, endPoint: .trailing)
                .frame(width: 20)
            Rectangle().fill(.black)
            LinearGradient(colors: [.black, .black.opacity(moreAfter ? 0 : 1)], startPoint: .leading, endPoint: .trailing)
                .frame(width: 20)
        }
    }
}

// MARK: - Fixed buttons

private struct NewPageButton: View {
    let ctx: BarContext
    @State private var hovering = false

    var body: some View {
        let m = ctx.metrics
        let shape = RoundedRectangle(cornerRadius: m.tileCornerRadius, style: .continuous)
        Button { ctx.onAction(.newPage) } label: {
            // The artboard's glyph: an 18 pt box, arms from 5 to 19 of 24, stroke 2, round caps.
            Path { path in
                path.move(to: CGPoint(x: 9, y: 3.75)); path.addLine(to: CGPoint(x: 9, y: 14.25))
                path.move(to: CGPoint(x: 3.75, y: 9)); path.addLine(to: CGPoint(x: 14.25, y: 9))
            }
            .stroke(ctx.palette.text, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            .frame(width: 18, height: 18)
            .frame(width: m.tile, height: m.tile)
            .background { if hovering { shape.fill(ctx.palette.hover) } }
            .contentShape(shape)
        }
        .buttonStyle(BarPressStyle())
        .onHover { over in withAnimation(ctx.hoverAnimation) { hovering = over } }
        .help("New page  ⌘T")
        .accessibilityLabel("New page")
    }
}

private struct ShelfButton: View {
    let ctx: BarContext
    @State private var hovering = false

    var body: some View {
        let m = ctx.metrics
        let shape = RoundedRectangle(cornerRadius: m.tileCornerRadius, style: .continuous)
        Button { ctx.onAction(.openShelf) } label: {
            Image(systemName: "tray")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(ctx.palette.text)
                .frame(width: BottomBarView.shelfWidth, height: m.tile)
                .background { if hovering { shape.fill(ctx.palette.hover) } }
                .contentShape(shape)
        }
        .buttonStyle(BarPressStyle())
        .onHover { over in withAnimation(ctx.hoverAnimation) { hovering = over } }
        .help("Shelf: pages that have been put away")
        .accessibilityLabel("Shelf")
    }
}

private struct SearchButton: View {
    let width: CGFloat
    let ctx: BarContext
    @State private var hovering = false

    var body: some View {
        let m = ctx.metrics
        let shape = RoundedRectangle(cornerRadius: m.tileCornerRadius, style: .continuous)
        Button { ctx.onAction(.openCommandBar) } label: {
            HStack(spacing: m.searchGap) {
                Text("Search")
                Text("⌘L")
            }
            .font(ctx.font(.regular))
            .foregroundStyle(ctx.palette.text)
            .lineLimit(1)
            .fixedSize()
            .frame(width: width, height: m.tile)
            .background {
                shape.fill(ctx.palette.searchFill)
                if hovering { shape.fill(ctx.palette.hover) }
            }
            .overlay { shape.strokeBorder(ctx.palette.searchBorder, lineWidth: 1) }
            .contentShape(shape)
        }
        .buttonStyle(BarPressStyle())
        .onHover { over in withAnimation(ctx.hoverAnimation) { hovering = over } }
        .help("Search pages, history and the web  ⌘L")
        .contextMenu {
            Button("Open Shelf") { ctx.onAction(.openShelf) }
        }
        .accessibilityLabel("Search")
    }
}
