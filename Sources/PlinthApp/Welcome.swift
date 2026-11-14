import AppKit
import SwiftUI
import Observation
import PlinthPanels
import PlinthSettings

// MARK: - Launching

extension AppController {
    /// First launch of a new profile shows the welcome guide. A profile that already has pages predates the
    /// guide, so it is marked as seen without showing anything.
    func launchWelcomeIfNeeded(profileHadWindows: Bool) {
        let seen = settings.value.hasCompletedOnboarding
        if OnboardingFlow.shouldShowAtLaunch(hasCompleted: seen, profileHadWindows: profileHadWindows) {
            showWelcomeGuide()
        } else if !seen {
            settings.update { $0.hasCompletedOnboarding = true }
        }
    }

    /// Also behind "Show Welcome Guide". PLINTH_WELCOME_CARD=<n> starts a launch-time guide at that card.
    func showWelcomeGuide(startingAtCard card: Int? = nil) {
        welcome?.close()
        let start = card ?? ProcessInfo.processInfo.environment["PLINTH_WELCOME_CARD"].flatMap { Int($0) }
        let controller = WelcomeWindowController(app: self, flow: OnboardingFlow(startingAtCard: start))
        welcome = controller
        controller.show()
    }
}

// MARK: - Window

@MainActor
@Observable
final class WelcomeModel {
    var flow: OnboardingFlow
    @ObservationIgnored var onFinished: () -> Void = {}

    init(flow: OnboardingFlow) { self.flow = flow }

    func apply(_ change: (inout OnboardingFlow) -> Void) {
        change(&flow)
        if flow.isFinished { onFinished() }
    }
}

/// Borderless, so the card floats over the browser like Plinth's other panels.
private final class WelcomeWindow: NSWindow {
    var onEscape: () -> Void = {}
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func cancelOperation(_ sender: Any?) { onEscape() }
}

@MainActor
final class WelcomeWindowController: NSWindowController, NSWindowDelegate {
    static let size = NSSize(width: 720, height: 520)
    private let app: AppController
    private let model: WelcomeModel
    private var finishing = false

    init(app: AppController, flow: OnboardingFlow) {
        self.app = app
        model = WelcomeModel(flow: flow)
        let window = WelcomeWindow(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless],
                                   backing: .buffered, defer: false)
        super.init(window: window)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.onEscape = { [weak self] in self?.model.apply { $0.skip() } }
        model.onFinished = { [weak self] in self?.finish() }

        let host = NSHostingView(rootView: WelcomeView(model: model, app: app,
                                                       importAction: { [weak self] in self?.openImport() }))
        host.frame = NSRect(origin: .zero, size: Self.size)
        window.contentView = host
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show() {
        guard let window else { return }
        if let parent = NSApp.windows.first(where: { $0.isVisible && $0 !== window && $0.canBecomeMain }) {
            let f = parent.frame
            window.setFrameOrigin(NSPoint(x: f.midX - Self.size.width / 2, y: f.midY - Self.size.height / 2))
        } else {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
    }

    private func finish() {
        guard !finishing else { return }
        finishing = true
        if !app.settings.value.hasCompletedOnboarding { app.settings.update { $0.hasCompletedOnboarding = true } }
        window?.animator().alphaValue = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            window?.orderOut(nil)
            if app.welcome === self { app.welcome = nil; app.announceLevelUpIfPossible() }
            // Hand the keyboard back to the browser.
            NSApp.windows.first(where: { $0.canBecomeMain && $0.isVisible })?.makeKeyAndOrderFront(nil)
        }
    }

    private func openImport() {
        model.apply { $0.skip() }
        app.menuSettings(nil)
        app.settingsWindow?.select(section: "import")
    }
}

// MARK: - Root view

struct WelcomeView: View {
    var model: WelcomeModel
    let app: AppController
    var importAction: () -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let p = PanelPalette(scheme)
        let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
        ZStack {
            p.surface
            switch model.flow.phase {
            case .intro:
                WelcomeIntro(reduceMotion: reduceMotion, onDone: { model.apply { $0.introDone() } })
                    .transition(.opacity)
            case .guide:
                WelcomeGuide(model: model, app: app, importAction: importAction)
                    .id(model.flow.cardIndex)
                    .transition(.opacity)
            case .finished:
                EmptyView()
            }
        }
        .animation(.easeInOut(duration: reduceMotion ? 0.15 : 0.35), value: model.flow.phase)
        .frame(width: WelcomeWindowController.size.width, height: WelcomeWindowController.size.height)
        .clipShape(shape)
        .overlay(shape.strokeBorder(p.border, lineWidth: 1).allowsHitTesting(false))
        .environment(\.layoutDirection, .leftToRight)
    }
}

// MARK: - Logo

/// The brand mark from Design/icon/plinth-full.svg, drawn in code so it can animate and follow dark mode
/// (Sunrise in light, the Dusk colourway in dark, per docs/brand-guide.md).
struct PlinthMark: View {
    var dark: Bool
    var size: CGFloat
    /// 0...1 each.
    var tile = 1.0
    var steps = 1.0
    var frame = 1.0
    var sky = 1.0
    var sun = 1.0

    private var tileColor: Color { dark ? Color(welcomeHex: 0x1B1A2E) : Color(welcomeHex: 0xF6F1E7) }
    private var edge: Color { dark ? Color(welcomeHex: 0x3A3958) : Color(welcomeHex: 0xD9D0BC) }
    private var ink: Color { dark ? Color(welcomeHex: 0xF4EEE6) : Color(welcomeHex: 0x1C1C1A) }
    private var gradient: LinearGradient {
        LinearGradient(stops: dark
            ? [.init(color: Color(welcomeHex: 0x3A2A7A), location: 0), .init(color: Color(welcomeHex: 0xB0509A), location: 0.6), .init(color: Color(welcomeHex: 0xFF9E7A), location: 1)]
            : [.init(color: Color(welcomeHex: 0x2F5BEA), location: 0), .init(color: Color(welcomeHex: 0x93AAFF), location: 0.6), .init(color: Color(welcomeHex: 0xFFC9A3), location: 1)],
                       startPoint: .top, endPoint: .bottom)
    }

    var body: some View {
        let k = size / 280
        ZStack {
            RoundedRectangle(cornerRadius: 64 * k, style: .continuous).fill(tileColor)
                .overlay(RoundedRectangle(cornerRadius: 64 * k, style: .continuous).strokeBorder(edge, lineWidth: 1))
                .opacity(tile)
            ArchShape().fill(gradient).opacity(sky)
            Circle().fill(Color(welcomeHex: dark ? 0xFFE0B8 : 0xFFF1DA))
                .frame(width: 52 * k, height: 52 * k)
                .position(x: 140 * k, y: 186 * k + (1 - sun) * 70 * k)
                .mask(ArchShape())
                .opacity(sun > 0 ? 1 : 0)
            ArchShape(open: true).trim(from: 0, to: frame).stroke(ink, style: StrokeStyle(lineWidth: 10 * k, lineJoin: .round))
            step(x: 72, y: 190, w: 136).opacity(steps).offset(y: (1 - steps) * 14 * k)
            step(x: 50, y: 214, w: 180).opacity(steps).offset(y: (1 - steps) * 22 * k)
        }
        .frame(width: size, height: size)
        .compositingGroup()
        .accessibilityHidden(true)
    }

    private func step(x: CGFloat, y: CGFloat, w: CGFloat) -> some View {
        let k = size / 280
        return RoundedRectangle(cornerRadius: 4 * k, style: .continuous).fill(ink)
            .frame(width: w * k, height: 20 * k)
            .position(x: (x + w / 2) * k, y: (y + 10) * k)
            .frame(width: size, height: size)
    }

    /// The arch in the SVG's 280-unit space.
    struct ArchShape: Shape {
        var open = false
        func path(in r: CGRect) -> Path {
            let k = r.width / 280
            func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * k, y: r.minY + y * k) }
            var p = Path()
            p.move(to: pt(92, 192))
            p.addLine(to: pt(92, 108))
            p.addArc(center: pt(140, 108), radius: 48 * k, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
            p.addLine(to: pt(188, 192))
            if !open { p.closeSubpath() }
            return p
        }
    }
}

// MARK: - Mini bar (illustration)

/// A small drawing of the floating bar, enough to read as the real thing.
private struct MiniBar: View {
    struct Site: Identifiable {
        enum Kind { case current, normal, fading }
        let id = UUID()
        var name: String
        var kind: Kind
        var opacity = 1.0
    }
    var sites: [Site]
    var accent: Color
    var dark: Bool
    var showSearch = true
    var width: CGFloat = 400

    var body: some View {
        let p = PanelPalette(dark ? .dark : .light)
        HStack(spacing: 6) {
            PlinthMark(dark: dark, size: 26)
                .padding(.trailing, 2)
            Rectangle().fill(p.divider).frame(width: 1, height: 18)
            HStack(spacing: 2) {
                ForEach(sites) { site in
                    Text(site.name).font(.system(size: 11.5, weight: site.kind == .current ? .semibold : .medium)).lineLimit(1)
                        .foregroundStyle(site.kind == .current ? p.onAccent : (site.kind == .fading ? p.tertiary : p.secondary))
                        .padding(.horizontal, 10).frame(height: 24)
                        .background { if site.kind == .current { Capsule().fill(accent) } }
                        .overlay {
                            if site.kind == .fading {
                                Capsule().strokeBorder(p.tertiary.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                            }
                        }
                        .opacity(site.opacity)
                }
            }
            .padding(3).background(Capsule().fill(p.fill))
            Spacer(minLength: 0)
            if showSearch {
                HStack(spacing: 6) {
                    Text("Search").font(.system(size: 11.5, weight: .medium))
                    Text("⌘L").font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(p.secondary).padding(.horizontal, 11).frame(height: 26)
                .background(Capsule().fill(p.inputFill)).overlay(Capsule().strokeBorder(p.border, lineWidth: 1))
            }
        }
        .padding(.horizontal, 10).frame(width: width, height: 44)
        .background(Capsule().fill(p.surface).shadow(color: p.shadow, radius: 14, y: 8))
        .overlay(Capsule().strokeBorder(p.border, lineWidth: 1))
    }
}

// MARK: - Intro

/// About 2.4 s: the plinth builds itself, the sun rises, the floating bar slides up beneath it.
/// Click anywhere or press Esc to skip. With Reduce Motion it is a short still fade.
private struct WelcomeIntro: View {
    var reduceMotion: Bool
    var onDone: () -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var start = Date()
    @State private var stillShown = false
    static let duration = 2.5

    private func seg(_ t: Double, _ a: Double, _ b: Double) -> Double {
        let x = min(max((t - a) / (b - a), 0), 1)
        return 1 - pow(1 - x, 3)
    }

    var body: some View {
        let p = PanelPalette(scheme)
        let dark = scheme == .dark
        ZStack {
            if reduceMotion {
                scene(t: Self.duration, dark: dark, p: p).opacity(stillShown ? 1 : 0)
            } else {
                TimelineView(.animation) { context in
                    scene(t: context.date.timeIntervalSince(start), dark: dark, p: p)
                }
            }
            VStack {
                Spacer()
                Text("Click or press Esc to skip").font(.system(size: 11.5)).foregroundStyle(p.tertiary).padding(.bottom, 18)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onDone)
        .task {
            if reduceMotion {
                withAnimation(.easeOut(duration: 0.5)) { stillShown = true }
                try? await Task.sleep(for: .seconds(1.8))
            } else {
                start = Date()
                try? await Task.sleep(for: .seconds(Self.duration + 0.1))
            }
            onDone()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Welcome to Plinth")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Skips the animation")
    }

    @ViewBuilder private func scene(t: Double, dark: Bool, p: PanelPalette) -> some View {
        let lift = seg(t, 1.35, 1.95)
        ZStack {
            // A soft glow behind the mark that warms as the sun comes up.
            Circle().fill(RadialGradient(colors: [(dark ? Color(welcomeHex: 0xB0509A) : Color(welcomeHex: 0xFFC9A3)).opacity(0.32 * seg(t, 0.8, 1.6)), .clear],
                                         center: .center, startRadius: 0, endRadius: 190))
                .frame(width: 380, height: 380).offset(y: -50 - 18 * lift)
            PlinthMark(dark: dark, size: 168,
                       tile: seg(t, 0, 0.45), steps: seg(t, 0.1, 0.7), frame: seg(t, 0.35, 1.05),
                       sky: seg(t, 0.8, 1.25), sun: seg(t, 0.95, 1.6))
                .scaleEffect(0.94 + 0.06 * seg(t, 0, 1.6))
                .offset(y: -66 - 18 * lift)
            Text("Plinth")
                .font(.system(size: 30, weight: .semibold)).kerning(-1.3).foregroundStyle(p.primary)
                .opacity(seg(t, 1.3, 1.85)).offset(y: 46 - 18 * lift + (1 - seg(t, 1.3, 1.85)) * 8)
            MiniBar(sites: [.init(name: "Mail", kind: .normal), .init(name: "Docs", kind: .current), .init(name: "News", kind: .fading, opacity: 0.85)],
                    accent: Color(welcomeHex: 0x2F5BEA), dark: dark, showSearch: true, width: 400)
                .opacity(seg(t, 1.7, 2.25))
                .offset(y: 168 + (1 - seg(t, 1.7, 2.25)) * 34)
        }
    }
}

// MARK: - Guide

private struct WelcomeGuide: View {
    var model: WelcomeModel
    let app: AppController
    var importAction: () -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool

    private var card: GuideCard { model.flow.currentCard ?? .bar }
    private var isLast: Bool { model.flow.isLastCard }
    private var index: Int { model.flow.cardIndex ?? 0 }

    var body: some View {
        let p = PanelPalette(scheme)
        let accent = app.accent(dark: scheme == .dark)
        VStack(spacing: 0) {
            HStack {
                Spacer()
                if !isLast {
                    Button("Skip") { model.apply { $0.skip() } }
                        .buttonStyle(.plain).font(.system(size: 12.5, weight: .medium)).foregroundStyle(p.secondary)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .accessibilityLabel("Skip the welcome guide")
                }
            }
            .frame(height: 30).padding(.top, 14).padding(.horizontal, 22)

            illustration(p: p, accent: accent)
                .frame(maxWidth: .infinity).frame(height: 244)
                .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(p.fill))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(p.border.opacity(0.7), lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .padding(.horizontal, 36).padding(.top, 8)

            VStack(spacing: 8) {
                Text(title).font(.system(size: 25, weight: .semibold)).kerning(-0.6).foregroundStyle(p.primary)
                    .accessibilityAddTraits(.isHeader)
                Text(message).font(.system(size: 14)).foregroundStyle(p.secondary).multilineTextAlignment(.center)
                    .lineSpacing(3).frame(maxWidth: 500).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 24).padding(.horizontal, 36)

            Spacer(minLength: 12)

            HStack {
                Group {
                    if index > 0 {
                        guideButton("Back", filled: false, accent: accent) { model.apply { $0.back() } }
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 150, alignment: .leading)
                Spacer()
                HStack(spacing: 7) {
                    ForEach(0..<OnboardingFlow.cards.count, id: \.self) { i in
                        Capsule().fill(i == index ? accent : p.border).frame(width: i == index ? 20 : 7, height: 7)
                    }
                }
                .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8), value: index)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Step \(index + 1) of \(OnboardingFlow.cards.count)")
                Spacer()
                guideButton(isLast ? "Start browsing" : "Next", filled: true, accent: accent) { model.apply { $0.next() } }
                    .frame(width: 150, alignment: .trailing)
            }
            .padding(.horizontal, 36).padding(.bottom, 28)
        }
        .focusable().focusEffectDisabled().focused($focused)
        .onAppear { focused = true }
        .onKeyPress(.rightArrow) { model.apply { $0.next() }; return .handled }
        .onKeyPress(.leftArrow) { model.apply { $0.back() }; return .handled }
        .onKeyPress(.return) { model.apply { $0.next() }; return .handled }
    }

    private var title: String {
        switch card {
        case .bar: "A bar that floats, not a tab strip"
        case .commandBar: "One bar for everything"
        case .shelf: "The shelf remembers for you"
        case .getStarted: "Make yourself at home"
        }
    }

    private var message: String {
        switch card {
        case .bar: "Your pages live in a floating bar at the bottom. The ones you stop using quietly fade away to the shelf, so the bar stays short and nothing is lost."
        case .commandBar: "Press \u{2318}L to search, enter an address, or jump to any page. \u{2318}T opens a new page the same way."
        case .shelf: "Open the shelf with \u{21E7}\u{2318}L. Search it by meaning, like \u{201C}that article about sourdough\u{201D}, and Plinth finds it. It runs on-device, so nothing leaves your Mac."
        case .getStarted: "Bring your bookmarks and history along, and make Plinth the browser that opens your links. You can do both later in Settings."
        }
    }

    @ViewBuilder private func illustration(p: PanelPalette, accent: Color) -> some View {
        switch card {
        case .bar: BarIllustration(accent: accent, reduceMotion: reduceMotion)
        case .commandBar: CommandBarIllustration(accent: accent)
        case .shelf: ShelfIllustration(accent: accent)
        case .getStarted: GetStartedActions(accent: accent, importAction: importAction)
        }
    }

    private func guideButton(_ title: String, filled: Bool, accent: Color, action: @escaping () -> Void) -> some View {
        WelcomeButton(title: title, filled: filled, accent: accent, action: action)
    }
}

private struct WelcomeButton: View {
    var title: String
    var filled: Bool
    var accent: Color
    var systemImage: String? = nil
    var action: () -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var hovered = false

    var body: some View {
        let p = PanelPalette(scheme)
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage { Image(systemName: systemImage).font(.system(size: 11, weight: .semibold)).accessibilityHidden(true) }
                Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            }
            .foregroundStyle(filled ? p.onAccent : p.primary)
            .padding(.horizontal, 18).frame(height: 34)
            .background(Capsule().fill(filled ? accent : (hovered ? p.hover : p.fill)).opacity(filled && hovered ? 0.88 : 1))
            .overlay(Capsule().strokeBorder(filled ? .clear : p.border, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

// MARK: - Card illustrations

private struct BarIllustration: View {
    var accent: Color
    var reduceMotion: Bool
    @Environment(\.colorScheme) private var scheme
    @State private var faded = false

    var body: some View {
        let p = PanelPalette(scheme)
        let dark = scheme == .dark
        VStack(spacing: 18) {
            MiniBar(sites: [.init(name: "Mail", kind: .normal), .init(name: "Docs", kind: .current),
                            .init(name: "News", kind: .fading, opacity: faded ? 0.0 : 1)],
                    accent: accent, dark: dark, showSearch: true, width: 430)
            HStack(spacing: 8) {
                Image(systemName: "arrow.down").font(.system(size: 11, weight: .semibold))
                Text("Pages you leave alone fade to the shelf").font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(p.secondary)
            HStack(spacing: 8) {
                Image(systemName: "tray.full").font(.system(size: 12)).foregroundStyle(p.tertiary)
                ForEach(["Recipes", "Flights", "News"], id: \.self) { name in
                    Text(name).font(.system(size: 11.5, weight: .medium)).foregroundStyle(p.secondary)
                        .padding(.horizontal, 10).frame(height: 24)
                        .background(Capsule().fill(p.surface)).overlay(Capsule().strokeBorder(p.border, lineWidth: 1))
                        .opacity(name == "News" ? (faded ? 1 : 0.35) : 1)
                }
            }
        }
        .task {
            guard !reduceMotion else { faded = true; return }
            while !Task.isCancelled {
                withAnimation(.easeInOut(duration: 1.4)) { faded = true }
                try? await Task.sleep(for: .seconds(2.6))
                withAnimation(.easeInOut(duration: 0.5)) { faded = false }
                try? await Task.sleep(for: .seconds(1.2))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("The floating bar with three pages; the last one fades onto the shelf")
    }
}

private struct KeyCap: View {
    var text: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = PanelPalette(scheme)
        Text(text).font(.system(size: 12, weight: .semibold)).foregroundStyle(p.secondary)
            .padding(.horizontal, 8).frame(minWidth: 26, minHeight: 24)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(p.surface))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(p.border, lineWidth: 1))
    }
}

private struct CommandBarIllustration: View {
    var accent: Color
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = PanelPalette(scheme)
        VStack(spacing: 14) {
            HStack(spacing: 6) { KeyCap(text: "\u{2318}"); KeyCap(text: "L") }
            VStack(spacing: 0) {
                HStack(spacing: 9) {
                    Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(p.tertiary)
                    Text("swift").font(.system(size: 14)).foregroundStyle(p.primary)
                    Rectangle().fill(accent).frame(width: 1.5, height: 17)
                    Spacer()
                }
                .padding(.horizontal, 14).frame(height: 44).background(p.inputFill)
                Rectangle().fill(p.divider).frame(height: 1)
                row("Swift Programming Language", "docs.swift.org", selected: true, p: p)
                row("Search the web for \u{201C}swift\u{201D}", "DuckDuckGo", selected: false, p: p)
            }
            .frame(width: 400)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(p.surface).shadow(color: p.shadow, radius: 12, y: 6))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(p.border, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("The command bar, opened with Command L, showing search results")
    }

    private func row(_ title: String, _ sub: String, selected: Bool, p: PanelPalette) -> some View {
        HStack(spacing: 10) {
            Image(systemName: selected ? "globe" : "magnifyingglass").font(.system(size: 12)).foregroundStyle(selected ? p.onAccent : p.tertiary)
            Text(title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(selected ? p.onAccent : p.primary).lineLimit(1)
            Spacer()
            Text(sub).font(.system(size: 11.5)).foregroundStyle(selected ? p.onAccent.opacity(0.85) : p.tertiary)
        }
        .padding(.horizontal, 14).frame(height: 36)
        .background(selected ? accent : .clear)
    }
}

private struct ShelfIllustration: View {
    var accent: Color
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = PanelPalette(scheme)
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "sparkles").font(.system(size: 13)).foregroundStyle(scheme == .dark ? accent.mix(with: .white, by: 0.38) : accent)
                Text("that article about sourdough").font(.system(size: 13.5)).foregroundStyle(p.primary)
                Spacer()
                HStack(spacing: 4) { KeyCap(text: "\u{21E7}"); KeyCap(text: "\u{2318}"); KeyCap(text: "L") }
            }
            .padding(.horizontal, 14).frame(height: 46).background(p.inputFill)
            Rectangle().fill(p.divider).frame(height: 1)
            row("The Science of a Good Starter", "kingarthurbaking.com", "2 weeks ago", p: p)
            row("Why Your Loaf Isn't Rising", "seriouseats.com", "Last month", p: p)
        }
        .frame(width: 420)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(p.surface).shadow(color: p.shadow, radius: 12, y: 6))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(p.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("The shelf, searched by meaning for an article about sourdough")
    }

    private func row(_ title: String, _ host: String, _ when: String, p: PanelPalette) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 5, style: .continuous).fill(p.iconFill).frame(width: 20, height: 20)
                .overlay(Text(String(title.prefix(1))).font(.system(size: 11, weight: .bold)).foregroundStyle(p.iconLetter))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(p.primary).lineLimit(1)
                Text(host).font(.system(size: 11)).foregroundStyle(p.tertiary)
            }
            Spacer()
            Text(when).font(.system(size: 11)).foregroundStyle(p.tertiary)
        }
        .padding(.horizontal, 14).frame(height: 48)
    }
}

private struct GetStartedActions: View {
    var accent: Color
    @Environment(\.colorScheme) private var scheme0
    private var iconTint: Color { scheme0 == .dark ? accent.mix(with: .white, by: 0.38) : accent }
    var importAction: () -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var isDefault = DefaultBrowser.isDefault()

    var body: some View {
        let p = PanelPalette(scheme)
        VStack(spacing: 12) {
            actionRow(symbol: "square.and.arrow.down", title: "Import from another browser",
                      detail: "Bookmarks and history from Safari, Chrome, Arc or Zen.", p: p) {
                WelcomeButton(title: "Import\u{2026}", filled: false, accent: accent, action: importAction)
            }
            actionRow(symbol: "checkmark.seal", title: isDefault ? "Plinth is your default browser" : "Make Plinth your default",
                      detail: "Links from other apps open here.", p: p) {
                if isDefault {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 20)).foregroundStyle(iconTint)
                        .accessibilityLabel("Already the default browser")
                } else {
                    WelcomeButton(title: "Set as default", filled: true, accent: accent) { DefaultBrowser.makeDefault() }
                }
            }
        }
        .padding(.horizontal, 28)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in isDefault = DefaultBrowser.isDefault() }
    }

    private func actionRow<Trailing: View>(symbol: String, title: String, detail: String, p: PanelPalette,
                                          @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 17, weight: .medium)).foregroundStyle(iconTint)
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(accent.opacity(0.14)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(p.primary)
                Text(detail).font(.system(size: 12)).foregroundStyle(p.secondary)
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 16).frame(height: 68)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(p.surface))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(p.border, lineWidth: 1))
    }
}

private extension Color {
    init(welcomeHex hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, opacity: 1)
    }
}
