import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PlinthModel

/// The downloads tray: a panel in the shelf's style that floats above the bar's right end.
/// Running downloads come first (progress bar, size so far, speed, time left, a cancel button),
/// then the finished ones, newest first. A finished row opens its file; the magnifier shows it in
/// Finder; the × takes it off the list (never deletes the file). "Clear list" removes everything
/// that is no longer running. Escape and clicks outside close it.
public struct DownloadsTrayView: View {
    private let items: [DownloadItem]
    private let accent: Color
    private let onOpen: (UUID) -> Void
    private let onReveal: (UUID) -> Void
    private let onCancel: (UUID) -> Void
    private let onRemove: (UUID) -> Void
    private let onClear: () -> Void
    private let onDismiss: () -> Void
    @Environment(\.colorScheme) private var scheme

    static let width: CGFloat = 380
    static let headerHeight: CGFloat = 46
    static let rowHeight: CGFloat = 56
    static let maxListHeight: CGFloat = 400
    static let emptyHeight: CGFloat = 120

    public init(items: [DownloadItem],
                accent: Color = PanelPalette.sky,
                onOpen: @escaping (UUID) -> Void,
                onReveal: @escaping (UUID) -> Void,
                onCancel: @escaping (UUID) -> Void,
                onRemove: @escaping (UUID) -> Void,
                onClear: @escaping () -> Void,
                onDismiss: @escaping () -> Void) {
        self.items = items; self.accent = accent
        self.onOpen = onOpen; self.onReveal = onReveal; self.onCancel = onCancel
        self.onRemove = onRemove; self.onClear = onClear; self.onDismiss = onDismiss
    }

    /// Running first, then the rest, each newest first.
    static func ordered(_ items: [DownloadItem]) -> [DownloadItem] {
        let newest = items.sorted { $0.startedAt > $1.startedAt }
        return newest.filter { $0.state == .running } + newest.filter { $0.state != .running }
    }

    public var body: some View {
        let palette = PanelPalette(scheme)
        let rows = Self.ordered(items)
        let canClear = items.contains { $0.state != .running }
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(palette.secondary)
                    .accessibilityHidden(true)
                Text("Downloads")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.primary)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                if canClear {
                    PanelPillButton(title: "Clear list", style: .quiet, height: 24, palette: palette, action: onClear)
                        .help("Remove finished downloads from this list. The files stay where they are.")
                }
            }
            .padding(.horizontal, 14)
            .frame(height: Self.headerHeight)
            .background(palette.inputFill)
            Rectangle().fill(palette.divider).frame(height: 1)

            if rows.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 20))
                        .foregroundStyle(palette.tertiary)
                        .padding(.bottom, 4)
                        .accessibilityHidden(true)
                    Text("No downloads.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(palette.primary)
                    Text("Files you download show up here.")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.secondary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: Self.emptyHeight)
                .accessibilityElement(children: .combine)
            } else {
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { item in
                            DownloadRow(item: item, accent: accent, palette: palette,
                                        onOpen: onOpen, onReveal: onReveal, onCancel: onCancel, onRemove: onRemove)
                        }
                    }
                    .padding(6)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: min(CGFloat(rows.count) * Self.rowHeight + 12, Self.maxListHeight))
            }
        }
        .frame(width: Self.width)
        .panelChrome()
        .background(OutsideClickMonitor(onOutside: onDismiss))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Downloads")
    }
}

// MARK: - Text

/// The wording of one row's detail line, kept apart from the view so it reads (and tests) as plain strings.
enum DownloadText {
    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, count), countStyle: .file)
    }

    static func speed(_ bytesPerSecond: Double) -> String {
        bytes(Int64(bytesPerSecond.rounded())) + "/s"
    }

    /// "12 sec left", "3 min left", "1 hr 5 min left"; nil when the rate or size is unknown.
    static func timeLeft(_ item: DownloadItem) -> String? {
        guard let rate = item.bytesPerSecond, rate > 1, let total = item.totalBytes, total > item.receivedBytes else { return nil }
        let seconds = Int((Double(total - item.receivedBytes) / rate).rounded(.up))
        if seconds < 60 { return "\(max(seconds, 1)) sec left" }
        if seconds < 3600 { return "\(seconds / 60) min left" }
        let minutes = (seconds % 3600) / 60
        return minutes == 0 ? "\(seconds / 3600) hr left" : "\(seconds / 3600) hr \(minutes) min left"
    }

    /// "4.2 MB of 48 MB · 2.1 MB/s · 21 sec left" while running; the size and source when finished.
    static func detail(_ item: DownloadItem) -> String {
        switch item.state {
        case .running:
            var parts: [String] = []
            if let total = item.totalBytes {
                parts.append("\(bytes(item.receivedBytes)) of \(bytes(total))")
            } else if item.receivedBytes > 0 {
                parts.append(bytes(item.receivedBytes))
            } else {
                parts.append("Starting…")
            }
            if let rate = item.bytesPerSecond, rate > 1 { parts.append(speed(rate)) }
            if let left = timeLeft(item) { parts.append(left) }
            return parts.joined(separator: " · ")
        case .finished:
            var parts: [String] = []
            if item.receivedBytes > 0 { parts.append(bytes(item.receivedBytes)) }
            if let host = item.sourceURL?.host(percentEncoded: false), !host.isEmpty { parts.append(host) }
            return parts.isEmpty ? "Finished" : parts.joined(separator: " · ")
        case .failed(let reason):
            return reason.isEmpty ? "Failed" : "Failed: \(reason)"
        case .cancelled:
            return "Cancelled"
        }
    }
}

// MARK: - Row

private struct DownloadRow: View {
    var item: DownloadItem
    var accent: Color
    var palette: PanelPalette
    var onOpen: (UUID) -> Void
    var onReveal: (UUID) -> Void
    var onCancel: (UUID) -> Void
    var onRemove: (UUID) -> Void
    @State private var hovered = false

    private var running: Bool { item.state == .running }
    private var finished: Bool { item.state == .finished && item.fileURL != nil }

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: Self.fileIcon(item.filename))
                .resizable()
                .frame(width: 28, height: 28)
                .opacity(item.state == .finished || running ? 1 : 0.5)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.filename)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(palette.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if running { bar }
                Text(DownloadText.detail(item))
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(failed ? palette.notice : palette.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.horizontal, 10)
        .frame(height: DownloadsTrayView.rowHeight)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hovered && finished ? palette.hover : Color.clear))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture { if finished { onOpen(item.id) } }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.filename), \(DownloadText.detail(item))")
        .accessibilityAddTraits(finished ? .isButton : [])
        .accessibilityHint(finished ? "Opens the file" : "")
        .accessibilityAction(named: "Show in Finder") { if finished { onReveal(item.id) } }
        .accessibilityAction(named: running ? "Cancel" : "Remove from list") {
            if running { onCancel(item.id) } else { onRemove(item.id) }
        }
    }

    private var failed: Bool { if case .failed = item.state { return true }; return false }

    @ViewBuilder
    private var bar: some View {
        if let progress = item.progress {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(palette.fill)
                    Capsule().fill(accent).frame(width: max(4, proxy.size.width * min(max(progress, 0), 1)))
                }
            }
            .frame(height: 4)
            .accessibilityHidden(true)
        } else {
            ProgressView().progressViewStyle(.linear).tint(accent).controlSize(.small).frame(height: 4)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if running {
            iconButton("xmark", label: "Cancel \(item.filename)", help: "Cancel this download") { onCancel(item.id) }
        } else {
            HStack(spacing: 2) {
                if finished {
                    iconButton("magnifyingglass", label: "Show \(item.filename) in Finder", help: "Show in Finder") { onReveal(item.id) }
                }
                iconButton("xmark", label: "Remove \(item.filename) from the list", help: "Remove from the list") { onRemove(item.id) }
            }
            .opacity(hovered ? 1 : 0)
        }
    }

    private func iconButton(_ symbol: String, label: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(palette.secondary)
                .frame(width: 22, height: 22)
                .background(Circle().fill(palette.fill))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(label)
    }

    /// File icons by extension, looked up once each.
    @MainActor private static var iconCache: [String: NSImage] = [:]

    @MainActor static func fileIcon(_ filename: String) -> NSImage {
        let ext = (filename as NSString).pathExtension.lowercased()
        if let cached = iconCache[ext] { return cached }
        let type = ext.isEmpty ? UTType.data : (UTType(filenameExtension: ext) ?? .data)
        let icon = NSWorkspace.shared.icon(for: type)
        iconCache[ext] = icon
        return icon
    }
}
