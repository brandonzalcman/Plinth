import Foundation
import PlinthSettings

// The first-launch guide for the Chromium-based builds. The Mac app's `OnboardingFlow` has its own fixed
// cards (the floating bar, the command bar, the shelf), so this build keeps a small flow of its own
// with the same shape: an opening animation, then the cards, then done.

/// The guide's cards, in order.
public enum WelcomeCard: String, CaseIterable, Sendable {
    /// Pages in the bottom dock or the sidebar, chosen right on the card.
    case layout
    /// Pins on the plinth, pin folders as icons or a list, and a colour for every site.
    case sidebar
    /// The collapsed rail that opens on hover, and dragging one page onto another to split.
    case railAndSplit
    /// Pages fade, go to the shelf, and come back with a resume card.
    case fading
    /// Searching history and the shelf by meaning, on this Mac.
    case meaning
    /// Chrome extensions from the Web Store, under the puzzle piece; sign-in windows float.
    case extensions
    /// Points & Levels.
    case points
    /// Import from other browsers, passwords included; the last card.
    case getStarted
}

/// Where the guide stands. Pure state so it can be tested; the views only draw it.
public struct WelcomeFlow: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case intro
        case guide(Int)
        case finished
    }

    public private(set) var phase: Phase = .intro
    public static let cards = WelcomeCard.allCases

    public init() {}

    /// Starts at a given card (or the intro with nil); out-of-range indexes clamp.
    public init(startingAtCard index: Int?) {
        if let index { phase = .guide(min(max(index, 0), Self.cards.count - 1)) }
    }

    public var currentCard: WelcomeCard? { cardIndex.map { Self.cards[$0] } }

    public var cardIndex: Int? {
        if case .guide(let i) = phase { return i }
        return nil
    }

    public var isFirstCard: Bool { cardIndex == 0 }
    public var isLastCard: Bool { cardIndex == Self.cards.count - 1 }
    public var isFinished: Bool { phase == .finished }

    /// The animation ended or was skipped.
    public mutating func introDone() { if phase == .intro { phase = .guide(0) } }

    /// "Next"; on the last card this finishes ("Start browsing").
    public mutating func next() {
        switch phase {
        case .intro: phase = .guide(0)
        case .guide(let i): phase = i + 1 < Self.cards.count ? .guide(i + 1) : .finished
        case .finished: break
        }
    }

    /// "Back"; does nothing on the first card.
    public mutating func back() {
        if case .guide(let i) = phase, i > 0 { phase = .guide(i - 1) }
    }

    /// Jumps to a card (a click on its step dot). Ignored once finished or out of range.
    public mutating func go(to index: Int) {
        guard phase != .finished, Self.cards.indices.contains(index) else { return }
        phase = .guide(index)
    }

    /// Skip from anywhere.
    public mutating func skip() { phase = .finished }
}

/// Whether the guide opens at launch. Pure.
public enum WelcomeLaunch: Equatable {
    /// Open the guide.
    case show
    /// Don't show it, and remember it as seen: a profile from before the guide existed.
    case markSeen
    /// Leave everything as it is.
    case nothing

    /// A new profile gets the guide once; a profile that already had windows predates it and is marked
    /// as seen, the same rule as the Mac app (`OnboardingFlow.shouldShowAtLaunch`).
    ///
    /// Test launches: `override` is `PLINTH_WELCOME` ("1" always shows it, "0" never does), and a
    /// scripted launch (`PLINTH_STEPS`) leaves it out unless asked for, so scripted checks of other
    /// features aren't covered by it. Neither of those marks it as seen.
    public static func decide(hasCompleted: Bool, profileHadWindows: Bool, override: String?, scripted: Bool) -> WelcomeLaunch {
        switch override {
        case "1": return .show
        case "0": return .nothing
        default: break
        }
        if scripted { return .nothing }
        if OnboardingFlow.shouldShowAtLaunch(hasCompleted: hasCompleted, profileHadWindows: profileHadWindows) { return .show }
        return hasCompleted ? .nothing : .markSeen
    }
}

// MARK: - Words

public extension WelcomeCard {
    public var title: String {
        switch self {
        case .layout: "Pages in the dock, or down the side"
        case .sidebar: "Pins stand on the plinth"
        case .railAndSplit: "Fold it away, split it up"
        case .fading: "Pages fade, then rest on the shelf"
        case .meaning: "Search by meaning"
        case .extensions: "Your Chrome extensions"
        case .points: "Points & Levels"
        case .getStarted: "Make yourself at home"
        }
    }

    public var message: String {
        switch self {
        case .layout:
            "Keep your pages on a dock along the bottom, or list them in a sidebar on the left. Pick one now; you can switch any time from the View menu or Settings."
        case .sidebar:
            "Pin the sites you live in and they stand on the plinth at the top. Drop one pin on another to make a folder, shown as icons or as a list. Every site wears its own colour, taken from its icon."
        case .railAndSplit:
            "Collapse the sidebar to a rail of icons; rest the pointer on it and the whole sidebar opens over the page. Drag one page onto another to see the two side by side."
        case .fading:
            "Pages you leave alone grow faint, then go to the shelf, so the list stays short and nothing is lost. Bring one back and a card reminds you where you left off."
        case .meaning:
            "Search the shelf and your history for \u{201C}that article about sourdough\u{201D} and Plinth finds it. The AI runs on your Mac, so what you read never leaves it."
        case .extensions:
            "Add extensions from the Chrome Web Store; they live under the puzzle-piece button. Sign-in windows they open float over Plinth until you\u{2019}re done."
        case .points:
            "Using Plinth earns points: each day you browse, your first pin, your first split. Every level unlocks a new app icon and accent colour."
        case .getStarted:
            "Bring your bookmarks, history and passwords from Safari, Chrome, Arc, Firefox and others. You can also do it later in Settings."
        }
    }
}
