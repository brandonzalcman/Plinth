import AppKit
import PlinthModel

/// Measures bar text with the same fonts the bar draws with. The shell hands
/// `BarTextMeasurer.width` to the layout engine as its `measure` closure.
public enum BarTextMeasurer {
    public static let fontSize: CGFloat = 13

    public static func font(for style: BarTextStyle) -> NSFont {
        switch style {
        case .page: return pageFont
        case .currentPage: return currentFont
        case .regular: return regularFont
        }
    }

    /// Width in points of `text` on one line, rounded up to a whole point.
    public static func width(_ text: String, style: BarTextStyle) -> CGFloat {
        width(text, font: font(for: style))
    }

    static func width(_ text: String, font: NSFont) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        return ceil(NSAttributedString(string: text, attributes: [.font: font]).size().width)
    }

    private static let pageFont = NSFont.systemFont(ofSize: fontSize, weight: .medium)
    private static let currentFont = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
    private static let regularFont = NSFont.systemFont(ofSize: fontSize, weight: .regular)

    /// The count badge on a collapsed site.
    static let badgeFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
}
