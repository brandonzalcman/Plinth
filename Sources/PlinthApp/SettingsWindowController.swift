import AppKit

/// The shared Settings window. Owned by the settings-UI agent; this is the stub.
@MainActor
final class SettingsWindowController: NSWindowController {
    convenience init(app: AppController) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Settings"
        self.init(window: window)
    }

    func show() {
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

extension AppController {
    @objc func menuSettings(_ sender: Any?) {
        if settingsWindow == nil { settingsWindow = SettingsWindowController(app: self) }
        settingsWindow?.show()
    }
}
