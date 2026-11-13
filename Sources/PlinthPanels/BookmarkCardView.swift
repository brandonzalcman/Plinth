import SwiftUI
import AppKit
import PlinthModel

/// The card that appears above the bar when a page is bookmarked with ⌘D: a short confirmation
/// with the title to edit, the folder to keep it in, and Remove. Return or Escape finishes (the
/// title is kept). Left alone it goes away after a few seconds; touching it keeps it open.
public struct BookmarkCardView: View {
    private let siteKey: SiteKey
    private let isNew: Bool
    private let url: String
    private let folders: [BookmarkFolderChoice]
    private let selectedFolder: UUID?
    private let accent: Color
    private let icon: (SiteKey) -> NSImage?
    private let onRename: (String) -> Void
    private let onMove: (UUID?) -> Void
    private let onRemove: () -> Void
    private let onDismiss: () -> Void

    @State private var title: String
    @State private var touched = false
    @Environment(\.colorScheme) private var scheme

    public static let width: CGFloat = 380
    static let linger: Duration = .seconds(4)

    public init(siteKey: SiteKey, title: String, url: String, isNew: Bool,
                folders: [BookmarkFolderChoice], selectedFolder: UUID?, accent: Color,
                icon: @escaping (SiteKey) -> NSImage?,
                onRename: @escaping (String) -> Void, onMove: @escaping (UUID?) -> Void,
                onRemove: @escaping () -> Void, onDismiss: @escaping () -> Void) {
        self.siteKey = siteKey; self.url = url; self.isNew = isNew; self.folders = folders
        self.selectedFolder = selectedFolder; self.accent = accent; self.icon = icon
        self.onRename = onRename; self.onMove = onMove; self.onRemove = onRemove; self.onDismiss = onDismiss
        _title = State(initialValue: title)
    }

    private var folderLabel: String {
        folders.first { $0.id == selectedFolder }?.label ?? "Bookmarks"
    }

    public var body: some View {
        let palette = PanelPalette(scheme)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: isNew ? "bookmark.fill" : "bookmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(accent)
                    .accessibilityHidden(true)
                Text(isNew ? "Saved to Bookmarks" : "Already in Bookmarks")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(palette.tertiary)
                Spacer(minLength: 0)
                PanelCloseButton(label: "Done", hint: "esc", palette: palette, action: finish)
            }
            HStack(spacing: 10) {
                SiteIconView(key: siteKey, name: siteKey.host, image: icon(siteKey), size: 20)
                VStack(alignment: .leading, spacing: 2) {
                    PanelTextField(text: $title,
                                   placeholder: "Title",
                                   fontSize: 13,
                                   textColor: palette.primary,
                                   placeholderColor: palette.tertiary,
                                   accent: accent,
                                   label: "Bookmark title",
                                   focusOnAppear: true,
                                   selectAllOnFocus: true,
                                   onKey: handle)
                    Text(url)
                        .font(.system(size: 12))
                        .foregroundStyle(palette.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .onChange(of: title) { touched = true }
            HStack(spacing: 6) {
                folderMenu(palette: palette)
                Spacer(minLength: 0)
                PanelPillButton(title: "Remove", systemImage: "trash", style: .quiet, palette: palette) {
                    onRemove()
                }
                PanelPillButton(title: "Done", hint: "⏎", style: .accent(accent), palette: palette, action: finish)
            }
        }
        .padding(14)
        .frame(width: Self.width)
        .panelChrome()
        .background(OutsideClickMonitor(onOutside: finish))
        .onHover { if $0 { touched = true } }
        .task {
            // The card is a confirmation, not a dialog: it leaves on its own unless it was used.
            try? await Task.sleep(for: Self.linger)
            if !Task.isCancelled, !touched { onDismiss() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Bookmark")
    }

    private func folderMenu(palette: PanelPalette) -> some View {
        Menu {
            ForEach(folders) { choice in
                Button {
                    touched = true
                    onMove(choice.id)
                } label: {
                    if choice.id == selectedFolder { Label(choice.label, systemImage: "checkmark") } else { Text(choice.label) }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "folder").font(.system(size: 11, weight: .medium))
                Text(folderLabel)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .frame(maxWidth: 170, alignment: .leading)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(palette.secondary)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(Capsule().fill(palette.fill))
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Folder")
        .accessibilityValue(folderLabel)
    }

    private func handle(_ key: PanelKey) -> Bool {
        switch key {
        case .submit, .escape:
            finish()
            return true
        case .up, .down:
            return false
        }
    }

    private func finish() {
        onRename(title)
        onDismiss()
    }
}
