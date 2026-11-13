import SwiftUI
import AppKit
import PlinthModel

// MARK: - Pin

struct PinTileView: View {
    let pin: BarPinItem
    let ctx: BarContext
    @State private var hovering = false

    var body: some View {
        let m = ctx.metrics
        let shape = RoundedRectangle(cornerRadius: m.tileCornerRadius, style: .continuous)
        Button { ctx.onAction(.selectPin(pin.id)) } label: {
            ZStack {
                if let image = ctx.icon(pin.key) {
                    shape.fill(ctx.palette.pinIconTile)
                    shape.strokeBorder(ctx.palette.pinIconBorder, lineWidth: 1)
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 22, height: 22)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                } else {
                    shape.fill(ctx.palette.pinTile)
                    Text(String(pin.name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased())
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(ctx.palette.pinLetter)
                }
                if hovering { shape.fill(ctx.palette.hover) }
            }
            .frame(width: m.tile, height: m.tile)
            .contentShape(shape)
        }
        .buttonStyle(BarPressStyle())
        .overlay {
            // The ring sits just outside the tile, in the bar's own padding.
            if pin.isCurrent {
                RoundedRectangle(cornerRadius: m.tileCornerRadius + 3, style: .continuous)
                    .strokeBorder(ctx.palette.accentLine(ctx.accent), lineWidth: 2)
                    .padding(-3)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .onHover { over in withAnimation(ctx.hoverAnimation) { hovering = over } }
        .help(pin.name + shortcutSuffix(pin.shortcut))
        .contextMenu {
            Button("Reset to Home") { ctx.onAction(.resetPin(pin.id)) }
            Button("Unpin") { ctx.onAction(.unpin(pin.id)) }
        }
        .accessibilityLabel("\(pin.name), pinned")
        .accessibilityAddTraits(pin.isCurrent ? .isSelected : [])
    }
}

// MARK: - Site

struct SiteItemView: View {
    let site: BarSiteItem
    let ctx: BarContext

    var body: some View {
        Group {
            switch site.form {
            case .single:
                if let page = site.pages.first {
                    PageButton(page: page, site: site, isSingle: true, ctx: ctx)
                        .frame(width: site.width, height: ctx.metrics.tile, alignment: .leading)
                        .id(page.id)
                } else {
                    Color.clear.frame(width: site.width, height: ctx.metrics.tile)
                }
            case .capsule:
                CapsuleView(site: site, ctx: ctx)
            case .collapsed:
                CollapsedSiteView(site: site, ctx: ctx)
            }
        }
        // Whatever the arithmetic inside, the item occupies exactly what the layout said.
        .frame(width: site.width)
        .reportsBarFrame { ctx.drag.siteFrames[site.id] = $0 }
        .barDragLift(ctx.drag.isDragging(site: site.id), splitting: ctx.drag.splitTarget != nil, translation: ctx.drag.translation,
                     backing: ctx.palette.capsule,
                     cornerRadius: site.form == .single ? ctx.metrics.tileCornerRadius : ctx.metrics.capsuleCornerRadius,
                     reduceMotion: ctx.reduceMotion)
    }
}

@ViewBuilder
func siteMenuItems(_ site: BarSiteItem, ctx: BarContext) -> some View {
    Button(site.isKept ? "Stop Keeping" : "Keep on Bar") { ctx.onAction(.setKept(site.id, !site.isKept)) }
    Button("Pin") { ctx.onAction(.pinSite(site.id)) }
    Button("Put Away") { ctx.onAction(.shelveSite(site.id)) }
    Divider()
    Button("Close Site") { ctx.onAction(.closeSite(site.id)) }
}

struct CapsuleView: View {
    let site: BarSiteItem
    let ctx: BarContext

    var body: some View {
        let m = ctx.metrics
        let fading = site.fade == .fading
        let shape = RoundedRectangle(cornerRadius: m.capsuleCornerRadius, style: .continuous)
        // capsuleLeading + icon + iconTrailing + Σ(capsuleGap + button) + capsuleTrailing
        HStack(spacing: 0) {
            // Clicking the icon folds the site down to it; dragging it still moves the site.
            Button {
                guard !ctx.drag.suppressesClick else { return }
                ctx.onAction(.toggleFold(site.id))
            } label: {
                SiteIconView(key: site.key, greyed: fading, ctx: ctx)
                    .padding(.leading, m.capsuleLeading)
                    .padding(.trailing, m.iconTrailing)
                    .frame(height: m.capsuleHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(BarPressStyle())
            .simultaneousGesture(ctx.drag.gesture(for: .site(site.id, page: nil)))
            .help("\(site.name) — click to fold")
            .accessibilityLabel("Fold \(site.name)")
            .contextMenu { siteMenuItems(site, ctx: ctx) }
            ForEach(site.pages) { page in
                PageButton(page: page, site: site, isSingle: false, ctx: ctx)
                    .padding(.leading, m.capsuleGap)
                    .id(page.id)
                    .zIndex(ctx.drag.isDragging(page: page.id) ? 1 : 0)
            }
        }
        .padding(.trailing, m.capsuleTrailing)
        .frame(width: site.width, height: m.capsuleHeight, alignment: .leading)
        .background {
            if fading {
                shape.strokeBorder(ctx.palette.dashed, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            } else {
                shape.fill(ctx.palette.capsule)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(fading ? "\(site.name), fading" : site.name)
    }
}

struct CollapsedSiteView: View {
    let site: BarSiteItem
    let ctx: BarContext
    @State private var hovering = false

    static let iconGap: CGFloat = 8
    static let badgeGap: CGFloat = 6
    static let trailing: CGFloat = 10
    static let badgeHeight: CGFloat = 18

    static func badgeWidth(_ count: Int) -> CGFloat {
        max(badgeHeight, BarTextMeasurer.width(String(count), font: BarTextMeasurer.badgeFont) + 10)
    }

    /// Everything in a collapsed site except its name.
    static func chromeWidth(count: Int, metrics m: BarMetrics) -> CGFloat {
        m.capsuleLeading + m.iconSize + iconGap + badgeGap + badgeWidth(count) + trailing
    }

    var body: some View {
        let m = ctx.metrics
        let fading = site.fade == .fading
        let shape = RoundedRectangle(cornerRadius: m.capsuleCornerRadius, style: .continuous)
        // The name takes whatever the layout's width leaves, so the item always adds up.
        let nameWidth = max(0, site.width - Self.chromeWidth(count: site.pageCount, metrics: m))
        Button {
            guard !ctx.drag.suppressesClick else { return }
            // Folded by hand: the icon unfolds it. Collapsed for room: the click selects its page, which unfolds it.
            ctx.onAction(site.isFolded ? .toggleFold(site.id) : .selectSite(site.id))
        } label: {
            HStack(spacing: 0) {
                SiteIconView(key: site.key, greyed: fading, ctx: ctx)
                    .padding(.leading, m.capsuleLeading)
                    .padding(.trailing, site.labelWidth > 0 ? Self.iconGap : 0)
                if site.labelWidth > 0 {
                    Text(site.name)
                        .font(ctx.font(fading ? .regular : .page))
                        .foregroundStyle(ctx.palette.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(width: nameWidth, alignment: .leading)
                }
                Text(String(site.pageCount))
                    .font(Font(BarTextMeasurer.badgeFont as CTFont))
                    .monospacedDigit()
                    .foregroundStyle(ctx.palette.text)
                    .frame(width: Self.badgeWidth(site.pageCount), height: Self.badgeHeight)
                    .background(Capsule().fill(ctx.palette.badgeFill))
                    .padding(.leading, Self.badgeGap)
                    .padding(.trailing, Self.trailing)
            }
            .frame(width: site.width, height: m.capsuleHeight, alignment: .leading)
            .background {
                if fading {
                    shape.strokeBorder(ctx.palette.dashed, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                } else {
                    shape.fill(ctx.palette.capsule)
                }
            }
            .overlay { if hovering && !ctx.drag.isDragging { shape.fill(ctx.palette.hover) } }
            .contentShape(shape)
        }
        .buttonStyle(BarPressStyle())
        .simultaneousGesture(ctx.drag.gesture(for: .site(site.id, page: nil)))
        .onHover { over in withAnimation(ctx.hoverAnimation) { hovering = over } }
        .help(site.isFolded ? "\(site.name) — \(site.pageCount) pages, click to unfold" : "\(site.name) — \(site.pageCount) pages")
        .contextMenu { siteMenuItems(site, ctx: ctx) }
        .accessibilityLabel("\(site.name), \(site.pageCount) pages\(site.isFolded ? ", folded" : "")\(fading ? ", fading" : "")")
    }
}

// MARK: - Page

/// One named page: inside a capsule, or on its own with the site icon (`isSingle`).
struct PageButton: View {
    let page: BarPageItem
    let site: BarSiteItem
    let isSingle: Bool
    let ctx: BarContext

    @State private var hovering = false
    @State private var renaming = false
    @State private var draft = ""

    private var siteFading: Bool { site.fade == .fading }
    private var fading: Bool { !page.isCurrent && (page.fade == .fading || siteFading) }

    private var textStyle: BarTextStyle {
        if page.isCurrent { return .currentPage }
        // Brand guide: anything fading is set in regular weight.
        return fading ? .regular : .page
    }

    private var textColor: Color {
        if page.isCurrent { return ctx.palette.onAccent }
        // A lone fading page inside a live capsule is set lighter than its neighbours.
        if page.fade == .fading && !siteFading && !isSingle { return ctx.palette.textFaded }
        return ctx.palette.text
    }

    /// A dashed outline on this button alone: a fading single, or a fading page in a live capsule.
    /// (A fading capsule carries the dashes itself.)
    private var dashedOutline: Bool { fading && (isSingle || !siteFading) }

    var body: some View {
        let m = ctx.metrics
        let shape = RoundedRectangle(cornerRadius: m.tileCornerRadius, style: .continuous)
        let padding = isSingle ? m.singlePadding : (page.isCurrent ? m.currentPagePadding : m.pagePadding)
        let dragging = ctx.drag.isDragging
        let isTarget = ctx.drag.splitTarget == page.id
        Button {
            guard !ctx.drag.suppressesClick else { return }
            ctx.onAction(.selectPage(page.id))
        } label: {
            HStack(spacing: m.singleIconGap) {
                if isSingle { SiteIconView(key: site.key, greyed: fading, onAccent: page.isCurrent, ctx: ctx) }
                Text(page.name)
                    .font(ctx.font(textStyle))
                    .foregroundStyle(textColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: page.labelWidth, alignment: isSingle ? .leading : .center)
            }
            .padding(.horizontal, padding)
            .frame(height: m.tile)
            .background {
                if page.isCurrent {
                    shape.fill(ctx.accent)
                } else if isTarget {
                    shape.fill(ctx.palette.dropTarget)
                } else if hovering && !dragging {
                    shape.fill(ctx.palette.hover)
                }
            }
            .overlay {
                if isTarget {
                    // Just outside the button, like the current pin's ring, so it shows round a dragged chip.
                    RoundedRectangle(cornerRadius: m.tileCornerRadius + 3, style: .continuous)
                        .strokeBorder(ctx.palette.accentLine(ctx.accent), lineWidth: 2)
                        .padding(-3)
                } else if dashedOutline {
                    shape.strokeBorder(ctx.palette.dashed, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(BarPressStyle())
        // A single-page site's button moves the whole site; a capsule's page moves within it.
        .simultaneousGesture(ctx.drag.gesture(for: isSingle ? .site(site.id, page: page.id) : .page(page.id, site: site.id)))
        .reportsBarFrame { ctx.drag.pageFrames[page.id] = $0 }
        .barDragLift(!isSingle && ctx.drag.isDragging(page: page.id), splitting: ctx.drag.splitTarget != nil, translation: ctx.drag.translation,
                     backing: ctx.palette.capsule, cornerRadius: m.tileCornerRadius, reduceMotion: ctx.reduceMotion)
        .overlay(alignment: .trailing) {
            if hovering && !dragging { closeButton.padding(.trailing, 5).transition(.opacity) }
        }
        .background(MiddleClickCatcher(isActive: hovering) { ctx.onAction(.closePage(page.id)) })
        .onHover { over in withAnimation(ctx.hoverAnimation) { hovering = over } }
        .anchorPreference(key: SplitAnchorKey.self, value: .bounds) { page.splitRole != nil ? [$0] : [] }
        .help(page.name + shortcutSuffix(page.shortcut))
        .contextMenu { menu }
        .popover(isPresented: $renaming, arrowEdge: .top) { renamePopover }
        .accessibilityLabel(accessibilityName)
        .accessibilityAddTraits(page.isCurrent ? .isSelected : [])
        .accessibilityAction(named: "Close") { ctx.onAction(.closePage(page.id)) }
    }

    private var accessibilityName: String {
        var label = isSingle && site.name != page.name ? "\(page.name) on \(site.name)" : page.name
        if fading { label += ", fading" }
        if page.splitRole != nil { label += ", in split view" }
        return label
    }

    private var closeButton: some View {
        Button { ctx.onAction(.closePage(page.id)) } label: {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(page.isCurrent ? ctx.palette.onAccent : ctx.palette.text)
                .frame(width: 18, height: 18)
                .background {
                    // Opaque, so the end of the name does not show through.
                    if page.isCurrent {
                        Circle().fill(ctx.accent).overlay(Circle().fill(Color.black.opacity(0.22)))
                    } else {
                        Circle().fill(ctx.palette.closeFill)
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(BarPressStyle())
        .help("Close \(page.name)")
        .accessibilityHidden(true)   // offered as the page button's "Close" action instead
    }

    @ViewBuilder private var menu: some View {
        Button("Close") { ctx.onAction(.closePage(page.id)) }
        Button("Rename…") {
            draft = page.name
            renaming = true
        }
        if page.splitRole != nil {
            Button("End Split") { ctx.onAction(.endSplit) }
        } else {
            Button("Open in Split View") { ctx.onAction(.splitWithCurrent(page.id)) }
                .disabled(page.isCurrent)
        }
        Divider()
        if isSingle {
            siteMenuItems(site, ctx: ctx)
        } else {
            Menu(site.name) { siteMenuItems(site, ctx: ctx) }
        }
    }

    private var renamePopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Rename Page").font(.headline)
            TextField("Page name", text: $draft)
                .textFieldStyle(.roundedBorder)
                .frame(width: 230)
                .onSubmit(commitRename)
            Text("Leave empty to go back to the page’s own name.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { renaming = false }.keyboardShortcut(.cancelAction)
                Button("Rename", action: commitRename).keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
    }

    private func commitRename() {
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        renaming = false
        ctx.onAction(.renamePage(page.id, name.isEmpty ? nil : name))
    }
}
