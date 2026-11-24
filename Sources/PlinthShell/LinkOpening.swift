import Foundation

// Peek: ⇧-click a link to see it in a card over the page without leaving it, as in the Mac app.
// Chromium has already turned the click into a window-open disposition by the time Plinth hears of it,
// and ⇧-click is the one that arrives as "new window" with a user gesture (⌘-click is a background tab,
// a scripted window.open with features a popup). Shared by the Chromium-based apps. Pure.

/// How a page asked for a link to open, without the bridge's Objective-C type.
public enum LinkDisposition: Equatable, Sendable {
    case currentTab, foregroundTab, backgroundTab, newWindow, popup

}

/// What Plinth does with a link that asked for somewhere new to open.
public enum LinkOpening: Equatable, Sendable {
    /// A scripted popup (a sign-in window) keeps its own small window and its opener.
    case popup
    /// ⇧-click: preview it in a peek card.
    case peek
    /// A new page in the window; `background` for ⌘-click and middle-click.
    case page(background: Bool)

    /// The schemes a peek card shows, as on the Mac (`WebViewPool.reportedSchemes`).
    public static let peekSchemes: Set<String> = ["http", "https", "file"]

    public static func decide(_ disposition: LinkDisposition, userGesture: Bool, url: URL?) -> LinkOpening {
        switch disposition {
        case .popup:
            return .popup
        case .newWindow where userGesture && peekSchemes.contains(url?.scheme?.lowercased() ?? ""):
            return .peek
        case .backgroundTab:
            return .page(background: true)
        default:
            return .page(background: false)
        }
    }
}

