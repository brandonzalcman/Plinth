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
        guard !text.isEmpty else { return 0 }
        // The engine asks for the same labels again and again (every resize step, every collapse
        // pass), and measuring an attributed string is the expensive part. Main thread only.
        let key = Key(text: text, style: style)
        if let hit = cache[key] { return hit }
        let measured = width(text, font: font(for: style))
        if cache.count >= cacheLimit { cache.removeAll(keepingCapacity: true) }
        cache[key] = measured
        return measured
    }

    private struct Key: Hashable { var text: String; var style: BarTextStyle }
    private static let cacheLimit = 4096
    nonisolated(unsafe) private static var cache: [Key: CGFloat] = [:]

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
