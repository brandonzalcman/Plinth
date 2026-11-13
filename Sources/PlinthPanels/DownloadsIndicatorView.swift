import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PlinthModel

/// A small round button for the bar: a progress ring while any download is running (a spinning
/// arc when no running download knows its size), a plain down-arrow otherwise. Clicking it
/// toggles a popover with `DownloadsListView`. Fixed size: `DownloadsIndicatorView.diameter`.
public struct DownloadsIndicatorView: View {
    private let items: [DownloadItem]
    private let accent: Color
    private let onReveal: (UUID) -> Void
    private let onCancel: (UUID) -> Void
    private let onClear: () -> Void

    @State private var showsList = false
    @State private var hovered = false
    @State private var spin = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public static let diameter: CGFloat = 34

    public init(items: [DownloadItem],
                accent: Color = PanelPalette.sky,
                onReveal: @escaping (UUID) -> Void,
                onCancel: @escaping (UUID) -> Void,
                onClear: @escaping () -> Void) {
        self.items = items; self.accent = accent
        self.onReveal = onReveal; self.onCancel = onCancel; self.onClear = onClear
    }

    private var running: [DownloadItem] { items.filter { $0.state == .running } }

    /// Average progress of the running downloads that know their size; nil when none do.
    static func overallProgress(_ items: [DownloadItem]) -> Double? {
        let known = items.filter { $0.state == .running }.compactMap(\.progress)
        guard !known.isEmpty else { return nil }
        return min(max(known.reduce(0, +) / Double(known.count), 0), 1)
    }

    public var body: some View {
        let palette = PanelPalette(scheme)
        let isRunning = !running.isEmpty
        let progress = Self.overallProgress(items)
        Button {
            showsList.toggle()
        } label: {
            ZStack {
                Circle().fill(hovered || showsList ? palette.hover : palette.inputFill)
                Circle().strokeBorder(palette.border, lineWidth: 1)
                if isRunning {
                    let ring = Circle().inset(by: 4.5)
                    ring.stroke(palette.divider, lineWidth: 2.5)
                    if let progress {
                        ring.trim(from: 0, to: max(progress, 0.03))
                            .stroke(accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .animation(.easeOut(duration: 0.25), value: progress)
                    } else {
                        ring.trim(from: 0, to: 0.28)
                            .stroke(accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            .rotationEffect(.degrees(spin ? 270 : -90))
                            .onAppear {
                                guard !reduceMotion else { return }
                                withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) { spin = true }
                            }
                            .onDisappear { spin = false }
                    }
                }
                Image(systemName: "arrow.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isRunning ? accent : palette.secondary)
            }
            .frame(width: Self.diameter, height: Self.diameter)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help("Downloads")
        .accessibilityLabel(accessibilityText(progress: progress))
        .popover(isPresented: $showsList, arrowEdge: .top) {
            DownloadsListView(items: items, accent: accent, onReveal: onReveal, onCancel: onCancel, onClear: onClear)
                .environment(\.colorScheme, scheme)
        }
    }

    private func accessibilityText(progress: Double?) -> String {
        guard !running.isEmpty else { return "Downloads" }
        let count = running.count == 1 ? "1 download" : "\(running.count) downloads"
        if let progress { return "Downloads, \(count) running, \(Int((progress * 100).rounded())) percent" }
        return "Downloads, \(count) running"
    }
}

/// The list inside the downloads popover: newest first, each with its file icon, name and
/// progress or state. Running items can be cancelled; items with a file can be shown in Finder
/// (also by double-clicking the row). "Clear" removes everything that is no longer running.
/// Fixed width: `DownloadsListView.width`.
public struct DownloadsListView: View {
    private let items: [DownloadItem]
    private let accent: Color
    private let onReveal: (UUID) -> Void
    private let onCancel: (UUID) -> Void
    private let onClear: () -> Void
    @Environment(\.colorScheme) private var scheme

    public static let width: CGFloat = 320
    public static let maxListHeight: CGFloat = 360

    public init(items: [DownloadItem],
                accent: Color = PanelPalette.sky,
                onReveal: @escaping (UUID) -> Void,
                onCancel: @escaping (UUID) -> Void,
                onClear: @escaping () -> Void) {
        self.items = items; self.accent = accent
        self.onReveal = onReveal; self.onCancel = onCancel; self.onClear = onClear
    }

    private var sorted: [DownloadItem] { items.sorted { $0.startedAt > $1.startedAt } }

    public var body: some View {
        let palette = PanelPalette(scheme)
        VStack(spacing: 0) {
            HStack {
                Text("Downloads")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.primary)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if items.contains(where: { $0.state != .running }) {
                    PanelPillButton(title: "Clear", style: .quiet, height: 22, palette: palette, action: onClear)
                        .help("Clear finished downloads")
                }
            }
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .frame(height: 38)
            Rectangle().fill(palette.divider).frame(height: 1)
            if items.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 20))
                        .foregroundStyle(palette.tertiary)
                        .accessibilityHidden(true)
                    Text("No downloads")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.secondary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 96)
            } else {
                ScrollView(.vertical) {
                    VStack(spacing: 2) {
                        ForEach(sorted) { item in
                            DownloadRow(item: item, accent: accent, palette: palette,
                                        onReveal: onReveal, onCancel: onCancel)
                        }
                    }
                    .padding(6)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: min(CGFloat(items.count) * 50 + 12, Self.maxListHeight))
            }
        }
        .frame(width: Self.width)
        .background(palette.surface)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Downloads")
    }
}

private struct DownloadRow: View {
    var item: DownloadItem
    var accent: Color
    var palette: PanelPalette
    var onReveal: (UUID) -> Void
    var onCancel: (UUID) -> Void
    @State private var hovered = false

    private var canReveal: Bool { item.fileURL != nil && item.state == .finished }

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: Self.fileIcon(item.filename))
                .resizable()
                .frame(width: 28, height: 28)
                .opacity(item.state == .finished || item.state == .running ? 1 : 0.5)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.filename)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(palette.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                status
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if item.state == .running {
                iconButton("xmark.circle.fill", label: "Cancel \(item.filename)") { onCancel(item.id) }
            } else if canReveal {
                iconButton("magnifyingglass.circle.fill", label: "Show \(item.filename) in Finder") { onReveal(item.id) }
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 48)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hovered ? palette.hover : Color.clear))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture(count: 2) { if canReveal { onReveal(item.id) } }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var status: some View {
        switch item.state {
        case .running:
            if let progress = item.progress {
                HStack(spacing: 8) {
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(palette.fill)
                            Capsule().fill(accent).frame(width: proxy.size.width * min(max(progress, 0), 1))
                        }
                    }
                    .frame(height: 4)
                    Text("\(Int((min(max(progress, 0), 1) * 100).rounded()))%")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(palette.tertiary)
                        .fixedSize()
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(Int((progress * 100).rounded())) percent")
            } else {
                Text("Downloading…").font(.system(size: 11)).foregroundStyle(palette.tertiary)
            }
        case .finished:
            Text("Finished").font(.system(size: 11)).foregroundStyle(palette.tertiary)
        case .failed(let reason):
            Text(reason.isEmpty ? "Failed" : "Failed: \(reason)")
                .font(.system(size: 11))
                .foregroundStyle(palette.notice)
                .lineLimit(1)
                .truncationMode(.tail)
        case .cancelled:
            Text("Cancelled").font(.system(size: 11)).foregroundStyle(palette.tertiary)
        }
    }

    private func iconButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16))
                .foregroundStyle(palette.tertiary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }

    static func fileIcon(_ filename: String) -> NSImage {
        let ext = (filename as NSString).pathExtension
        let type = ext.isEmpty ? UTType.data : (UTType(filenameExtension: ext) ?? .data)
        return NSWorkspace.shared.icon(for: type)
    }
}
