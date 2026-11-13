import SwiftUI
import AppKit
import PlinthModel

/// The history panel: everything you visited, newest first, grouped by day.
///
/// A search field filters by title, site or address; chips narrow to Today, Yesterday, the last 7
/// or 30 days, or everything; the site menu narrows to one website. Back-to-back visits to the
/// same page are merged into one row with a count. ↑/↓ move through the rows, Return opens one in
/// a new page, Escape closes.
///
/// Filtering runs off the main thread: `prepare` is awaited once (the app builds a `HistoryIndex`
/// there), and each change of filter asks the returned closure for a `HistoryPage` on a background
/// task, after a short pause for further typing, so a 50,000-entry history stays responsive.
public struct HistoryView: View {
    public typealias Query = @Sendable (HistoryFilter) -> HistoryPage

    private let accent: Color
    private let icon: (SiteKey) -> NSImage?
    private let prepare: () async -> Query
    private let onOpen: (HistoryRow) -> Void
    private let onDismiss: () -> Void

    @State private var text = ""
    @State private var range: HistoryRange = .all
    @State private var site: String?
    @State private var query: Query?
    @State private var page = HistoryPage.empty
    @State private var hasLoaded = false
    @State private var selection: UUID?
    @State private var hovered: UUID?
    @State private var scrollTick = 0
    @Environment(\.colorScheme) private var scheme

    static let width: CGFloat = 460
    static let listHeight: CGFloat = 380
    static let fieldHeight: CGFloat = 46
    static let rowHeight: CGFloat = 34
    static let filterDelay: Duration = .milliseconds(90)

    public init(accent: Color,
                icon: @escaping (SiteKey) -> NSImage?,
                prepare: @escaping () async -> Query,
                onOpen: @escaping (HistoryRow) -> Void,
                onDismiss: @escaping () -> Void) {
        self.accent = accent; self.icon = icon; self.prepare = prepare; self.onOpen = onOpen; self.onDismiss = onDismiss
    }

    private var filter: HistoryFilter {
        HistoryFilter(text: text.trimmingCharacters(in: .whitespacesAndNewlines), range: range, site: site)
    }

    private var flatRows: [HistoryRow] { page.days.flatMap(\.rows) }

    // MARK: Body

    public var body: some View {
        let palette = PanelPalette(scheme)
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(palette.secondary)
                    .accessibilityHidden(true)
                PanelTextField(text: $text,
                               placeholder: "Search history",
                               fontSize: 13,
                               textColor: palette.primary,
                               placeholderColor: palette.tertiary,
                               accent: accent,
                               label: "Search history",
                               focusOnAppear: true,
                               selectAllOnFocus: true,
                               onKey: handle)
            }
            .padding(.horizontal, 14)
            .frame(height: Self.fieldHeight)
            .background(palette.inputFill)
            Rectangle().fill(palette.divider).frame(height: 1)

            filterBar(palette: palette)
            Rectangle().fill(palette.divider).frame(height: 1)

            Group {
                if !hasLoaded {
                    Color.clear
                } else if page.days.isEmpty {
                    message(palette: palette)
                } else {
                    list(palette: palette)
                }
            }
            .frame(height: Self.listHeight)

            Rectangle().fill(palette.divider).frame(height: 1)
            footer(palette: palette)
        }
        .frame(width: Self.width)
        .panelChrome()
        .background(OutsideClickMonitor(onOutside: onDismiss))
        .task {
            let ready = await prepare()
            query = ready
            await run(ready, immediately: true)
        }
        .task(id: filter) {
            guard let query else { return }
            await run(query, immediately: false)
        }
        .onChange(of: filter) { selection = nil; hovered = nil }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("History")
    }

    // MARK: Pieces

    private func filterBar(palette: PanelPalette) -> some View {
        HStack(spacing: 4) {
            ForEach(HistoryRange.allCases, id: \.self) { option in
                chip(option.title, selected: range == option, palette: palette) { range = option }
            }
            Spacer(minLength: 6)
            siteMenu(palette: palette)
        }
        .padding(.horizontal, 8)
        .frame(height: 38)
    }

    private func chip(_ title: String, selected: Bool, palette: PanelPalette, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(selected ? palette.onAccent : palette.secondary)
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background(Capsule().fill(selected ? accent : Color.clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private func siteMenu(palette: PanelPalette) -> some View {
        Menu {
            Button("All sites") { site = nil }
            if !page.sites.isEmpty { Divider() }
            ForEach(page.sites) { entry in
                Button("\(entry.host)  (\(entry.count))") { site = entry.host }
            }
        } label: {
            HStack(spacing: 4) {
                Text(site ?? "All sites")
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .frame(maxWidth: 130, alignment: .trailing)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(site == nil ? palette.secondary : accent)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(Capsule().fill(site == nil ? Color.clear : accent.opacity(0.14)))
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Site")
        .accessibilityValue(site ?? "All sites")
    }

    private func list(palette: PanelPalette) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
                    ForEach(page.days) { day in
                        Text(Self.dayTitle(day.day))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(palette.tertiary)
                            .padding(.horizontal, 10)
                            .padding(.top, 8)
                            .padding(.bottom, 4)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(day.rows) { row in
                            rowView(row, palette: palette).id(row.id)
                        }
                    }
                }
                .padding(6)
            }
            .onChange(of: scrollTick) {
                if let selection { proxy.scrollTo(selection) }
            }
        }
    }

    private func rowView(_ row: HistoryRow, palette: PanelPalette) -> some View {
        let selected = selection == row.id
        let strong = selected ? palette.onAccent : palette.primary
        let soft = selected ? palette.onAccent.opacity(0.85) : palette.secondary
        let location = Self.location(row.url)
        return Button {
            onOpen(row)
        } label: {
            HStack(spacing: 8) {
                SiteIconView(key: row.key, name: row.key.host, image: icon(row.key), size: 16)
                Text(row.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(strong)
                    .lineLimit(1)
                    .layoutPriority(1)
                Text(location)
                    .font(.system(size: 12))
                    .foregroundStyle(soft)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                if row.visits > 1 {
                    Text("×\(row.visits)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(selected ? palette.onAccent : palette.secondary)
                        .padding(.horizontal, 6)
                        .frame(height: 18)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(selected ? palette.onAccent.opacity(0.2) : palette.fill))
                        .fixedSize()
                }
                Text(row.visitedAt.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 12))
                    .foregroundStyle(soft)
                    .monospacedDigit()
                    .fixedSize()
            }
            .padding(.horizontal, 10)
            .frame(height: Self.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selected ? accent : (hovered == row.id ? palette.hover : Color.clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { hovered = row.id } else if hovered == row.id { hovered = nil }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.title), \(location), \(row.visitedAt.formatted(date: .abbreviated, time: .shortened))"
                            + (row.visits > 1 ? ", \(row.visits) visits in a row" : ""))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private func message(palette: PanelPalette) -> some View {
        let filtering = !filter.text.isEmpty || range != .all || site != nil
        return VStack(spacing: 6) {
            Image(systemName: filtering ? "magnifyingglass" : "clock")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(palette.tertiary)
                .padding(.bottom, 4)
                .accessibilityHidden(true)
            Text(filtering ? "No matches." : "No history yet.")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(palette.primary)
            Text(filtering ? "Try a wider range, another site or different words." : "Pages you visit appear here.")
                .font(.system(size: 12))
                .foregroundStyle(palette.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func footer(palette: PanelPalette) -> some View {
        let total = page.totalRows
        let shown = page.shownRows
        let label: String
        if !hasLoaded { label = "" }
        else if total == 0 { label = "Nothing to show" }
        else if shown < total { label = "Showing the newest \(shown.formatted()) of \(total.formatted()). Narrow the search to see more." }
        else { label = "\(total.formatted()) \(total == 1 ? "page" : "pages")" }
        return Text(label)
            .font(.system(size: 11))
            .foregroundStyle(palette.tertiary)
            .lineLimit(1)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 28)
    }

    // MARK: Work

    /// Asks `query` for the current filter on a background task. Typing waits `filterDelay`;
    /// `.task(id:)` cancels this when the filter changes again, so only the last one lands.
    private func run(_ query: @escaping Query, immediately: Bool) async {
        if !immediately {
            do { try await Task.sleep(for: Self.filterDelay) } catch { return }
        }
        let wanted = filter
        let result = await Task.detached(priority: .userInitiated) { query(wanted) }.value
        guard !Task.isCancelled, wanted == filter else { return }
        page = result
        hasLoaded = true
    }

    // MARK: Keys

    private func handle(_ key: PanelKey) -> Bool {
        let rows = flatRows
        let current = selection.flatMap { id in rows.firstIndex { $0.id == id } }
        switch key {
        case .down:
            guard !rows.isEmpty else { return false }
            move(to: rows[min((current ?? -1) + 1, rows.count - 1)])
            return true
        case .up:
            guard !rows.isEmpty else { return false }
            if let current, current > 0 { move(to: rows[current - 1]) } else { selection = nil }
            return true
        case .submit:
            if let current { onOpen(rows[current]) } else if let first = rows.first, !filter.text.isEmpty { onOpen(first) }
            return true
        case .escape:
            onDismiss()
            return true
        }
    }

    private func move(to row: HistoryRow) {
        guard selection != row.id else { return }
        selection = row.id
        scrollTick += 1
        AccessibilityNotification.Announcement("\(row.title), \(Self.location(row.url))").post()
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

    /// "Today", "Yesterday", then "Monday, 10 November" (or with the year when it is not this year).
    static func dayTitle(_ day: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(day, inSameDayAs: yesterday) { return "Yesterday" }
        if calendar.isDate(day, equalTo: now, toGranularity: .year) {
            return day.formatted(.dateTime.weekday(.wide).day().month(.wide))
        }
        return day.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
    }
}
