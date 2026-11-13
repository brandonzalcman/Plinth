import Foundation

/// What opening a new page does, decided from the settings.
public enum NewPageAction: Equatable, Sendable {
    /// Open the command bar so the user can type an address or a search.
    case commandBar
    /// Open this URL as a page.
    case open(URL)

    public static let blankURL = URL(string: "about:blank")!

    public static func decide(_ settings: AppSettings) -> NewPageAction {
        switch settings.newPage {
        case .commandBar: return .commandBar
        case .blank: return .open(blankURL)
        case .homepage:
            if let url = settings.homepageURL { return .open(url) }
            return .commandBar
        }
    }
}
