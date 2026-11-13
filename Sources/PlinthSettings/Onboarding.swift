import Foundation

/// The cards of the first-launch guide, in order.
public enum GuideCard: String, CaseIterable, Sendable {
    case bar, commandBar, shelf, getStarted
}

/// Where the first-launch experience stands: the opening animation, then the guide cards.
/// Pure state so it can be tested; the views only render it.
public struct OnboardingFlow: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case intro
        case guide(Int)
        case finished
    }

    public private(set) var phase: Phase = .intro
    public static let cards = GuideCard.allCases

    public init() {}

    /// Starts at a given card (or the intro with nil); out-of-range indexes clamp.
    public init(startingAtCard index: Int?) {
        if let index { phase = .guide(min(max(index, 0), Self.cards.count - 1)) }
    }

    public var currentCard: GuideCard? {
        if case .guide(let i) = phase { return Self.cards[i] }
        return nil
    }
    public var cardIndex: Int? {
        if case .guide(let i) = phase { return i }
        return nil
    }
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

    public mutating func back() {
        if case .guide(let i) = phase, i > 0 { phase = .guide(i - 1) }
    }

    /// Skip from anywhere.
    public mutating func skip() { phase = .finished }

    /// Whether to show the guide at launch. A profile that already has pages (an upgrade from an earlier
    /// version, which never had a flag) counts as having seen it, so only a genuinely new profile gets it.
    public static func shouldShowAtLaunch(hasCompleted: Bool, profileHadWindows: Bool) -> Bool {
        !hasCompleted && !profileHadWindows
    }
}
