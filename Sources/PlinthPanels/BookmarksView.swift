import SwiftUI
import AppKit
import PlinthModel

/// The bookmarks panel: folders and bookmarks in one list, with a search field on top.
///
/// Typing filters every bookmark and folder by title, address or folder name, wherever it is.
/// With nothing typed, the list shows one folder at a time, folders first; the header goes back up
/// a level and makes a new folder. ↑/↓ move through the rows, Return opens a bookmark in a new
/// page or steps into a folder, Escape closes. Each row's "…" menu renames, moves and removes
/// (removing a folder keeps what was in it).
public struct BookmarksView: View {
    private let folders: [BookmarkFolder]
    private let bookmarks: [Bookmark]
    private let accent: Color
    private let icon: (SiteKey) -> NSImage?
    private let onOpen: (Bookmark) -> Void
    private let onRename: (UUID, String) -> Void
    private let onMove: (UUID, UUID?) -> Void
    private let onRemove: (UUID) -> Void
    private let onAddFolder: (String, UUID?) -> UUID
    private let onRenameFolder: (UUID, String) -> Void
    private let onMoveFolder: (UUID, UUID?) -> Void
    private let onRemoveFolder: (UUID) -> Void
    private let onDismiss: () -> Void

    @State private var current: UUID?
    @State private var text = ""
    @State private var selection: UUID?
    @State private var hovered: UUID?
    @State private var renaming: UUID?
    @State private var renameText = ""
    @State private var scrollTick = 0
    @Environment(\.colorScheme) private var scheme

    static let width: CGFloat = 460
    static let listHeight: CGFloat = 380
    static let rowHeight: CGFloat = 34

    public init(folders: [BookmarkFolder], bookmarks: [Bookmark], accent: Color,
                icon: @escaping (SiteKey) -> NSImage?,
                onOpen: @escaping (Bookmark) -> Void,
                onRename: @escaping (UUID, String) -> Void,
                onMove: @escaping (UUID, UUID?) -> Void,
                onRemove: @escaping (UUID) -> Void,
                onAddFolder: @escaping (String, UUID?) -> UUID,
                onRenameFolder: @escaping (UUID, String) -> Void,
                onMoveFolder: @escaping (UUID, UUID?) -> Void,
                onRemoveFolder: @escaping (UUID) -> Void,
                onDismiss: @escaping () -> Void) {
        self.folders = folders; self.bookmarks = bookmarks; self.accent = accent; self.icon = icon
        self.onOpen = onOpen; self.onRename = onRename; self.onMove = onMove; self.onRemove = onRemove
        self.onAddFolder = onAddFolder; self.onRenameFolder = onRenameFolder; self.onMoveFolder = onMoveFolder
        self.onRemoveFolder = onRemoveFolder; self.onDismiss = onDismiss
    }

    // MARK: Data

    enum Entry: Identifiable, Equatable {
        case folder(BookmarkFolder)
        case bookmark(Bookmark)
        var id: UUID {
            switch self { case .folder(let f): f.id; case .bookmark(let b): b.id }
        }
    }

    private var query: [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map { Self.fold(String($0)) }
    }

    private func name(of folder: UUID?) -> String {
        Self.path(of: folder, in: folders).joined(separator: " › ")
    }

    /// The rows now on show.
    var entries: [Entry] {
        let tokens = query
        let byName: (BookmarkFolder, BookmarkFolder) -> Bool = { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if tokens.isEmpty {
            return folders.filter { $0.parent == current }.sorted(by: byName).map(Entry.folder)
                + bookmarks.filter { $0.folder == current }.map(Entry.bookmark)
        }
        let matchedFolders = folders.filter { f in
            let haystack = Self.fold(name(of: f.id))
            return tokens.allSatisfy { haystack.contains($0) }
        }.sorted(by: byName).map(Entry.folder)
        let matchedBookmarks = bookmarks.filter { b in
            let haystack = Self.fold(b.title + " " + b.url.absoluteString + " " + name(of: b.folder))
            return tokens.allSatisfy { haystack.contains($0) }
        }.map(Entry.bookmark)
        return matchedFolders + matchedBookmarks
    }

    // MARK: Body

    public var body: some View {
        let palette = PanelPalette(scheme)
        let rows = entries
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(palette.secondary)
                    .accessibilityHidden(true)
                PanelTextField(text: $text,
                               placeholder: "Search bookmarks",
                               fontSize: 13,
                               textColor: palette.primary,
                               placeholderColor: palette.tertiary,
                               accent: accent,
                               label: "Search bookmarks",
                               focusOnAppear: true,
                               selectAllOnFocus: true,
                               onKey: handle)
            }
            .padding(.horizontal, 14)
            .frame(height: 46)
            .background(palette.inputFill)
            Rectangle().fill(palette.divider).frame(height: 1)

            header(palette: palette)
            Rectangle().fill(palette.divider).frame(height: 1)

            Group {
                if rows.isEmpty { message(palette: palette) } else { list(rows, palette: palette) }
            }
            .frame(height: Self.listHeight)

            Rectangle().fill(palette.divider).frame(height: 1)
            footer(rows, palette: palette)
        }
        .frame(width: Self.width)
        .panelChrome()
        .background(OutsideClickMonitor(onOutside: onDismiss))
        .onChange(of: text) { selection = nil; hovered = nil }
        .onChange(of: current) { selection = nil; hovered = nil }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Bookmarks")
    }

    // MARK: Pieces

    private func header(palette: PanelPalette) -> some View {
        HStack(spacing: 6) {
            if current != nil, query.isEmpty {
                Button { current = folders.first { $0.id == current }?.parent } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(palette.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Up one folder")
            }
            Text(query.isEmpty ? (current == nil ? "Bookmarks" : name(of: current)) : "Search results")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(palette.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 6)
            if query.isEmpty {
                PanelPillButton(title: "New Folder", systemImage: "folder.badge.plus", style: .quiet, height: 24, palette: palette) {
                    let id = onAddFolder("New Folder", current)
                    beginRename(id, text: "New Folder")
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
    }

    private func list(_ rows: [Entry], palette: PanelPalette) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { entry in
                        rowView(entry, palette: palette).id(entry.id)
                    }
                }
                .padding(6)
            }
            .onChange(of: scrollTick) {
                if let selection { proxy.scrollTo(selection) }
            }
        }
    }

    private func rowView(_ entry: Entry, palette: PanelPalette) -> some View {
        let id = entry.id
        let selected = selection == id
        let strong = selected ? palette.onAccent : palette.primary
        let soft = selected ? palette.onAccent.opacity(0.85) : palette.secondary
        let isRenaming = renaming == id
        let content = HStack(spacing: 8) {
            switch entry {
            case .folder(let folder):
                Image(systemName: "folder")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(selected ? palette.onAccent : accent)
                    .frame(width: 16, height: 16)
                    .accessibilityHidden(true)
                titleView(folder.name, palette: palette, strong: strong, isRenaming: isRenaming, label: "Folder name")
                if !isRenaming {
                    Text(count(in: folder.id))
                        .font(.system(size: 12))
                        .foregroundStyle(soft)
                        .lineLimit(1)
                        .fixedSize()
                }
                Spacer(minLength: 6)
            case .bookmark(let bookmark):
                let key = SiteKey(bookmark.url.host(percentEncoded: false) ?? "")
                SiteIconView(key: key, name: key.host, image: icon(key), size: 16)
                titleView(bookmark.title, palette: palette, strong: strong, isRenaming: isRenaming, label: "Bookmark title")
                if !isRenaming {
                    Text(query.isEmpty || bookmark.folder == nil ? HistoryView.location(bookmark.url) : name(of: bookmark.folder))
                        .font(.system(size: 12))
                        .foregroundStyle(soft)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 6)
            }
            if !isRenaming {
                if selected || hovered == id {
                    actionsMenu(entry, selected: selected, palette: palette)
                } else if case .folder = entry {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(soft)
                        .accessibilityHidden(true)
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: Self.rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(selected ? accent : (hovered == id ? palette.hover : Color.clear)))
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { hovered = id } else if hovered == id { hovered = nil }
        }
        return Group {
            if isRenaming {
                content
            } else {
                Button { activate(entry) } label: { content }
                    .buttonStyle(.plain)
                    .contextMenu { menuItems(for: entry) }
            }
        }
        .accessibilityElement(children: isRenaming ? .contain : .ignore)
        .accessibilityLabel(label(for: entry))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private func titleView(_ title: String, palette: PanelPalette, strong: Color, isRenaming: Bool, label: String) -> some View {
        if isRenaming {
            PanelTextField(text: $renameText, placeholder: label, fontSize: 13, textColor: palette.primary,
                           placeholderColor: palette.tertiary, accent: accent, label: label,
                           focusOnAppear: true, selectAllOnFocus: true, onKey: handleRename)
        } else {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(strong)
                .lineLimit(1)
                .layoutPriority(1)
        }
    }

    private func actionsMenu(_ entry: Entry, selected: Bool, palette: PanelPalette) -> some View {
        Menu { menuItems(for: entry) } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(selected ? palette.onAccent : palette.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("More")
    }

    @ViewBuilder
    private func menuItems(for entry: Entry) -> some View {
        switch entry {
        case .bookmark(let bookmark):
            Button("Rename") { beginRename(bookmark.id, text: bookmark.title) }
            Menu("Move to") {
                ForEach(Self.choices(folders: folders, excluding: nil)) { choice in
                    Button { onMove(bookmark.id, choice.id) } label: {
                        if choice.id == bookmark.folder { Label(choice.label, systemImage: "checkmark") } else { Text(choice.label) }
                    }
                }
            }
            Divider()
            Button("Remove Bookmark", role: .destructive) { onRemove(bookmark.id) }
        case .folder(let folder):
            Button("Rename") { beginRename(folder.id, text: folder.name) }
            Menu("Move to") {
                ForEach(Self.choices(folders: folders, excluding: folder.id)) { choice in
                    Button { onMoveFolder(folder.id, choice.id) } label: {
                        if choice.id == folder.parent { Label(choice.label, systemImage: "checkmark") } else { Text(choice.label) }
                    }
                }
            }
            Divider()
            Button("Delete Folder (Keep Bookmarks)", role: .destructive) {
                if current == folder.id { current = folder.parent }
                onRemoveFolder(folder.id)
            }
        }
    }

    private func message(palette: PanelPalette) -> some View {
        let searching = !query.isEmpty
        return VStack(spacing: 6) {
            Image(systemName: searching ? "magnifyingglass" : "bookmark")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(palette.tertiary)
                .padding(.bottom, 4)
                .accessibilityHidden(true)
            Text(searching ? "No matches." : (current == nil ? "No bookmarks yet." : "This folder is empty."))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(palette.primary)
            Text(searching ? "Try different words." : "Press ⌘D on a page to bookmark it.")
                .font(.system(size: 12))
                .foregroundStyle(palette.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func footer(_ rows: [Entry], palette: PanelPalette) -> some View {
        let marks = rows.filter { if case .bookmark = $0 { true } else { false } }.count
        let label = rows.isEmpty ? "Nothing to show"
            : "\(marks.formatted()) \(marks == 1 ? "bookmark" : "bookmarks")" + (rows.count > marks ? ", \((rows.count - marks).formatted()) \(rows.count - marks == 1 ? "folder" : "folders")" : "")
        return Text(label)
            .font(.system(size: 11))
            .foregroundStyle(palette.tertiary)
            .lineLimit(1)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 28)
    }

    // MARK: Actions

    private func activate(_ entry: Entry) {
        switch entry {
        case .bookmark(let bookmark): onOpen(bookmark)
        case .folder(let folder):
            text = ""
            current = folder.id
        }
    }

    private func beginRename(_ id: UUID, text: String) {
        renameText = text
        renaming = id
        selection = id
    }

    private func finishRename(save: Bool) {
        guard let id = renaming else { return }
        renaming = nil
        guard save else { return }
        if folders.contains(where: { $0.id == id }) { onRenameFolder(id, renameText) } else { onRename(id, renameText) }
    }

    private func handleRename(_ key: PanelKey) -> Bool {
        switch key {
        case .submit: finishRename(save: true); return true
        case .escape: finishRename(save: false); return true
        case .up, .down: return true
        }
    }

    private func count(in folder: UUID) -> String {
        let n = bookmarks.filter { $0.folder == folder }.count + folders.filter { $0.parent == folder }.count
        return "\(n)"
    }

    private func label(for entry: Entry) -> String {
        switch entry {
        case .folder(let f): "Folder, \(f.name), \(count(in: f.id)) items"
        case .bookmark(let b): "\(b.title), \(HistoryView.location(b.url))"
        }
    }

    // MARK: Keys

    private func handle(_ key: PanelKey) -> Bool {
        let rows = entries
        let index = selection.flatMap { id in rows.firstIndex { $0.id == id } }
        switch key {
        case .down:
            guard !rows.isEmpty else { return false }
            move(to: rows[min((index ?? -1) + 1, rows.count - 1)])
            return true
        case .up:
            guard !rows.isEmpty else { return false }
            if let index, index > 0 { move(to: rows[index - 1]) } else { selection = nil }
            return true
        case .submit:
            if let index { activate(rows[index]) }
            else if let first = rows.first(where: { if case .bookmark = $0 { true } else { false } }), !query.isEmpty { activate(first) }
            return true
        case .escape:
            onDismiss()
            return true
        }
    }

    private func move(to entry: Entry) {
        guard selection != entry.id else { return }
        selection = entry.id
        scrollTick += 1
        AccessibilityNotification.Announcement(label(for: entry)).post()
    }

    // MARK: Helpers

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    static func path(of folder: UUID?, in folders: [BookmarkFolder]) -> [String] {
        var names: [String] = []
        var at = folder
        var steps = 0
        while let id = at, let f = folders.first(where: { $0.id == id }), steps < 64 {
            names.insert(f.name, at: 0)
            at = f.parent
            steps += 1
        }
        return names
    }

    /// Where something can be moved to: the top level, then every folder by path. A folder being
    /// moved is left out together with everything inside it.
    static func choices(folders: [BookmarkFolder], excluding moving: UUID?) -> [BookmarkFolderChoice] {
        func inside(_ id: UUID) -> Bool {
            guard let moving else { return false }
            var at: UUID? = id
            var steps = 0
            while let current = at, steps < 64 {
                if current == moving { return true }
                at = folders.first { $0.id == current }?.parent
                steps += 1
            }
            return false
        }
        var out = [BookmarkFolderChoice(id: nil, label: "Bookmarks")]
        for f in folders where !inside(f.id) {
            out.append(BookmarkFolderChoice(id: f.id, label: path(of: f.id, in: folders).joined(separator: " › ")))
        }
        return Array(out.prefix(1)) + out.dropFirst().sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }
}
