import AppKit

/// Starts Plinth. Called from the SwiftPM executable and from the Xcode app target.
public enum PlinthLauncher {
    /// - Parameter checkForUpdates: when set, the app menu gets "Check for Updates…", which calls it.
    ///   The Xcode app target passes Sparkle's updater here; the SwiftPM build has no updater.
    public static func run(checkForUpdates: (@MainActor () -> Void)? = nil) -> Never {
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            let controller = AppController()
            controller.checkForUpdates = checkForUpdates
            app.delegate = controller
            app.setActivationPolicy(.regular)
            // The delegate is held weakly by NSApplication; keep it alive for the life of the process.
            AppController.shared = controller
            app.run()
        }
        exit(0)
    }
}
