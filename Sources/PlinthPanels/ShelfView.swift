import SwiftUI
import AppKit
import PlinthModel

/// The shelf: everything that has faded off a bar, grouped by site, newest first.
/// The search field keeps keyboard focus the whole time; ↑/↓ move a selection through the
/// site headers and page rows, Return restores it, Escape closes.
///
/// With `semanticResults`, a search also asks for by-meaning hits about 250 ms after the last
/// keystroke (cancelled by further typing). They are listed after the keyword-filtered shelf rows
/// under a "By meaning" heading and are part of the ↑/↓ selection. Choosing one calls
/// `onOpenResult`; without it, only hits that point at a shelf page are shown, and those restore
/// through `onRestore`.
public struct ShelfView: View {
    private let entries: [ShelfEntry]
    private let accent: Color
    private let icon: (SiteKey) -> NSImage?
    private let snapshot: (PageID) -> NSImage?
    private let now: Date
    private let onRestore: (SiteID, PageID?) -> Void
    private let onRemove: (SiteID, PageID?) -> Void
    private let onDismiss: () -> Void
    private let semanticResults: ((String) async -> [SearchResult])?
    private let onOpenResult: ((SearchResult) -> Void)?
    private let onClearAll: (() -> Void)?
    private let undoCount: Int
    private let onUndoClear: (() -> Void)?

    @State private var query = ""
    /// By-meaning hits for the current query (cleared whenever the query changes).
    @State private var meaningHits: [SearchResult] = []
    /// Content height of the list while searching, so by-meaning rows can grow it.
    @State private var searchHeight: CGFloat = 0
    @State private var selection: RowID?
    @State private var hovered: RowID?
    /// Bumped on keyboard moves only, so hovering never scrolls the list.
    @State private var scrollTick = 0
    /// Height of the unfiltered list. The list keeps this height while searching, so the panel
    /// (which is anchored at its bottom edge) does not jump about as matches come and go.
    @State private var naturalHeight: CGFloat
    @Environment(\.colorScheme) private var scheme

    static let width: CGFloat = 380
    static let maxHeight: CGFloat = 480
    static let fieldHeight: CGFloat = 46
    static let rowHeight: CGFloat = 36
    static let emptyHeight: CGFloat = 148
    static var maxListHeight: CGFloat { maxHeight - fieldHeight - 1 }

    public init(entries: [ShelfEntry],
                accent: Color,
                icon: @escaping (SiteKey) -> NSImage?,
                snapshot: @escaping (PageID) -> NSImage?,
                now: Date = Date(),
                onRestore: @escaping (_ entry: SiteID, _ page: PageID?) -> Void,
                onRemove: @escaping (_ entry: SiteID, _ page: PageID?) -> Void,
                onDismiss: @escaping () -> Void,
                semanticResults: ((String) async -> [SearchResult])? = nil,
                onOpenResult: ((SearchResult) -> Void)? = nil,
                onClearAll: (() -> Void)? = nil,
                undoCount: Int = 0,
                onUndoClear: (() -> Void)? = nil) {
        self.onClearAll = onClearAll; self.undoCount = undoCount; self.onUndoClear = onUndoClear
        self.entries = entries; self.accent = accent; self.icon = icon; self.snapshot = snapshot; self.now = now
        self.onRestore = onRestore; self.onRemove = onRemove; self.onDismiss = onDismiss
        self.semanticResults = semanticResults; self.onOpenResult = onOpenResult
        let estimate = entries.reduce(CGFloat(12)) { $0 + Self.rowHeight * CGFloat(1 + $1.pages.count) + 6 }
        _naturalHeight = State(initialValue: estimate)
    }

    enum RowID: Hashable {
        case site(SiteID)
        case page(SiteID, PageID)
        /// A by-meaning hit, by `SearchResult.id`.
        case meaning(String)
    }

    struct Group: Identifiable {
        var entry: ShelfEntry
        var pages: [Page]
        var id: SiteID { entry.id }
    }

    // MARK: Filtering

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    static func tokens(_ query: String) -> [String] {
        fold(query).split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    /// Newest first. A page stays when every word of the query appears somewhere in its name,
    /// title, URL or its site's name or host.
    static func groups(_ entries: [ShelfEntry], query: String) -> [Group] {
        let words = tokens(query)
        let sorted = entries.enumerated().sorted {
            $0.element.shelvedAt != $1.element.shelvedAt ? $0.element.shelvedAt > $1.element.shelvedAt : $0.offset < $1.offset
        }.map(\.element)
        return sorted.compactMap { entry in
            guard !entry.pages.isEmpty else { return nil }
            guard !words.isEmpty else { return Group(entry: entry, pages: entry.pages) }
            let site = fold(entry.name + " " + entry.key.host)
            let pages = entry.pages.filter { page in
                let haystack = site + " " + fold([page.name, page.customName ?? "", page.rawTitle, page.url.absoluteString].joined(separator: " "))
                return words.allSatisfy { haystack.contains($0) }
            }
            return pages.isEmpty ? nil : Group(entry: entry, pages: pages)
        }
    }

    static func flatRows(_ groups: [Group], meaning: [SearchResult] = []) -> [RowID] {
        groups.flatMap { group in [RowID.site(group.id)] + group.pages.map { RowID.page(group.id, $0.id) } }
            + meaning.map { RowID.meaning($0.id) }
    }

    static let maxMeaningRows = 5

    /// By-meaning hits worth listing: deduplicated, minus shelf pages the keyword filter already
    /// shows, and (without `onOpenResult`) only hits that point at a shelf page.
    static func meaningRows(_ hits: [SearchResult], groups: [Group], canOpenAny: Bool) -> [SearchResult] {
        let shown = Set(groups.flatMap { group in group.pages.map { "\(group.id.raw)/\($0.id.raw)" } })
        var seen = Set<String>()
        var rows: [SearchResult] = []
        for hit in hits where !seen.contains(hit.id) {
            if case .shelf(let entry, let page) = hit.target {
                if shown.contains("\(entry.raw)/\(page.raw)") { continue }
            } else if !canOpenAny {
                continue
            }
            seen.insert(hit.id)
            rows.append(hit)
            if rows.count == maxMeaningRows { break }
        }
        return rows
    }

    // MARK: Body

    public var body: some View {
        let palette = PanelPalette(scheme)
        let groups = Self.groups(entries, query: query)
        let searching = !Self.tokens(query).isEmpty
        let meaning = searching ? Self.meaningRows(meaningHits, groups: groups, canOpenAny: onOpenResult != nil) : []
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(palette.secondary)
                    .accessibilityHidden(true)
                PanelTextField(text: $query,
                               placeholder: "Search the shelf",
                               fontSize: 13,
                               textColor: palette.primary,
                               placeholderColor: palette.tertiary,
                               accent: accent,
                               label: "Search the shelf",
                               focusOnAppear: true,
                               selectAllOnFocus: true,
                               onKey: { handle($0, groups: groups, meaning: meaning) })
                if let onClearAll, !searching, !entries.allSatisfy({ $0.pages.isEmpty }) {
                    PanelPillButton(title: "Clear all", style: .quiet, height: 24, palette: palette, action: onClearAll)
                        .help("Remove every page from the shelf. You can undo this.")
                        .accessibilityHint("Removes every page from the shelf. You can undo it.")
                }
            }
            .padding(.horizontal, 14)
            .frame(height: Self.fieldHeight)
            .background(palette.inputFill)
            Rectangle().fill(palette.divider).frame(height: 1)

            if entries.allSatisfy({ $0.pages.isEmpty }) {
                if undoCount > 0, let onUndoClear {
                    VStack(spacing: 12) {
                        message(symbol: "tray", title: "Shelf cleared.",
                                detail: undoCount == 1 ? "1 page was removed." : "\(undoCount) pages were removed.", palette: palette)
                        PanelPillButton(title: "Undo", systemImage: "arrow.uturn.backward", style: .accent(accent),
                                        palette: palette, action: onUndoClear)
                            .accessibilityHint("Puts the pages back on the shelf")
                    }
                    .padding(.bottom, 16)
                    .frame(height: Self.emptyHeight + 24)
                } else {
                    message(symbol: "tray", title: "Nothing put away.", detail: "Sites you stop using land here.", palette: palette)
                        .frame(height: Self.emptyHeight)
                }
            } else if groups.isEmpty, meaning.isEmpty {
                message(symbol: "magnifyingglass", title: "No matches.", detail: "Nothing on the shelf matches “\(query.trimmingCharacters(in: .whitespaces))”.", palette: palette)
                    .frame(height: max(min(naturalHeight, Self.maxListHeight), Self.emptyHeight))
            } else {
                list(groups, meaning: meaning, searching: searching, palette: palette)
            }
        }
        .frame(width: Self.width)
        .panelChrome()
        .background(OutsideClickMonitor(onOutside: onDismiss))
        .onChange(of: query) { selection = nil; hovered = nil; meaningHits = [] }
        .task(id: query.trimmingCharacters(in: .whitespacesAndNewlines)) { await runSemanticSearch() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Shelf")
    }

    private func list(_ groups: [Group], meaning: [SearchResult], searching: Bool, palette: PanelPalette) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(groups) { group in
                        header(group, palette: palette).id(RowID.site(group.id))
                        let thumbnails = group.pages.contains { snapshot($0.id) != nil }
                        ForEach(group.pages) { page in
                            pageRow(page, in: group, thumbnails: thumbnails, palette: palette)
                                .id(RowID.page(group.id, page.id))
                        }
                        Color.clear.frame(height: 6)
                    }
                    if !meaning.isEmpty {
                        Text("By meaning")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(palette.tertiary)
                            .padding(.horizontal, 10)
                            .padding(.top, groups.isEmpty ? 4 : 2)
                            .padding(.bottom, 4)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(meaning) { hit in
                            meaningRow(hit, palette: palette).id(RowID.meaning(hit.id))
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    if !searching, height > 0 { naturalHeight = height }
                    if searching { searchHeight = height }
                }
            }
            .frame(height: min(max(naturalHeight, searching ? searchHeight : 0, Self.rowHeight * 2), Self.maxListHeight))
            .onChange(of: scrollTick) {
                if let selection { proxy.scrollTo(selection) }
            }
        }
    }

    private func message(symbol: String, title: String, detail: String, palette: PanelPalette) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(palette.tertiary)
                .padding(.bottom, 4)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(palette.primary)
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(palette.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    // MARK: Rows

    private func header(_ group: Group, palette: PanelPalette) -> some View {
        let id = RowID.site(group.id)
        let selected = selection == id
        let active = selected || hovered == id
        let strong = selected ? palette.onAccent : palette.primary
        let soft = selected ? palette.onAccent.opacity(0.85) : palette.tertiary
        let whole = group.pages.count == group.entry.pages.count
        let when = Self.relative(group.entry.shelvedAt, now: now)
        let count = group.entry.pages.count
        return Button {
            restore(id, groups: [group])
        } label: {
            HStack(spacing: 8) {
                SiteIconView(key: group.entry.key, name: group.entry.name, image: icon(group.entry.key), size: 16)
                Text(group.entry.name.isEmpty ? group.entry.key.host : group.entry.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(strong)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(when)
                    .font(.system(size: 12))
                    .foregroundStyle(soft)
                    .lineLimit(1)
                    .fixedSize()
                    .opacity(active ? 0 : 1)
            }
            .padding(.horizontal, 10)
            .frame(height: Self.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowBackground(selected: selected, hovered: hovered == id, palette: palette))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(whole ? "Restore every page from this site" : "Restore the matching pages")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(group.entry.name), \(count) \(count == 1 ? "page" : "pages"), put away \(when.lowercased())")
        .accessibilityHint("Restores the whole site")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected, .isHeader] : [.isButton, .isHeader])
        .accessibilityAction(named: "Remove from shelf") { onRemove(group.id, nil) }
        .overlay(alignment: .trailing) {
            if active {
                removeButton(label: "Remove \(group.entry.name) from the shelf", onAccent: selected, palette: palette) {
                    onRemove(group.id, nil)
                }
            }
        }
        .onHover { inside in hover(id, inside) }
    }

    private func pageRow(_ page: Page, in group: Group, thumbnails: Bool, palette: PanelPalette) -> some View {
        let id = RowID.page(group.id, page.id)
        let selected = selection == id
        let active = selected || hovered == id
        let strong = selected ? palette.onAccent : palette.primary
        let soft = selected ? palette.onAccent.opacity(0.85) : palette.secondary
        let name = page.customName ?? page.name
        let location = Self.location(page.url)
        return Button {
            onRestore(group.id, page.id)
        } label: {
            HStack(spacing: 8) {
                if thumbnails {
                    thumbnail(snapshot(page.id), palette: palette)
                } else {
                    Color.clear.frame(width: 16, height: 1)
                }
                Text(name.isEmpty ? location : name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(strong)
                    .lineLimit(1)
                    .layoutPriority(1)
                Text(location)
                    .font(.system(size: 12))
                    .foregroundStyle(soft)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: active ? 30 : 0)
            }
            .padding(.horizontal, 10)
            .frame(height: Self.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowBackground(selected: selected, hovered: hovered == id, palette: palette))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name), \(location)")
        .accessibilityHint("Restores this page")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: "Remove from shelf") { onRemove(group.id, page.id) }
        .overlay(alignment: .trailing) {
            if active {
                removeButton(label: "Remove \(name) from the shelf", onAccent: selected, palette: palette) {
                    onRemove(group.id, page.id)
                }
            }
        }
        .onHover { inside in hover(id, inside) }
    }

    private func meaningRow(_ hit: SearchResult, palette: PanelPalette) -> some View {
        let id = RowID.meaning(hit.id)
        let selected = selection == id
        let strong = selected ? palette.onAccent : palette.primary
        let soft = selected ? palette.onAccent.opacity(0.85) : palette.secondary
        let title = hit.title.isEmpty ? hit.subtitle : hit.title
        return Button {
            open(hit)
        } label: {
            HStack(spacing: 8) {
                SiteIconView(key: hit.key, name: hit.key.host, image: icon(hit.key), size: 16)
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(strong)
                    .lineLimit(1)
                    .layoutPriority(1)
                if !hit.title.isEmpty, !hit.subtitle.isEmpty {
                    Text(hit.subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(soft)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: Self.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowBackground(selected: selected, hovered: hovered == id, palette: palette))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([title, hit.subtitle, "by meaning"].filter { !$0.isEmpty }.joined(separator: ", "))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .onHover { inside in hover(id, inside) }
    }

    private func open(_ hit: SearchResult) {
        if let onOpenResult {
            onOpenResult(hit)
        } else if case .shelf(let entry, let page) = hit.target {
            onRestore(entry, page)
        }
    }

    /// Debounced by-meaning search; `.task(id:)` cancels it when the query changes.
    private func runSemanticSearch() async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let semanticResults, !text.isEmpty else { return }
        do { try await Task.sleep(for: CommandBarView.semanticDelay) } catch { return }
        let hits = await semanticResults(text)
        guard !Task.isCancelled, text == query.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        meaningHits = hits
    }

    private func rowBackground(selected: Bool, hovered: Bool, palette: PanelPalette) -> some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(selected ? accent : (hovered ? palette.hover : Color.clear))
    }

    private func thumbnail(_ image: NSImage?, palette: PanelPalette) -> some View {
        let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
        return ZStack {
            shape.fill(palette.fill)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 38, height: 26, alignment: .top)
            }
        }
        .frame(width: 38, height: 26)
        .clipShape(shape)
        .overlay(shape.strokeBorder(palette.border, lineWidth: 1))
        .accessibilityHidden(true)
    }

    private func removeButton(label: String, onAccent: Bool, palette: PanelPalette, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(onAccent ? palette.onAccent : palette.secondary)
                .frame(width: 22, height: 22)
                .background(Circle().fill(onAccent ? palette.onAccent.opacity(0.2) : palette.fill))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.trailing, 7)
        .help("Remove from the shelf")
        .accessibilityLabel(label)
    }

    private func hover(_ id: RowID, _ inside: Bool) {
        if inside { hovered = id } else if hovered == id { hovered = nil }
    }

    // MARK: Keys

    private func handle(_ key: PanelKey, groups: [Group], meaning: [SearchResult]) -> Bool {
        let rows = Self.flatRows(groups, meaning: meaning)
        let current = selection.flatMap { rows.firstIndex(of: $0) }
        switch key {
        case .down:
            guard !rows.isEmpty else { return false }
            select(rows[min((current ?? -1) + 1, rows.count - 1)], groups: groups, meaning: meaning)
            return true
        case .up:
            guard !rows.isEmpty else { return false }
            // Up from the first row hands the "selection" back to the search field.
            if let current, current > 0 { select(rows[current - 1], groups: groups, meaning: meaning) } else { selection = nil }
            return true
        case .submit:
            if let current {
                if case .meaning(let id) = rows[current] {
                    if let hit = meaning.first(where: { $0.id == id }) { open(hit) }
                } else {
                    restore(rows[current], groups: groups)
                }
            } else if !Self.tokens(query).isEmpty {
                // Typed a search and pressed Return: take the best (first) match.
                if let first = groups.first, let page = first.pages.first {
                    onRestore(first.id, page.id)
                } else if let hit = meaning.first {
                    open(hit)
                }
            }
            return true
        case .escape:
            onDismiss()
            return true
        }
    }

    private func select(_ id: RowID, groups: [Group], meaning: [SearchResult]) {
        guard selection != id else { return }
        selection = id
        scrollTick += 1
        AccessibilityNotification.Announcement(spoken(id, groups: groups, meaning: meaning)).post()
    }

    private func spoken(_ id: RowID, groups: [Group], meaning: [SearchResult]) -> String {
        switch id {
        case .meaning(let hit):
            return meaning.first { $0.id == hit }.map { "\($0.title), by meaning" } ?? ""
        case .site(let site):
            return groups.first { $0.id == site }.map { "\($0.entry.name), whole site" } ?? ""
        case .page(let site, let page):
            let found = groups.first { $0.id == site }?.pages.first { $0.id == page }
            return found.map { $0.customName ?? $0.name } ?? ""
        }
    }

    /// A header restores the whole site, unless a search has narrowed it, in which case it
    /// restores just the pages still showing.
    private func restore(_ id: RowID, groups: [Group]) {
        switch id {
        case .page(let site, let page):
            onRestore(site, page)
        case .meaning:
            break
        case .site(let site):
            guard let group = groups.first(where: { $0.id == site }) else { return }
            if group.pages.count == group.entry.pages.count {
                onRestore(site, nil)
            } else {
                for page in group.pages { onRestore(site, page.id) }
            }
        }
    }

    // MARK: Text helpers

    static func location(_ url: URL) -> String {
        guard var host = url.host(percentEncoded: false), !host.isEmpty else {
            return url.scheme == "file" ? url.lastPathComponent : url.absoluteString
        }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        var path = url.path(percentEncoded: false)
        if path.hasSuffix("/") { path.removeLast() }
        return host + path
    }

    /// "Just now", "5 minutes ago", "2 hours ago", "Yesterday", "3 days ago", "Last week", then a date.
    static func relative(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "Just now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return minutes == 1 ? "1 minute ago" : "\(minutes) minutes ago" }
        let hours = minutes / 60
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        // Late last night still reads better as hours when it was only a few hours ago.
        if days == 0 || (days == 1 && hours < 6) { return hours == 1 ? "1 hour ago" : "\(hours) hours ago" }
        if days == 1 { return "Yesterday" }
        if days < 7 { return "\(days) days ago" }
        if days < 14 { return "Last week" }
        if days < 35 { return "\(days / 7) weeks ago" }
        return date.formatted(.dateTime.day().month(.abbreviated).year())
    }
}
