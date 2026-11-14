import SwiftUI
import AppKit
import PlinthModel

/// The bar over a stand-in page, with the artboard's sample data: two pins, a three-page capsule
/// whose last page is current, a two-page capsule and one fading single. The layout is built by
/// hand (no layout engine), so nothing collapses when the window narrows; the sites scroll instead.
/// Clicking selects, closing removes, the context menus work on the sample data, and dragging
/// reorders sites and pages or drops one page on another to split.
public struct BottomBarPreviewHarness: View {
    private struct SamplePage { var id = PageID(); var name: String; var fade: FadeStage = .live }
    private struct SampleSite {
        var id = SiteID(); var key: SiteKey; var name: String
        var pages: [SamplePage]; var fade: FadeStage = .live; var isKept = false
    }
    private struct SamplePin { var id = SiteID(); var pageID = PageID(); var key: SiteKey; var name: String }

    private let accent: Color
    private let metrics: BarMetrics
    @State private var pins: [SamplePin]
    @State private var sites: [SampleSite]
    @State private var selected: PageID?
    @State private var split: [PageID] = []
    @State private var lastAction = ""
    @Environment(\.colorScheme) private var colorScheme

    public init(accent: Color = Color(.sRGB, red: 0x2F / 255, green: 0x5B / 255, blue: 0xEA / 255, opacity: 1),
                metrics: BarMetrics = .standard) {
        self.accent = accent
        self.metrics = metrics
        let seat = SamplePage(name: "Seat map")
        _pins = State(initialValue: [
            SamplePin(key: SiteKey("mail.example.com"), name: "Mail"),
            SamplePin(key: SiteKey("calendar.example.com"), name: "Calendar"),
        ])
        // Hosts chosen so the placeholder icon colours land on the artboard's (Sky, purple).
        _sites = State(initialValue: [
            SampleSite(key: SiteKey("exampleair.example"), name: "Example Air",
                       pages: [SamplePage(name: "Flight search"), SamplePage(name: "Fare calendar"), seat]),
            SampleSite(key: SiteKey("docs.example.org"), name: "Docs",
                       pages: [SamplePage(name: "Trip notes"), SamplePage(name: "Budget")]),
            SampleSite(key: SiteKey("news.example.com"), name: "News",
                       pages: [SamplePage(name: "Morning briefing")], fade: .fading),
        ])
        _selected = State(initialValue: seat.id)
    }

    public var body: some View {
        let dark = colorScheme == .dark
        ZStack(alignment: .bottom) {
            fakePage(dark: dark)
            BottomBarView(layoutForWidth: { _ in layout() }, metrics: metrics, accent: accent,
                          icon: { _ in nil }, onAction: handle)
                .padding(.horizontal, metrics.sideInset)
                .padding(.bottom, metrics.bottomInset)
        }
        .frame(minWidth: 640, minHeight: 360)
        .background(dark ? Color(hex: 0x14131F) : Color(hex: 0xFBF8F2))
    }

    private func fakePage(dark: Bool) -> some View {
        let strong = dark ? Color(hex: 0x34324F) : Color(hex: 0xE3DCCB)
        let soft = dark ? Color(hex: 0x262540) : Color(hex: 0xEFEADD)
        let block = dark ? Color(hex: 0x1F1E33) : Color(hex: 0xF6F1E7)
        return VStack(alignment: .leading, spacing: 16) {
            RoundedRectangle(cornerRadius: 6).fill(strong).frame(width: 420, height: 28)
            RoundedRectangle(cornerRadius: 6).fill(soft).frame(height: 12)
            RoundedRectangle(cornerRadius: 6).fill(soft).frame(height: 12)
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 6).fill(soft).frame(width: geo.size.width * 0.7, height: 12)
            }
            .frame(height: 12)
            UnevenRoundedRectangle(topLeadingRadius: 12, topTrailingRadius: 12)
                .fill(block)
                .padding(.top, 16)
                .overlay(alignment: .top) {
                    Text(lastAction).font(.callout.monospaced()).foregroundStyle(.secondary).padding(.top, 40)
                }
        }
        .padding(.top, 64)
        .padding(.horizontal, 140)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityHidden(true)
    }

    // MARK: Layout by hand

    private func layout() -> BarLayout {
        let m = metrics
        var shortcut = 0
        func next() -> Int? { shortcut += 1; return shortcut <= 9 ? shortcut : nil }

        let pinItems = pins.map {
            BarPinItem(id: $0.id, pageID: $0.pageID, key: $0.key, name: $0.name,
                       isCurrent: selected == $0.pageID, shortcut: next())
        }
        let inSplit = split.count == 2 && split.contains(where: { $0 == selected })
        let siteItems: [BarSiteItem] = sites.map { site in
            let single = site.pages.count == 1
            let pages: [BarPageItem] = site.pages.map { page in
                let role: SplitRole? = split.count == 2
                    ? (page.id == split[0] ? .leading : (page.id == split[1] ? .trailing : nil)) : nil
                let current = page.id == selected || (inSplit && role != nil)
                let fading = !current && (page.fade == .fading || site.fade == .fading)
                let style: BarTextStyle = current ? .currentPage : (fading ? .regular : .page)
                let label = min(m.maxLabelWidth, BarTextMeasurer.width(page.name, style: style))
                return BarPageItem(id: page.id, name: page.name, labelWidth: label, isCurrent: current,
                                   fade: fading ? .fading : .live, shortcut: next(), splitRole: role)
            }
            let width: CGFloat
            if single {
                width = m.singlePadding + m.iconSize + m.singleIconGap + pages[0].labelWidth + m.singlePadding
            } else {
                width = m.capsuleLeading + m.iconSize + m.iconTrailing + pages.reduce(0) {
                    $0 + m.capsuleGap + ($1.isCurrent ? m.currentPagePadding : m.pagePadding) * 2 + $1.labelWidth
                } + m.capsuleTrailing
            }
            return BarSiteItem(id: site.id, key: site.key, name: site.name, form: single ? .single : .capsule,
                               fade: site.fade, isKept: site.isKept, pages: pages, pageCount: pages.count,
                               labelWidth: 0, width: width)
        }
        let total = siteItems.reduce(0) { $0 + $1.width } + m.itemGap * CGFloat(max(0, siteItems.count - 1))
        // No overflow handling here: the bar scrolls by itself when the row does not fit.
        return BarLayout(pins: pinItems, sites: siteItems, sitesWidth: total, sitesAvailable: total, scrolls: false)
    }

    // MARK: Actions

    private func handle(_ action: BarAction) {
        lastAction = String(describing: action)
            .replacingOccurrences(of: #"\(raw: [0-9A-F-]+\)"#, with: "(…)", options: .regularExpression)
        switch action {
        case .selectPage(let id):
            selected = id
        case .selectPin(let id):
            selected = pins.first { $0.id == id }?.pageID
        case .closePage(let id):
            removePages { $0.id == id }
        case .closeSite(let id), .shelveSite(let id):
            let gone = Set(sites.first { $0.id == id }?.pages.map(\.id) ?? [])
            removePages { gone.contains($0.id) }
        case .setKept(let id, let kept):
            if let i = sites.firstIndex(where: { $0.id == id }) {
                sites[i].isKept = kept
                if kept { sites[i].fade = .live }
            }
        case .renamePage(let id, let name):
            for s in sites.indices {
                for p in sites[s].pages.indices where sites[s].pages[p].id == id {
                    sites[s].pages[p].name = name ?? "Untitled"
                }
            }
        case .splitWithCurrent(let id):
            if let selected, selected != id { split = [selected, id] }
        case .endSplit:
            split = []
        case .unpin(let id):
            pins.removeAll { $0.id == id }
        case .newPage:
            let page = SamplePage(name: "New page")
            sites.append(SampleSite(key: SiteKey("page\(sites.count).example.net"), name: "Example", pages: [page]))
            selected = page.id
        case .moveSite(let id, let index):
            guard let from = sites.firstIndex(where: { $0.id == id }) else { break }
            let site = sites.remove(at: from)
            sites.insert(site, at: min(max(0, index), sites.count))
        case .movePage(let id, let index):
            for s in sites.indices {
                guard let from = sites[s].pages.firstIndex(where: { $0.id == id }) else { continue }
                let page = sites[s].pages.remove(at: from)
                sites[s].pages.insert(page, at: min(max(0, index), sites[s].pages.count))
            }
        case .splitPages(let dragged, let target):
            // The page dropped on stays leading, the dragged one sits beside it; focus goes to it.
            if dragged != target {
                split = [target, dragged]
                selected = dragged
            }
        case .selectSite, .toggleFold, .openCommandBar, .openShelf, .openDownloads, .pinSite, .resetPin, .movePinToFolder, .removePinFromFolder, .renamePinFolder, .ungroupPinFolder, .goBack, .goForward, .reload, .stopLoading:
            break
        }
    }

    private func removePages(where gone: (SamplePage) -> Bool) {
        for i in sites.indices { sites[i].pages.removeAll(where: gone) }
        sites.removeAll { $0.pages.isEmpty }
        let remaining = Set(sites.flatMap { $0.pages.map(\.id) } + pins.map(\.pageID))
        if !split.allSatisfy(remaining.contains) { split = [] }
        if let current = selected, !remaining.contains(current) { selected = sites.last?.pages.last?.id }
    }
}
