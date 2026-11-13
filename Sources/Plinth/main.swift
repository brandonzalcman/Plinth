import AppKit

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let controller = AppController()
    app.delegate = controller
    app.setActivationPolicy(.regular)
    // The delegate is held weakly by NSApplication; keep it alive for the life of the process.
    AppController.shared = controller
    app.run()
}
