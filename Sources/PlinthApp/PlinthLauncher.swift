import AppKit

/// Starts Plinth. Called from the SwiftPM executable and from the Xcode app target.
public enum PlinthLauncher {
    public static func run() -> Never {
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            let controller = AppController()
            app.delegate = controller
            app.setActivationPolicy(.regular)
            // The delegate is held weakly by NSApplication; keep it alive for the life of the process.
            AppController.shared = controller
            app.run()
        }
        exit(0)
    }
}
