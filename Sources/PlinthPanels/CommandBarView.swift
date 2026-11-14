import SwiftUI
import AppKit
import PlinthModel

public enum CommandSubmission: Equatable {
    /// Raw text; the shell resolves URL vs search. `newPage` = open in a new page rather than the current one.
    case text(String, newPage: Bool)
    case result(SearchResult)
}

/// The command bar panel. Results stack upward from the text field, so the field stays put just
/// above the bottom bar: row 0 (the literal "Go to" / "Search for" action) is the row nearest the
/// field, better matches sit closer to it, and ↑ moves away from the field, which is visually up.
/// The selected row is filled with the accent; hover is a separate, fainter Haze wash.
///
/// With `semanticResults`, typing also runs a by-meaning search about 250 ms after the last
/// keystroke (cancelled by further typing). Its hits, and any `byMeaning` rows the synchronous
/// `results` returned, are listed after the keyword results under a small "By meaning" heading
/// (visually above them), and are selected and submitted like any other result.
public struct CommandBarView: View {
    private let initialText: String
    private let opensNewPage: Bool
    private let accent: Color
    private let results: (String) -> [SearchResult]
    private let semanticResults: ((String) async -> [SearchResult])?
    private let searchSuggestions: ((String) async -> [String])?
    private let icon: (SiteKey) -> NSImage?
    private let onSubmit: (CommandSubmission) -> Void
    private let onDismiss: () -> Void

    @State private var text: String
    @State private var rows: [Row] = []
    /// Index in `rows` of the first by-meaning row; `rows.count` when there are none.
    @State private var meaningStart = 0
    /// Index in `rows` of the first bookmark row; `meaningStart` when there are none.
    @State private var bookmarkStart = 0
    /// The latest by-meaning hits for the current query (cleared whenever the query changes).
    @State private var semanticHits: [SearchResult] = []
    /// The search engine's suggestions for the current query (cleared whenever the query changes).
    @State private var engineSuggestions: [String] = []
    /// False until the text first changes, so the pre-filled address never triggers a by-meaning search.
    @State private var hasEdited = false
    /// Index into `rows`; 0 is nearest the field.
    @State private var selection: Int?
    @State private var showsRecents = false
    /// With nothing typed: rows `0..<suggestedEnd` are suggested pages, the rest (up to `bookmarkStart`) are shelved pages.
    @State private var suggestedEnd = 0
    @State private var hovered: Int?
    @Environment(\.colorScheme) private var scheme

    static let maxRows = 8
    /// Shelved pages listed when nothing is typed, at most; suggested pages take the rest of `maxRows` first.
    static let maxShelfRows = 4
    static let maxMeaningRows = 4
    static let maxBookmarkRows = 3
    static let maxSuggestionRows = 3
    static let suggestionDelay: Duration = .milliseconds(120)
    static let semanticDelay: Duration = .milliseconds(250)
    static let width: CGFloat = 640

    public init(initialText: String,
                opensNewPage: Bool,
                accent: Color,
                results: @escaping (String) -> [SearchResult],
                semanticResults: ((String) async -> [SearchResult])? = nil,
                searchSuggestions: ((String) async -> [String])? = nil,
                icon: @escaping (SiteKey) -> NSImage?,
                onSubmit: @escaping (CommandSubmission) -> Void,
                onDismiss: @escaping () -> Void) {
        self.initialText = initialText; self.opensNewPage = opensNewPage; self.accent = accent
        self.results = results; self.semanticResults = semanticResults; self.searchSuggestions = searchSuggestions; self.icon = icon; self.onSubmit = onSubmit; self.onDismiss = onDismiss
        _text = State(initialValue: initialText)
    }

    enum Row: Equatable {
        case literal(String, isURL: Bool)
        /// A phrase the search engine suggests for what is typed; choosing it searches for it.
        case suggestion(String)
        case result(SearchResult)
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    public var body: some View {
        let palette = PanelPalette(scheme)
        VStack(spacing: 0) {
            if !rows.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    if showsRecents {
                        heading("Recently put away", palette: palette)
                    }
                    // Reversed: index 0 is drawn last, right above the field. By-meaning rows sit
                    // at the top under their own heading.
                    if meaningStart < rows.count {
                        heading("By meaning", palette: palette)
                        ForEach(Array(rows.enumerated().dropFirst(meaningStart)).reversed(), id: \.offset) { index, row in
                            rowView(row, index: index, palette: palette)
                        }
                        if meaningStart > 0 { divider(palette: palette) }
                    }
                    if bookmarkStart < meaningStart {
                        heading("Bookmarks", palette: palette)
                        ForEach(Array(rows.enumerated().prefix(meaningStart).dropFirst(bookmarkStart)).reversed(), id: \.offset) { index, row in
                            rowView(row, index: index, palette: palette)
                        }
                        if bookmarkStart > 0 { divider(palette: palette) }
                    }
                    // Nothing typed: shelved pages above, then the suggested pages under their own heading.
                    ForEach(Array(rows.enumerated().prefix(bookmarkStart).dropFirst(suggestedEnd)).reversed(), id: \.offset) { index, row in
                        rowView(row, index: index, palette: palette)
                    }
                    if suggestedEnd > 0 {
                        heading("Suggested", palette: palette)
                        ForEach(Array(rows.enumerated().prefix(suggestedEnd)).reversed(), id: \.offset) { index, row in
                            rowView(row, index: index, palette: palette)
                        }
                    }
                }
                .padding(6)
                Rectangle().fill(palette.divider).frame(height: 1)
            }
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(palette.secondary)
                    .accessibilityHidden(true)
                PanelTextField(text: $text,
                               placeholder: "Search or enter address",
                               fontSize: 15,
                               textColor: palette.primary,
                               placeholderColor: palette.tertiary,
                               accent: accent,
                               label: opensNewPage ? "Search or enter address for a new page" : "Search or enter address",
                               focusOnAppear: true,
                               selectAllOnFocus: true,
                               onKey: handle)
                if opensNewPage {
                    Tag(text: "New page", palette: palette, onSelection: false)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 50)
            .background(palette.inputFill)
        }
        .frame(maxWidth: Self.width)
        .panelChrome()
        .background(OutsideClickMonitor(onOutside: onDismiss))
        .onAppear {
            // Opened on the current page's address: keep the panel quiet until the user types.
            if trimmed.isEmpty { refresh() }
        }
        .onChange(of: text) { hasEdited = true; refresh() }
        .task(id: trimmed) { await runSemanticSearch(for: trimmed) }
        .task(id: trimmed) { await runEngineSuggestions(for: trimmed) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Command bar")
    }

    // MARK: Rows

    private func divider(palette: PanelPalette) -> some View {
        Rectangle().fill(palette.divider).frame(height: 1)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
    }

    private func heading(_ title: String, palette: PanelPalette) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(palette.tertiary)
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private func rowView(_ row: Row, index: Int, palette: PanelPalette) -> some View {
        let selected = selection == index
        let strong = selected ? palette.onAccent : palette.primary
        let soft = selected ? palette.onAccent.opacity(0.85) : palette.secondary
        Button {
            let flags = NSEvent.modifierFlags
            submit(row, newPage: flags.contains(.option) || flags.contains(.command))
        } label: {
            HStack(spacing: 10) {
                switch row {
                case .literal(let value, let isURL):
                    Image(systemName: isURL ? "globe" : "magnifyingglass")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(soft)
                        .frame(width: 16, height: 16)
                        .accessibilityHidden(true)
                    HStack(spacing: 0) {
                        Text(isURL ? "Go to " : "Search for ")
                            .foregroundStyle(soft)
                            .fixedSize()
                        Text(isURL ? Self.displayAddress(value) : value)
                            .fontWeight(.medium)
                            .foregroundStyle(strong)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .font(.system(size: 13))
                    Spacer(minLength: 8)
                    if selected {
                        Text("↩")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(soft)
                            .accessibilityHidden(true)
                    }
                case .suggestion(let phrase):
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(soft)
                        .frame(width: 16, height: 16)
                        .accessibilityHidden(true)
                    Self.suggestionText(phrase, typed: trimmed, strong: strong, soft: soft)
                        .font(.system(size: 13))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 8)
                    if selected {
                        Text("↩")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(soft)
                            .accessibilityHidden(true)
                    }
                case .result(let result):
                    SiteIconView(key: result.key, name: result.key.host,
                                 image: icon(result.key), size: 16)
                    Text(result.title.isEmpty ? result.subtitle : result.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(strong)
                        .lineLimit(1)
                        .layoutPriority(1)
                    if !result.title.isEmpty, !result.subtitle.isEmpty {
                        Text(result.subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(soft)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                    Tag(text: result.isTopHit ? "Top hit" : Self.tag(for: result), palette: palette, onSelection: selected,
                        warm: Self.isShelf(result.target))
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 36)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? accent : (hovered == index ? palette.hover : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Hover is only a Haze wash; the keyboard selection stays where it is until a click.
        .onHover { inside in
            if inside { hovered = index } else if hovered == index { hovered = nil }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spokenLabel(for: row))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private struct Tag: View {
        var text: String
        var palette: PanelPalette
        var onSelection: Bool
        var warm = false
        var body: some View {
            let foreground = onSelection ? palette.onAccent : (warm ? palette.warmText : palette.secondary)
            let background = onSelection ? palette.onAccent.opacity(0.2) : (warm ? palette.warmFill : palette.fill)
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(foreground)
                .padding(.horizontal, 7)
                .frame(height: 20)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(background))
                .fixedSize()
        }
    }

    // MARK: State

    private func refresh() {
        semanticHits = []
        engineSuggestions = []
        rebuild(resetSelection: true)
    }

    /// Recomputes `rows` from the query, the synchronous results and the latest by-meaning hits.
    private func rebuild(resetSelection: Bool) {
        let query = trimmed
        hovered = resetSelection ? nil : hovered
        let found = results(query)
        let keyword = found.filter { !$0.byMeaning && !$0.isBookmark }
        // Bookmarks get their own heading, between the keyword results and "By meaning".
        let bookmarkRows = found.filter { !$0.byMeaning && $0.isBookmark }.prefix(Self.maxBookmarkRows).map(Row.result)
        var seen = Set(found.filter { !$0.byMeaning }.map(\.id))
        var meaning: [SearchResult] = []
        for hit in found.filter(\.byMeaning) + semanticHits where !seen.contains(hit.id) {
            seen.insert(hit.id)
            meaning.append(hit)
        }
        let meaningRows = meaning.prefix(Self.maxMeaningRows).map(Row.result)
        if query.isEmpty {
            // Suggested pages (history) first, then what was put away, within `maxRows` in all.
            let suggested = keyword.filter { !Self.isShelf($0.target) }.prefix(Self.maxRows)
            let shelved = keyword.filter { Self.isShelf($0.target) }.prefix(min(Self.maxShelfRows, Self.maxRows - suggested.count))
            let recent = (suggested + shelved).map(Row.result)
            rows = recent + bookmarkRows + meaningRows
            suggestedEnd = suggested.count
            bookmarkStart = recent.count
            meaningStart = recent.count + bookmarkRows.count
            showsRecents = !shelved.isEmpty
            if resetSelection { selection = nil }
        } else {
            // A confident top hit leads (and is what Return does); the literal "Go to" / "Search
            // for" row stays right behind it.
            let literal = Row.literal(query, isURL: Self.looksLikeURL(query))
            // The engine's suggestions come right after the literal row, before history.
            let suggested = engineSuggestions.prefix(Self.maxSuggestionRows).map { Row.suggestion($0) }
            let head: [Row]
            if let top = keyword.first, top.isTopHit {
                let others = keyword.dropFirst().map(Row.result)
                head = Array(([Row.result(top), literal] + suggested + others).prefix(Self.maxRows))
            } else {
                head = Array(([literal] + suggested + keyword.map(Row.result)).prefix(Self.maxRows))
            }
            rows = head + bookmarkRows + meaningRows
            bookmarkStart = head.count
            meaningStart = head.count + bookmarkRows.count
            showsRecents = false
            suggestedEnd = 0
            if resetSelection { selection = 0 }
        }
        if let current = selection, !rows.indices.contains(current) { selection = rows.isEmpty ? nil : rows.count - 1 }
    }

    /// Debounced: waits a moment, then asks the search engine for suggestions.
    private func runEngineSuggestions(for query: String) async {
        guard let searchSuggestions, hasEdited, !query.isEmpty else { return }
        do { try await Task.sleep(for: Self.suggestionDelay) } catch { return }
        let found = await searchSuggestions(query)
        guard !Task.isCancelled, query == trimmed, !found.isEmpty else { return }
        engineSuggestions = found
        rebuild(resetSelection: false)
    }

    /// Debounced: waits `semanticDelay`, then asks for by-meaning hits. `.task(id:)` cancels this
    /// as soon as the query changes, and late answers for an old query are dropped.
    private func runSemanticSearch(for query: String) async {
        guard let semanticResults, hasEdited, !query.isEmpty else { return }
        do { try await Task.sleep(for: Self.semanticDelay) } catch { return }
        let hits = await semanticResults(query)
        guard !Task.isCancelled, query == trimmed else { return }
        semanticHits = hits.map { hit in
            var hit = hit
            hit.byMeaning = true
            return hit
        }
        rebuild(resetSelection: false)
    }

    private func handle(_ key: PanelKey) -> Bool {
        switch key {
        case .up:
            guard !rows.isEmpty else { return false }
            move(to: min((selection ?? -1) + 1, rows.count - 1))
            return true
        case .down:
            guard !rows.isEmpty else { return false }
            if let current = selection {
                // The literal action is the floor while there is text; recents can be deselected.
                if current > 0 { move(to: current - 1) } else if showsRecents || suggestedEnd > 0 { selection = nil }
            }
            return true
        case .submit(let option, let command, _):
            let newPage = option || command
            if let index = selection, rows.indices.contains(index) {
                submit(rows[index], newPage: newPage)
            } else if !trimmed.isEmpty {
                onSubmit(.text(trimmed, newPage: opensNewPage || newPage))
            }
            return true
        case .escape:
            onDismiss()
            return true
        }
    }

    private func move(to index: Int) {
        guard selection != index, rows.indices.contains(index) else { return }
        selection = index
        // Focus never leaves the text field, so tell VoiceOver what is selected.
        AccessibilityNotification.Announcement(Self.spokenLabel(for: rows[index])).post()
    }

    private func submit(_ row: Row, newPage: Bool) {
        switch row {
        case .literal(let value, _), .suggestion(let value):
            onSubmit(.text(value, newPage: opensNewPage || newPage))
        case .result(let result):
            // `.result` cannot carry "in a new page". A history hit is just an address, so with
            // ⌥/⌘ held it goes out as text; the other targets already exist and are simply shown.
            if newPage, case .history(let url) = result.target {
                onSubmit(.text(url.absoluteString, newPage: true))
            } else {
                onSubmit(.result(result))
            }
        }
    }

    // MARK: Text helpers

    static func tag(for result: SearchResult) -> String {
        result.isBookmark ? "Bookmark" : tag(for: result.target)
    }

    static func tag(for target: SearchResult.Target) -> String {
        switch target {
        case .openPage: return "Open"
        case .pin: return "Pinned"
        case .shelf: return "Shelf"
        case .history: return "History"
        }
    }

    static func isShelf(_ target: SearchResult.Target) -> Bool {
        if case .shelf = target { return true }
        return false
    }

    /// The part of a suggestion that continues what was typed is bold, the typed part is soft.
    static func suggestionText(_ phrase: String, typed: String, strong: Color, soft: Color) -> Text {
        var out = AttributedString(phrase)
        out.foregroundColor = strong
        out.font = .system(size: 13, weight: .medium)
        if !typed.isEmpty, phrase.lowercased().hasPrefix(typed.lowercased()) {
            let end = out.index(out.startIndex, offsetByCharacters: typed.count)
            out[out.startIndex..<end].foregroundColor = soft
            out[out.startIndex..<end].font = .system(size: 13)
        }
        return Text(out)
    }

    static func spokenLabel(for row: Row) -> String {
        switch row {
        case .literal(let value, let isURL):
            return isURL ? "Go to \(displayAddress(value))" : "Search for \(value)"
        case .suggestion(let phrase):
            return "Suggested search, \(phrase)"
        case .result(let result):
            return [result.title, result.subtitle, result.isTopHit ? "top hit" : tag(for: result)].filter { !$0.isEmpty }.joined(separator: ", ")
        }
    }

    /// A deliberately simple guess, used only to word the first row. The shell decides for real.
    static func looksLikeURL(_ input: String) -> Bool {
        let text = input.lowercased()
        guard !text.isEmpty, !text.contains(where: { $0.isWhitespace }) else { return false }
        if text.contains("://") { return true }
        for scheme in ["about:", "file:", "data:", "mailto:"] where text.hasPrefix(scheme) { return true }
        guard var host = text.split(whereSeparator: { "/?#".contains($0) }).first.map(String.init) else { return false }
        if let colon = host.lastIndex(of: ":") {
            let port = host[host.index(after: colon)...]
            guard !port.isEmpty, port.allSatisfy({ $0.isNumber }) else { return false }
            host = String(host[..<colon])
        }
        if host == "localhost" { return true }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2,
              labels.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" } }),
              let last = labels.last
        else { return false }
        if labels.count == 4, labels.allSatisfy({ $0.allSatisfy { $0.isNumber } }) { return true }
        return last.count >= 2 && last.allSatisfy { $0.isLetter }
    }

    static func displayAddress(_ input: String) -> String {
        var text = input
        for scheme in ["https://", "http://"] where text.lowercased().hasPrefix(scheme) {
            text = String(text.dropFirst(scheme.count))
        }
        if text.hasSuffix("/"), text.filter({ $0 == "/" }).count == 1 { text.removeLast() }
        return text.isEmpty ? input : text
    }
}
