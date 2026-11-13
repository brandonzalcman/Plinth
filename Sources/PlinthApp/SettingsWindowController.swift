import AppKit
import SwiftUI
import Observation

/// Which section the Settings window shows. Shared between the window controller and the sidebar.
@MainActor
@Observable
final class SettingsNavigation {
    var selected: SettingsSection = .general
}

/// The window itself: Escape closes it, like the other Plinth panels.
final class SettingsWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) { performClose(sender) }
}

/// The shared Settings window (Plinth ▸ Settings…, ⌘,).
@MainActor
final class SettingsWindowController: NSWindowController {
    private let app: AppController
    private let navigation = SettingsNavigation()
    private var placed = false
    static let defaultSize = NSSize(width: 760, height: 560)

    convenience init(app: AppController) {
        let window = SettingsWindow(contentRect: NSRect(origin: .zero, size: Self.defaultSize),
                                    styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                    backing: .buffered, defer: false)
        self.init(window: window, app: app)
    }

    private init(window: NSWindow, app: AppController) {
        self.app = app
        super.init(window: window)
        window.title = "Settings"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.minSize = Self.defaultSize

        let glass = NSVisualEffectView()
        glass.material = .underWindowBackground
        glass.blendingMode = .behindWindow
        glass.state = .followsWindowActiveState
        let host = NSHostingView(rootView: SettingsRoot(app: app, navigation: navigation))
        host.translatesAutoresizingMaskIntoConstraints = false
        glass.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: glass.leadingAnchor), host.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
            host.topAnchor.constraint(equalTo: glass.topAnchor), host.bottomAnchor.constraint(equalTo: glass.bottomAnchor),
        ])
        window.contentView = glass
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Shows the section with this stable id: general, privacy, downloads, startup, appearance, ai, import.
    func select(section id: String) {
        if let section = SettingsSection(rawValue: id) { navigation.selected = section }
    }

    func show() {
        if !placed { window?.center(); placed = true }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Self.captureIfRequested(window)
    }

    // MARK: Verification hooks (inert unless the environment variables are set)

    /// PLINTH_OPEN_SETTINGS=1 opens the window shortly after launch; PLINTH_SETTINGS_SECTION=<id> picks the section and
    /// PLINTH_SETTINGS_SHOT=<path> saves a screenshot of the window 1.5 s after it is shown.
    /// Called from `MainMenu.build()`, which runs during launch.
    static func installLaunchHooks() {
        guard ProcessInfo.processInfo.environment["PLINTH_OPEN_SETTINGS"] == "1" else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { AppController.shared?.menuSettings(nil) }
        }
    }

    private static func captureIfRequested(_ window: NSWindow?) {
        guard let path = ProcessInfo.processInfo.environment["PLINTH_SETTINGS_SHOT"], let window else { return }
        switch ProcessInfo.processInfo.environment["PLINTH_SETTINGS_APPEARANCE"] {
        case "dark": window.appearance = NSAppearance(named: .darkAqua)
        case "light": window.appearance = NSAppearance(named: .aqua)
        default: break
        }
        let number = window.windowNumber
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            task.arguments = ["-x", "-o", "-l", String(number), path]
            try? task.run()
            task.waitUntilExit()
            NSLog("Plinth settings screenshot: %@ (status %d)", path, task.terminationStatus)
        }
    }
}

extension AppController {
    @objc func menuSettings(_ sender: Any?) {
        if settingsWindow == nil { settingsWindow = SettingsWindowController(app: self) }
        if let section = ProcessInfo.processInfo.environment["PLINTH_SETTINGS_SECTION"] { settingsWindow?.select(section: section) }
        settingsWindow?.show()
    }
}
