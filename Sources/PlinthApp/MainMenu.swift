import AppKit

/// The menu bar is where every keyboard shortcut lives; Plinth has no toolbar.
@MainActor
enum MainMenu {
    static let splitMenuTitle = "Split View With"
    static let remoteMenuTitle = "Pages on Other Macs"

    static func build() -> NSMenu {
        let main = NSMenu()
        SettingsWindowController.installLaunchHooks()

        let app = submenu(main, "Plinth")
        app.addItem(withTitle: "About Plinth", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        if AppController.shared?.checkForUpdates != nil {
            add(app, "Check for Updates…", #selector(AppController.menuCheckForUpdates(_:)), "")
        }
        app.addItem(.separator())
        add(app, "Show Welcome Guide", #selector(AppController.menuShowWelcome(_:)), "")
        add(app, "Settings…", #selector(AppController.menuSettings(_:)), ",")
        app.addItem(.separator())
        add(app, "Use On-Device AI", #selector(AppController.menuToggleAI(_:)), "")
        add(app, "iCloud Sync", #selector(AppController.menuToggleSync(_:)), "")
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Plinth", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Plinth", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let file = submenu(main, "File")
        add(file, "New Page", #selector(AppController.menuNewPage(_:)), "t")
        add(file, "New Window", #selector(AppController.menuNewWindow(_:)), "n")
        add(file, "Search or Enter Address…", #selector(AppController.menuOpenLocation(_:)), "l")
        file.addItem(.separator())
        add(file, "Close Page", #selector(AppController.menuClosePage(_:)), "w")
        add(file, "Close Window", #selector(AppController.menuCloseWindow(_:)), "w", [.command, .shift])
        add(file, "Reopen Closed Page", #selector(AppController.menuReopen(_:)), "t", [.command, .shift])
        file.addItem(.separator())
        add(file, "Move to Main Window", #selector(AppController.menuPromoteMini(_:)), "\r", [.command, .shift])
        dynamicSubmenu(file, remoteMenuTitle)

        let edit = submenu(main, "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        add(edit, "Find…", #selector(AppController.menuFind(_:)), "f")
        add(edit, "Ask About This Page…", #selector(AppController.menuAsk(_:)), "j")

        let view = submenu(main, "View")
        add(view, "Reload Page", #selector(AppController.menuReload(_:)), "r")
        view.addItem(.separator())
        add(view, "Zoom In", #selector(AppController.menuZoomIn(_:)), "+")
        add(view, "Zoom Out", #selector(AppController.menuZoomOut(_:)), "-")
        add(view, "Actual Size", #selector(AppController.menuZoomReset(_:)), "0")
        view.addItem(.separator())
        add(view, "Show Shelf", #selector(AppController.menuShelf(_:)), "l", [.command, .shift])
        dynamicSubmenu(view, splitMenuTitle)
        add(view, "Split View with Next Page", #selector(AppController.menuSplitWithNext(_:)), "\\", [.command, .option])
        add(view, "End Split View", #selector(AppController.menuEndSplit(_:)), "\\", [.command, .shift])
        view.addItem(.separator())
        let fullScreen = view.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]

        let go = submenu(main, "Go")
        add(go, "Back", #selector(AppController.menuBack(_:)), "[")
        add(go, "Forward", #selector(AppController.menuForward(_:)), "]")
        go.addItem(.separator())
        add(go, "Next Page", #selector(AppController.menuNextPage(_:)), "]", [.command, .shift])
        add(go, "Previous Page", #selector(AppController.menuPreviousPage(_:)), "[", [.command, .shift])
        go.addItem(.separator())
        for number in 1...9 {
            let item = add(go, "Page \(number)", #selector(AppController.menuSelectNumbered(_:)), "\(number)")
            item.tag = number
        }

        let site = submenu(main, "Site")
        add(site, "Keep on Bar", #selector(AppController.menuKeepSite(_:)), "k", [.command, .shift])
        add(site, "Pin Site", #selector(AppController.menuPinSite(_:)), "p", [.command, .shift])
        add(site, "Put Away", #selector(AppController.menuPutAway(_:)), "e", [.command, .shift])

        let window = submenu(main, "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        NSApp.windowsMenu = window

        return main
    }

    /// A submenu whose items AppController fills when it opens.
    private static func dynamicSubmenu(_ parent: NSMenu, _ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        menu.delegate = AppController.shared
        item.submenu = menu
        parent.addItem(item)
    }

    private static func submenu(_ main: NSMenu, _ title: String) -> NSMenu {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        item.submenu = menu
        main.addItem(item)
        return menu
    }

    @discardableResult
    private static func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String,
                            _ modifiers: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = AppController.shared
        return item
    }
}
