import SwiftUI
import AppKit
import PlinthModel

/// The pill for a group the user accepted: its icons and name plus a one-click toggle between
/// "Show only these" (hide everything else on the bar) and "Show all". Right-click offers
/// "Remove Group". Width fits its content, up to `GroupChipView.maxWidth`.
public struct GroupChipView: View {
    private let name: String
    private let keys: [SiteKey]
    private let isFiltering: Bool
    private let accent: Color
    private let icon: (SiteKey) -> NSImage?
    private let onToggle: () -> Void
    private let onRemove: () -> Void
    @Environment(\.colorScheme) private var scheme

    public static let height: CGFloat = 36
    /// Just short of half the height: a full-radius continuous corner leaves flat ticks at the sides.
    static let cornerRadius: CGFloat = 14
    public static let maxWidth: CGFloat = 360

    /// - Parameters:
    ///   - isFiltering: true while only this group's sites are showing; the button then reads "Show all".
    ///   - onToggle: flip between showing only the group and showing everything.
    public init(name: String,
                keys: [SiteKey],
                isFiltering: Bool,
                accent: Color,
                icon: @escaping (SiteKey) -> NSImage?,
                onToggle: @escaping () -> Void,
                onRemove: @escaping () -> Void) {
        self.name = name; self.keys = keys; self.isFiltering = isFiltering; self.accent = accent
        self.icon = icon; self.onToggle = onToggle; self.onRemove = onRemove
    }

    /// Convenience for a `SiteGroup` straight from the model.
    public init(group: SiteGroup,
                isFiltering: Bool,
                accent: Color,
                icon: @escaping (SiteKey) -> NSImage?,
                onToggle: @escaping () -> Void,
                onRemove: @escaping () -> Void) {
        self.init(name: group.name, keys: group.keys, isFiltering: isFiltering, accent: accent, icon: icon,
                  onToggle: onToggle, onRemove: onRemove)
    }

    public var body: some View {
        let palette = PanelPalette(scheme)
        HStack(spacing: 8) {
            SiteIconStack(keys: keys, names: [], icon: icon, size: 14, palette: palette)
            Text(name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(palette.primary)
                .lineLimit(1)
                .truncationMode(.tail)
            Rectangle().fill(palette.divider).frame(width: 1, height: 16)
            if isFiltering {
                PanelPillButton(title: "Show all", systemImage: "square.grid.2x2", style: .quiet,
                                height: 24, palette: palette, action: onToggle)
                    .help("Show every site on the bar again")
            } else {
                PanelPillButton(title: "Show only these", systemImage: "line.3.horizontal.decrease", style: .quiet,
                                height: 24, palette: palette, action: onToggle)
                    .help("Hide sites outside \(name)")
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 5)
        .frame(height: Self.height)
        .frame(maxWidth: Self.maxWidth)
        .fixedSize(horizontal: true, vertical: false)
        .panelChrome(cornerRadius: Self.cornerRadius)
        .overlay {
            // While filtering, an accent edge says the bar is showing a subset.
            if isFiltering {
                RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous).strokeBorder(accent, lineWidth: 1.5).allowsHitTesting(false)
            }
        }
        .contextMenu {
            Button("Remove Group", role: .destructive, action: onRemove)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isFiltering ? "\(name) group, showing only these sites" : "\(name) group")
        .accessibilityAction(named: "Remove Group", onRemove)
    }
}
