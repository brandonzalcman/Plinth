import Foundation

/// What to do when a page's web content process ends (a crash, or the system reclaiming it).
///
/// Without a handler WebKit reloads the page by itself and the window background shows until it
/// paints. So the pool decides: a shown page reloads now, a hidden one waits until it is shown
/// (so a memory-pressure sweep does not reload every background tab at once), and a page whose
/// process ended again straight after a reload is left alone rather than looping.
public enum CrashRecovery {
    public enum Action: Equatable, Sendable {
        case reloadNow
        case reloadWhenShown
        case leaveAsIs
    }

    public static func action(isShown: Bool, alreadyReloaded: Bool) -> Action {
        if alreadyReloaded { return .leaveAsIs }
        return isShown ? .reloadNow : .reloadWhenShown
    }
}
