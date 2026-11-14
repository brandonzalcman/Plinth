import SwiftUI
import AppKit
import PlinthModel

// MARK: - Pin folder

/// A folder as one pin tile: a 2×2 mosaic of its members' icons. Clicking it opens a small tray
/// above the bar listing the members.
struct FolderTileView: View {
    let folder: BarFolderItem
    let folders: [BarFolderItem]
    let ctx: BarContext
    @State private var hovering = false
    @State private var open = false
    @State private var renaming = false

    var body: some View {
        let m = ctx.metrics
        let shape = RoundedRectangle(cornerRadius: m.tileCornerRadius, style: .continuous)
        Button { open.toggle() } label: {
            ZStack {
                shape.fill(ctx.palette.pinIconTile)
                shape.strokeBorder(ctx.palette.pinIconBorder, lineWidth: 1)
                mosaic
                if hovering { shape.fill(ctx.palette.hover) }
            }
            .frame(width: m.tile, height: m.tile)
            .contentShape(shape)
        }
        .buttonStyle(BarPressStyle())
        .overlay {
            if folder.isCurrent {
                RoundedRectangle(cornerRadius: m.tileCornerRadius + 3, style: .continuous)
                    .strokeBorder(ctx.palette.accentLine(ctx.accent), lineWidth: 2)
                    .padding(-3)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .onHover { over in withAnimation(ctx.hoverAnimation) { hovering = over } }
        .help(folder.name)
        .popover(isPresented: $open, arrowEdge: .top) {
            FolderTray(folder: folder, folders: folders, ctx: ctx, renaming: $renaming, close: { open = false })
        }
        .contextMenu {
            Button("Rename…") { renaming = true; open = true }
            Button("Ungroup") { ctx.onAction(.ungroupPinFolder(folder.id)) }
        }
        .accessibilityLabel("\(folder.name), folder of \(folder.members.count) pins")
        .accessibilityAddTraits(folder.isCurrent ? .isSelected : [])
    }

    private var mosaic: some View {
        let cell: CGFloat = 14
        let shown = Array(folder.members.prefix(4))
        return VStack(spacing: 4) {
            ForEach(0..<2, id: \.self) { row in
                HStack(spacing: 4) {
                    ForEach(0..<2, id: \.self) { col in
                        let i = row * 2 + col
                        if i < shown.count {
                            MemberGlyph(pin: shown[i], size: cell, ctx: ctx)
                        } else {
                            Color.clear.frame(width: cell, height: cell)
                        }
                    }
                }
            }
        }
    }
}

/// A member's favicon, or its first letter on Ink until one loads.
struct MemberGlyph: View {
    let pin: BarPinItem
    let size: CGFloat
    let ctx: BarContext

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
        ZStack {
            if let image = ctx.icon(pin.key) {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    .frame(width: size, height: size).clipShape(shape)
            } else {
                shape.fill(ctx.palette.pinTile)
                Text(String(pin.name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased())
                    .font(.system(size: size * 0.6, weight: .semibold))
                    .foregroundStyle(ctx.palette.pinLetter)
            }
        }
        .frame(width: size, height: size)
    }
}

private struct FolderTray: View {
    let folder: BarFolderItem
    let folders: [BarFolderItem]
    let ctx: BarContext
    @Binding var renaming: Bool
    let close: () -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            header
            ForEach(folder.members) { pin in
                Button { ctx.onAction(.selectPin(pin.id)); close() } label: {
                    HStack(spacing: 10) {
                        MemberGlyph(pin: pin, size: 20, ctx: ctx)
                        Text(pin.name)
                            .font(.system(size: 13, weight: pin.isCurrent ? .semibold : .medium))
                            .lineLimit(1)
                        Spacer(minLength: 12)
                        if let n = pin.shortcut {
                            Text("⌘\(n)").font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(pin.isCurrent ? ctx.accent.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu { pinMenu(pin) }
                .accessibilityAddTraits(pin.isCurrent ? .isSelected : [])
            }
        }
        .padding(8)
        .frame(minWidth: 200, maxWidth: 280)
    }

    @ViewBuilder private var header: some View {
        if renaming {
            TextField("Folder name", text: $draft)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { ctx.onAction(.renamePinFolder(folder.id, draft)); renaming = false }
                .onExitCommand { renaming = false }
                .padding(.horizontal, 2).padding(.bottom, 4)
                .onAppear { draft = folder.name; focused = true }
        } else {
            Text(folder.name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8).padding(.top, 2).padding(.bottom, 4)
        }
    }

    @ViewBuilder private func pinMenu(_ pin: BarPinItem) -> some View {
        Button("Remove from Folder") { ctx.onAction(.removePinFromFolder(pin.id)) }
        Button("Reset to Home") { ctx.onAction(.resetPin(pin.id)) }
        Button("Unpin") { ctx.onAction(.unpin(pin.id)) }
    }
}

/// "Move to Folder ▸ New Folder / each other folder", for a pin tile.
@ViewBuilder
func moveToFolderMenu(_ pin: BarPinItem, folders: [BarFolderItem], ctx: BarContext) -> some View {
    Menu("Move to Folder") {
        Button("New Folder") { ctx.onAction(.movePinToFolder(pin.id, folder: nil)) }
        let others = folders.filter { $0.id != pin.folderID }
        if !others.isEmpty {
            Divider()
            ForEach(others) { f in Button(f.name) { ctx.onAction(.movePinToFolder(pin.id, folder: f.id)) } }
        }
    }
}
