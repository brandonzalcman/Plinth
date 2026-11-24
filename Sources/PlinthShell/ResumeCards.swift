import Foundation
import PlinthModel

// The "where you left off" card shown when a site comes back from the shelf. Pure.

/// The card's content, kept on the window's `WindowChrome`.
public struct ResumeCard: Equatable {
    public var page: PageID
    public var key: SiteKey
    public var siteName: String
    public var pageName: String
    public var summary: String?
    public var isLoading: Bool
}

/// Whether a restore shows a card, and what kind. Pure, so it can be tested.
public enum ResumeCardDecision: Equatable {
    case none
    /// Summaries are off: the card only marks where you left off, briefly.
    case placeOnly
    /// The card shows a placeholder while the page is read and summed up.
    case summarise

    /// A card shows only for the page now selected, and only if it is one of the pages that just
    /// came back. With summaries on it needs the model to be available; with them off, the AI
    /// switch still has to be on (as on the Mac). Never in a private window.
    public static func decide(selected: PageID?, restored: [PageID], isPrivate: Bool, summariesEnabled: Bool,
                       aiEnabled: Bool, aiAvailable: Bool) -> ResumeCardDecision {
        guard let selected, restored.contains(selected), !isPrivate else { return .none }
        if summariesEnabled { return aiAvailable ? .summarise : .none }
        return aiEnabled ? .placeOnly : .none
    }

    /// How long a card stays: a place-only card, and a card once its summary is in.
    public static let placeOnlyDuration: Duration = .seconds(8)
    public static let summaryDuration: Duration = .seconds(14)
    /// A restored page loads again from scratch; it is read once loaded, or after `readAnywayAfter`
    /// tries of a second each, giving up after `attempts`.
    public static let attempts = 8
    public static let readAnywayAfter = 4
}
