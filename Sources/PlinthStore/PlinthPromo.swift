import Foundation
import PlinthModel

/// The Plinth site as the very first page. One definition for every platform.
///
/// A brand-new profile opens the site once, as its first page, under the welcome guide. Typing
/// "plinth", "getplinth" or "get" suggests the site through `PopularSites` (it is listed there like any
/// well-known site, with no history needed, and not twice when the history has it). Nothing is shown
/// for it when nothing is typed.
public enum PlinthPromo {
    public static let title = "Plinth"
    public static let host = "getplinth.dev"
    public static let url = URL(string: "https://getplinth.dev")!

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
