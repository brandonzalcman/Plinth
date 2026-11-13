import SwiftUI
import AppKit
import PlinthModel

/// A small "where you left off" card shown just above the bar when a site comes back from the
/// shelf: the site's icon, a caption, the page name and a one or two sentence summary. While the
/// summary is still being written (`summary == nil && isLoading`) two quiet shimmering lines
/// stand in for it; with no summary and nothing loading, only the page name shows.
///
/// The × button and Escape (when no text field is being edited) call `onDismiss`. Timing out
/// the card is the shell's job. Fixed width: `ResumeCardView.width`.
public struct ResumeCardView: View {
    private let siteKey: SiteKey
    private let siteName: String
    private let pageName: String
    private let summary: String?
    private let isLoading: Bool
    private let accent: Color
    private let icon: (SiteKey) -> NSImage?
    private let onDismiss: () -> Void
    @Environment(\.colorScheme) private var scheme

    public static let width: CGFloat = 360

    public init(siteKey: SiteKey,
                siteName: String,
                pageName: String,
                summary: String?,
                isLoading: Bool,
                accent: Color,
                icon: @escaping (SiteKey) -> NSImage?,
                onDismiss: @escaping () -> Void) {
        self.siteKey = siteKey; self.siteName = siteName; self.pageName = pageName
        self.summary = summary; self.isLoading = isLoading; self.accent = accent
        self.icon = icon; self.onDismiss = onDismiss
    }

    private var trimmedSummary: String? {
        guard let text = summary?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    public var body: some View {
        let palette = PanelPalette(scheme)
        HStack(alignment: .top, spacing: 10) {
            SiteIconView(key: siteKey, name: siteName, image: icon(siteKey), size: 20)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(accent)
                        .accessibilityHidden(true)
                    Text("Where you left off")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(palette.tertiary)
                }
                Text(pageName.isEmpty ? siteName : pageName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let text = trimmedSummary {
                    Text(text)
                        .font(.system(size: 12))
                        .foregroundStyle(palette.secondary)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                        .transition(.opacity)
                } else if isLoading {
                    VStack(alignment: .leading, spacing: 6) {
                        ShimmerLine(width: nil, palette: palette)
                        ShimmerLine(width: 170, palette: palette)
                    }
                    .padding(.top, 6)
                    .padding(.bottom, 2)
                    .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            PanelCloseButton(label: "Dismiss", palette: palette, action: onDismiss)
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .padding(.vertical, 12)
        .frame(width: Self.width)
        .panelChrome(cornerRadius: 16)
        .animation(.easeOut(duration: 0.18), value: trimmedSummary)
        .background(PanelKeyMonitor { event, window in
            guard event.keyCode == PanelKeyMonitor.escape, PanelKeyMonitor.isPlain(event),
                  !PanelKeyMonitor.isEditingText(in: window) else { return false }
            onDismiss()
            return true
        })
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityText)
        .accessibilityAction(.escape, onDismiss)
    }

    private var accessibilityText: String {
        var parts = ["Where you left off", pageName.isEmpty ? siteName : pageName]
        if let text = trimmedSummary { parts.append(text) } else if isLoading { parts.append("Summary loading") }
        return parts.joined(separator: ", ")
    }
}
