import Foundation
import PlinthModel

/// Where a window shows its pages: Plinth's floating bar along the bottom, or the vertical sidebar.
public enum TabLayout: String, Codable, CaseIterable, Sendable {
    case dock
    case sidebar

    public var displayName: String {
        switch self {
        case .dock: "Bottom dock"
        case .sidebar: "Sidebar"
        }
    }
}

/// Everything the sidebar draws for one window. Built from the same store state as the bottom bar
/// (`BarInput`) and answered with the same `BarAction`s, so both layouts behave identically.
///
/// The sidebar is Plinth's own design rather than a list of tabs: pins sit in a tile row at the
/// top, then each website is one card with its pages listed by name under it. A site with one page
/// is a single row. Fading pages are drawn faint, the same signal the bar gives with its dashed outline.
public struct SidebarModel: Equatable, Sendable {
    public var pins: [PinSlot]
    public var sites: [SiteCard]
    public var selected: PageID?

    public enum PinSlot: Identifiable, Equatable, Sendable {
        case pin(Pin)
        case folder(Folder)

        public var id: String {
            switch self {
            case .pin(let p): "pin-" + p.id.raw.uuidString
            case .folder(let f): "folder-" + f.id.uuidString
            }
        }

        public var isCurrent: Bool {
            switch self {
            case .pin(let p): p.isCurrent
            case .folder(let f): f.isCurrent
            }
        }
    }

    public struct Pin: Identifiable, Equatable, Sendable {
        public var id: SiteID
        public var pageID: PageID
        public var key: SiteKey
        public var name: String
        public var isCurrent: Bool
        public var shortcut: Int?
        public var folderID: UUID?
    }

    public struct Folder: Identifiable, Equatable, Sendable {
        public var id: UUID
        public var name: String
        public var members: [Pin]
        public var isCurrent: Bool { members.contains(where: \.isCurrent) }
    }

    public struct SiteCard: Identifiable, Equatable, Sendable {
        public var id: SiteID
        public var key: SiteKey
        public var name: String
        public var pages: [PageRow]
        public var isKept: Bool
        public var isFolded: Bool
        public var fade: FadeStage
        /// One of its pages is on screen.
        public var isCurrent: Bool { pages.contains(where: \.isCurrent) }
        /// One page: the card is a single row with the page's name, like the bar's single button.
        public var isSingle: Bool { pages.count == 1 }
        /// Pages listed under the site's header. A folded site lists none unless one is selected,
        /// since selecting a page unfolds it (the store does that; this only mirrors it).
        public var visiblePages: [PageRow] { isSingle || (isFolded && !isCurrent) ? [] : pages }
    }

    public struct PageRow: Identifiable, Equatable, Sendable {
        public var id: PageID
        public var name: String
        /// The focused page, and its split partner while the split is showing.
        public var isCurrent: Bool
        public var fade: FadeStage
        public var shortcut: Int?
        public var splitRole: SplitRole?
        /// When the page was last used, for the sidebar's gradual fade.
        public var lastUsed: Date = .distantPast
    }

    public init(pins: [PinSlot], sites: [SiteCard], selected: PageID?) {
        self.pins = pins; self.sites = sites; self.selected = selected
    }

    /// The model for `input` — the same input the bar layout engine takes.
    public init(_ input: BarInput) {
        let order = BarOrder.pageOrder(pins: input.pins, sites: input.sites)
        var shortcuts: [PageID: Int] = [:]
        for (i, id) in order.prefix(9).enumerated() { shortcuts[id] = i + 1 }
        let split = input.split
        let current: Set<PageID> = {
            guard let selected = input.selected else { return [] }
            if let split, split.contains(selected) { return [split.leading, split.trailing] }
            return [selected]
        }()

        var slots: [PinSlot] = []
        var folderIndex: [UUID: Int] = [:]
        for pin in BarOrder.arranged(input.pins) {
            let item = Pin(id: pin.id, pageID: pin.page.id, key: pin.key, name: pin.name,
                           isCurrent: current.contains(pin.page.id), shortcut: shortcuts[pin.page.id],
                           folderID: pin.folder?.id)
            if let folder = pin.folder {
                if let i = folderIndex[folder.id], case .folder(var f) = slots[i] {
                    f.members.append(item)
                    slots[i] = .folder(f)
                } else {
                    folderIndex[folder.id] = slots.count
                    slots.append(.folder(Folder(id: folder.id, name: folder.name, members: [item])))
                }
            } else {
                slots.append(.pin(item))
            }
        }

        let cards = input.sites.map { site in
            SiteCard(id: site.id, key: site.key, name: site.name,
                     pages: site.pages.map { page in
                         PageRow(id: page.id, name: page.name, isCurrent: current.contains(page.id),
                                 fade: site.isKept ? .live : page.fade, shortcut: shortcuts[page.id],
                                 splitRole: split.flatMap { s in
                                     page.id == s.leading ? .leading : (page.id == s.trailing ? .trailing : nil)
                                 },
                                 lastUsed: page.usage.lastUsed)
                     },
                     isKept: site.isKept, isFolded: site.isFolded && site.pages.count > 1,
                     fade: site.isKept ? .live : site.fade)
        }
        self.init(pins: slots, sites: cards, selected: input.selected)
    }

    /// Every pin, folder members included, in order.
    public var allPins: [Pin] {
        pins.flatMap { slot -> [Pin] in
            switch slot {
            case .pin(let p): [p]
            case .folder(let f): f.members
            }
        }
    }

    /// The collapsed sidebar: a slim rail of icons, pins first, then one per site.
    public var rail: [RailItem] {
        allPins.map { RailItem(kind: .pin($0.id), key: $0.key, name: $0.name, isCurrent: $0.isCurrent, pageCount: 1) }
            + sites.map { RailItem(kind: .site($0.id), key: $0.key, name: $0.name, isCurrent: $0.isCurrent,
                                   pageCount: $0.pages.count) }
    }

    public struct RailItem: Identifiable, Equatable, Sendable {
        public enum Kind: Hashable, Sendable { case pin(SiteID), site(SiteID) }
        public var kind: Kind
        public var key: SiteKey
        public var name: String
        public var isCurrent: Bool
        public var pageCount: Int
        public var id: Kind { kind }
    }
}

/// How fresh a page looks in the sidebar: pages drift towards faint as they go unused, ahead of the
/// store actually fading them, so the sidebar shows at a glance what you've been using.
public enum Freshness {
    /// Fully fresh for the first hour, then easing down to 0 at a day.
    public static func value(lastUsed: Date, now: Date) -> Double {
        let hours = now.timeIntervalSince(lastUsed) / 3600
        guard hours > 1 else { return 1 }
        let t = min((hours - 1) / 23, 1)
        return 1 - t * t * (3 - 2 * t)   // smoothstep
    }

    /// Opacity for a page row: never below 0.5, so old pages stay readable.
    public static func opacity(lastUsed: Date, now: Date, isCurrent: Bool, kept: Bool) -> Double {
        if isCurrent || kept { return 1 }
        return 0.5 + 0.5 * value(lastUsed: lastUsed, now: now)
    }
}

/// A site's own colour when its icon has none to give (or hasn't loaded): a stable hue from its host,
/// so a site keeps the same colour across launches and windows.
public enum SiteTint {
    public static func hue(for host: String) -> Double {
        var hash: UInt64 = 1469598103934665603   // FNV-1a
        for byte in host.lowercased().utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return Double(hash % 360) / 360
    }
}

/// What a click or command in the sidebar means, as the same actions the bar sends.
public enum SidebarIntent: Equatable, Sendable {
    case tapPin(SiteID)
    case tapSiteHeader(SiteID)
    case tapPage(PageID)
    case tapRail(SidebarModel.RailItem.Kind)
    case toggleFold(SiteID)
    case closePage(PageID)
    case closeSite(SiteID)
    case keep(SiteID, Bool)
    case pin(SiteID)
    case unpin(SiteID)
    case putAway(SiteID)
    case splitWithCurrent(PageID)
    case movePinToFolder(SiteID, folder: UUID?)
    case removePinFromFolder(SiteID)
    case renameFolder(UUID, String)
    case ungroupFolder(UUID)
    case moveSite(SiteID, toIndex: Int)
    case movePage(PageID, toIndex: Int)
    case newPage
    case search

    public var action: BarAction {
        switch self {
        case .tapPin(let id): .selectPin(id)
        case .tapSiteHeader(let id): .selectSite(id)
        case .tapPage(let id): .selectPage(id)
        case .tapRail(.pin(let id)): .selectPin(id)
        case .tapRail(.site(let id)): .selectSite(id)
        case .toggleFold(let id): .toggleFold(id)
        case .closePage(let id): .closePage(id)
        case .closeSite(let id): .closeSite(id)
        case .keep(let id, let kept): .setKept(id, kept)
        case .pin(let id): .pinSite(id)
        case .unpin(let id): .unpin(id)
        case .putAway(let id): .shelveSite(id)
        case .splitWithCurrent(let id): .splitWithCurrent(id)
        case .movePinToFolder(let id, let folder): .movePinToFolder(id, folder: folder)
        case .removePinFromFolder(let id): .removePinFromFolder(id)
        case .renameFolder(let id, let name): .renamePinFolder(id, name)
        case .ungroupFolder(let id): .ungroupPinFolder(id)
        case .moveSite(let id, let index): .moveSite(id, toIndex: index)
        case .movePage(let id, let index): .movePage(id, toIndex: index)
        case .newPage: .newPage
        case .search: .openCommandBar
        }
    }
}
