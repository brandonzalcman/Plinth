import SwiftUI
import AppKit
import PlinthModel

/// An unobtrusive pill shown above the bar when some sites have been open together for a while:
/// their icons, "Group Docs, Mail & Calendar?", a quiet "Not now" and an accent "Group".
/// Ignoring it changes nothing; it never takes focus or keys. Width fits its content, up to
/// `GroupSuggestionView.maxWidth`.
public struct GroupSuggestionView: View {
    private let keys: [SiteKey]
    private let siteNames: [String]
    private let accent: Color
    private let icon: (SiteKey) -> NSImage?
    private let onGroup: () -> Void
    private let onNotNow: () -> Void
    @Environment(\.colorScheme) private var scheme

    public static let height: CGFloat = 40
    /// Just short of half the height: a full-radius continuous corner leaves flat ticks at the sides.
    static let cornerRadius: CGFloat = 16
    public static let maxWidth: CGFloat = 480

    /// - Parameters:
    ///   - keys: the sites to group, in display order.
    ///   - siteNames: their display names, in `keys` order.
    public init(keys: [SiteKey],
                siteNames: [String],
                accent: Color,
                icon: @escaping (SiteKey) -> NSImage?,
                onGroup: @escaping () -> Void,
                onNotNow: @escaping () -> Void) {
        self.keys = keys; self.siteNames = siteNames; self.accent = accent; self.icon = icon
        self.onGroup = onGroup; self.onNotNow = onNotNow
    }

    /// Convenience for a `GroupSuggestion` straight from the model.
    public init(suggestion: GroupSuggestion,
                accent: Color,
                icon: @escaping (SiteKey) -> NSImage?,
                onGroup: @escaping () -> Void,
                onNotNow: @escaping () -> Void) {
        self.init(keys: suggestion.keys, siteNames: suggestion.siteNames, accent: accent, icon: icon,
                  onGroup: onGroup, onNotNow: onNotNow)
    }

    private var question: String { "Group \(PanelText.joinedNames(siteNames))?" }

    public var body: some View {
        let palette = PanelPalette(scheme)
        HStack(spacing: 10) {
            SiteIconStack(keys: keys, names: siteNames, icon: icon, size: 16, palette: palette)
            Text(question)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(palette.primary)
                .lineLimit(1)
                .truncationMode(.tail)
            HStack(spacing: 2) {
                PanelPillButton(title: "Not now", style: .quiet, palette: palette, action: onNotNow)
                PanelPillButton(title: "Group", style: .accent(accent), palette: palette, action: onGroup)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 7)
        .frame(height: Self.height)
        .frame(maxWidth: Self.maxWidth)
        .fixedSize(horizontal: true, vertical: false)
        .panelChrome(cornerRadius: Self.cornerRadius)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(question)
    }
}
