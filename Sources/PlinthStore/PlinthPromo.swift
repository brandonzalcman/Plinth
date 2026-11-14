import Foundation

/// The Plinth site as a suggestion, and as the very first page. One definition for every platform.
///
/// - **Promo row.** With nothing typed in the command bar, one row offers getplinth.dev. It comes
///   last, after the suggested pages, so it never pushes a real suggestion out. It stops appearing
///   once the user has visited the site `hideAfterVisits` times (they know it by then). There is no
///   dismiss button and no stored flag: the history is the only state. It is a fixed row, so it also
///   shows in private windows.
/// - **First page.** A brand-new profile opens the site once, as its first page, under the welcome
///   guide.
public enum PlinthPromo {
    /// `SearchResult.id` of the promo row, so a UI can label it.
    public static let resultID = "promo-plinth"
    public static let title = "Plinth"
    public static let host = "getplinth.dev"
    public static let url = URL(string: "https://getplinth.dev")!
    /// The row's second line.
    public static let subtitle = "getplinth.dev"
    /// The row disappears from the empty command bar after this many visits to the site.
    public static let hideAfterVisits = 3

    /// Whether the promo row is listed, given how many times the history shows the site visited.
    public static func isShown(visits: Int) -> Bool { visits < hideAfterVisits }

    /// True for the Plinth site's own host (with or without "www.").
    public static func isPlinthHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == Self.host || host == "www." + Self.host
    }

    /// The page a brand-new profile opens first. Nil on every later launch, and whenever the
    /// launch already says what to open (a test or scripted launch, a restored session).
    /// `profileHadWindows` is whether the profile had any windows saved before this launch;
    /// `hasCompletedOnboarding` is the welcome-guide flag. A new profile has neither.
    public static func firstLaunchURL(hasCompletedOnboarding: Bool, profileHadWindows: Bool,
                                      hasExplicitURLs: Bool = false) -> URL? {
        guard !hasCompletedOnboarding, !profileHadWindows, !hasExplicitURLs else { return nil }
        return url
    }
}
