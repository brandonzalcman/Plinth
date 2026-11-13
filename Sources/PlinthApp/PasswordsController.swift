import AppKit
import WebKit
import Observation
import PlinthWeb
import PlinthPasswords

/// The built-in password manager at the app level: the Keychain vault, the page capture/fill coordinator wired into
/// the web views, and the native prompts ("Save password?", the account picker). Settings reads and edits through `model`.
@MainActor
final class PasswordsController: PasswordPrompting {
    let vault: PasswordVault
    let preferences: PasswordPreferences
    let authenticator: Authenticating
    let model: PasswordsModel
    private var coordinator: PasswordsCoordinator!

    /// `testing` (a throwaway PLINTH_STORAGE profile) keeps logins out of the real ones in the Keychain.
    init(pool: WebViewPool, storageDirectory: URL, testing: Bool, authenticator: Authenticating = DeviceAuthenticator()) {
        let vault = KeychainVault(service: testing ? "app.plinth.passwords.test" : "app.plinth.passwords")
        self.vault = vault
        self.preferences = PasswordPreferences(storageDirectory: storageDirectory)
        self.authenticator = authenticator
        self.model = PasswordsModel(vault: vault)
        let coordinator = PasswordsCoordinator(vault: vault, preferences: preferences, prompts: self)
        coordinator.savedHook = { [model] in model.reload() }
        self.coordinator = coordinator
        pool.extraUserScripts = [PasswordPageScript.userScript()]
        pool.addMessageHandler(coordinator, name: PasswordPageScript.handlerName, world: PasswordPageScript.world)
    }

    // MARK: Test launches (PLINTH_STEPS "pw ..."; only meaningful with a throwaway PLINTH_STORAGE)

    private var debugAnswer: SaveChoice?

    /// pw add <url> <user> <password> | pw answer <save|notnow|never> | pw list | pw show <url> <user> | pw clear
    func debug(_ arg: String) {
        guard ProcessInfo.processInfo.environment["PLINTH_STORAGE"] != nil else { return }
        let p = arg.split(separator: " ").map(String.init)
        switch p.first {
        case "add" where p.count == 4:
            if let origin = WebOrigin(string: p[1]) { try? vault.save(Login(origin: origin, username: p[2], password: p[3])) }
            model.reload()
        case "answer" where p.count == 2:
            debugAnswer = ["save": .save, "notnow": .notNow, "never": .never][p[1]]
        case "list":
            DebugScript.log("passwords: " + ((try? vault.list()) ?? []).map { "\($0.origin) \($0.username)" }.joined(separator: " | ") + " never: \(preferences.neverSave.map(\.description))")
        case "show" where p.count == 3:
            let secret = WebOrigin(string: p[1]).flatMap { try? vault.password(for: LoginKey(origin: $0, username: p[2])) }
            DebugScript.log("password for \(p[2]): \(secret.map { "\($0.count) chars, value \($0)" } ?? "none")")
        case "clear":
            for login in (try? vault.list()) ?? [] { try? vault.delete(login.key) }
            model.reload()
        default: break
        }
    }

    // MARK: PasswordPrompting

    func confirmSave(origin: WebOrigin, username: String, isUpdate: Bool, in webView: WKWebView?) async -> SaveChoice {
        if let debugAnswer {
            DebugScript.log("save prompt: \(origin) \(username) update=\(isUpdate) -> \(debugAnswer)")
            return debugAnswer
        }
        guard let window = webView?.window else { return .notNow }
        let alert = NSAlert()
        alert.messageText = isUpdate ? "Update the password for \(origin.displayHost)?" : "Save the password for \(origin.displayHost)?"
        alert.informativeText = "User name: \(username)\nPlinth keeps it in your Mac's Keychain."
        alert.addButton(withTitle: isUpdate ? "Update" : "Save")
        alert.addButton(withTitle: "Not Now")
        alert.addButton(withTitle: "Never for This Site")
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { response in
                switch response {
                case .alertFirstButtonReturn: continuation.resume(returning: .save)
                case .alertSecondButtonReturn: continuation.resume(returning: .notNow)
                default: continuation.resume(returning: .never)
                }
            }
        }
    }

    func choose(from logins: [LoginSummary], origin: WebOrigin, in webView: WKWebView?) async -> LoginSummary? {
        guard let webView, let window = webView.window else { return nil }
        let menu = NSMenu(title: "Passwords")
        menu.addItem(withTitle: "Fill a password for \(origin.displayHost)", action: nil, keyEquivalent: "").isEnabled = false
        let picker = MenuPicker()
        for login in logins {
            let item = NSMenuItem(title: login.username.isEmpty ? "(no user name)" : login.username, action: #selector(MenuPicker.pick(_:)), keyEquivalent: "")
            item.target = picker
            item.representedObject = login.id
            menu.addItem(item)
        }
        // Shown at the pointer, over the page; returns once the person picks or dismisses it.
        let point = webView.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        menu.popUp(positioning: nil, at: point, in: webView)
        return logins.first { $0.id == picker.chosen }
    }

    // MARK: Clipboard

    /// Copies a password marked as concealed (clipboard managers skip it) and clears it after a minute if nothing else was copied.
    func copyToClipboard(_ secret: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(secret, forType: .string)
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        let count = pasteboard.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            if NSPasteboard.general.changeCount == count { NSPasteboard.general.clearContents() }
        }
    }
}

private final class MenuPicker: NSObject {
    var chosen: String?
    @objc func pick(_ sender: NSMenuItem) { chosen = sender.representedObject as? String }
}

/// What the Settings list shows: logins without their passwords.
@MainActor
@Observable
final class PasswordsModel {
    private(set) var logins: [LoginSummary] = []
    private(set) var error: String?
    @ObservationIgnored private let vault: PasswordVault

    init(vault: PasswordVault) {
        self.vault = vault
        reload()
    }

    func reload() {
        do { logins = try vault.list(); error = nil }
        catch { self.error = "Plinth couldn't read the Keychain right now." }
    }
}

extension AppController {
    /// Starts the password manager. Called once at launch, after the web view pool exists.
    func setUpPasswords() {
        let testing = ProcessInfo.processInfo.environment["PLINTH_STORAGE"] != nil
        passwords = PasswordsController(pool: pool, storageDirectory: storageDirectory, testing: testing)
    }
}
