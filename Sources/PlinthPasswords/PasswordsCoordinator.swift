import Foundation
import WebKit

/// What the page script reports. Decoded defensively: the message body comes from a web page's process.
public enum PageEvent: Equatable, Sendable {
    case focus(token: Int, isNewPassword: Bool, action: String?)
    case submit(username: String, password: String, isNewPassword: Bool, action: String?)
    case loaded(hasPassword: Bool)
    case settled

    public init?(body: Any) {
        guard let dict = body as? [String: Any], let kind = dict["kind"] as? String else { return nil }
        let action = dict["action"] as? String
        switch kind {
        case "focus":
            guard let token = (dict["token"] as? NSNumber)?.intValue else { return nil }
            self = .focus(token: token, isNewPassword: dict["isNewPassword"] as? Bool ?? false, action: action)
        case "submit":
            guard let u = dict["username"] as? String, let p = dict["password"] as? String, u.count <= 512, p.count <= 4096 else { return nil }
            self = .submit(username: u, password: p, isNewPassword: dict["isNewPassword"] as? Bool ?? false, action: action)
        case "loaded": self = .loaded(hasPassword: dict["hasPassword"] as? Bool ?? false)
        case "settled": self = .settled
        default: return nil
        }
    }
}

public enum SaveChoice: Equatable, Sendable { case save, notNow, never }

/// The native UI the coordinator asks. Implemented by the app; tests use a fake.
@MainActor
public protocol PasswordPrompting: AnyObject {
    func confirmSave(origin: WebOrigin, username: String, isUpdate: Bool, in webView: WKWebView?) async -> SaveChoice
    /// Several logins match: let the person pick one (nil = none).
    func choose(from logins: [LoginSummary], origin: WebOrigin, in webView: WKWebView?) async -> LoginSummary?
}

/// Receives the page script's messages and applies the rules:
///  - fill only logins saved for exactly the page's origin (never across http/https, hosts or ports), only for a
///    form whose action stays on that origin, only after the person clicked into the field, only in the main frame;
///  - one match fills at once, several ask which; "new password" fields are never filled;
///  - after a submit, offer to save or update only once the login looks successful (the form is gone), never on
///    sites the person said "never" for, never with an empty user name or password;
///  - passwords are never logged and cross the page boundary only as the argument of the fill call.
@MainActor
public final class PasswordsCoordinator: NSObject, WKScriptMessageHandler {
    private let vault: PasswordVault
    private let preferences: PasswordPreferences
    private let prompts: PasswordPrompting
    private let now: () -> Date

    struct Pending {
        var origin: WebOrigin
        var username: String
        var password: String
        var isUpdate: Bool
        weak var webView: WKWebView?
        var at: Date
    }
    var pending: Pending?
    private var prompting = false
    static let pendingLifetime: TimeInterval = 60

    public init(vault: PasswordVault, preferences: PasswordPreferences, prompts: PasswordPrompting, now: @escaping () -> Date = Date.init) {
        self.vault = vault
        self.preferences = preferences
        self.prompts = prompts
        self.now = now
        super.init()
    }

    // MARK: WebKit entry point

    public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let event = PageEvent(body: message.body) else { return }
        let so = message.frameInfo.securityOrigin
        guard let origin = WebOrigin(scheme: so.protocol, host: so.host, port: so.port) else { return }
        let webView = message.webView
        let frame = message.frameInfo
        Task { @MainActor in
            await self.handle(event, origin: origin, webView: webView) { token, username, password in
                guard let webView else { return }
                _ = try? await webView.callAsyncJavaScript(PasswordPageScript.fillBody,
                                                           arguments: ["token": token, "username": username, "password": password],
                                                           in: frame, contentWorld: PasswordPageScript.world)
            }
        }
    }

    /// A view whose data store is non-persistent belongs to a private window (or a popup or peek from one).
    static func isPrivate(_ webView: WKWebView?) -> Bool {
        webView.map { !$0.configuration.websiteDataStore.isPersistent } ?? false
    }

    // MARK: Rules (testable without WebKit)

    public func handle(_ event: PageEvent, origin: WebOrigin, webView: WKWebView?,
                       fill: @escaping (_ token: Int, _ username: String, _ password: String) async -> Void) async {
        switch event {
        case .focus(let token, let isNewPassword, let action):
            guard !isNewPassword, WebOrigin.formActionAllowed(page: origin, action: action) else { return }
            guard let matches = try? vault.logins(for: origin), !matches.isEmpty else { return }
            let chosen = matches.count == 1 ? matches[0] : await prompts.choose(from: matches, origin: origin, in: webView)
            guard let chosen, WebOrigin.mayFill(saved: chosen.origin, into: origin),
                  let secret = try? vault.password(for: chosen.key) else { return }
            await fill(token, chosen.username, secret)

        case .submit(let username, let password, _, let action):
            // A private window offers to fill but never to save.
            guard !Self.isPrivate(webView), preferences.offerToSave, !username.isEmpty, !password.isEmpty, !preferences.isNeverSaved(origin),
                  WebOrigin.formActionAllowed(page: origin, action: action) else { return }
            let key = LoginKey(origin: origin, username: username)
            let existing = try? vault.password(for: key)
            if existing == password { pending = nil; return }
            pending = Pending(origin: origin, username: username, password: password, isUpdate: existing != nil, webView: webView, at: now())

        case .loaded(let hasPassword):
            // A page that still asks for a password right after a submit means the login failed.
            if hasPassword { pending = nil } else { await offerPending(webView: webView) }

        case .settled:
            await offerPending(webView: webView)
        }
    }

    private func offerPending(webView: WKWebView?) async {
        guard let p = pending, !prompting, now().timeIntervalSince(p.at) < Self.pendingLifetime,
              p.webView == nil || p.webView === webView else { return }
        pending = nil
        guard preferences.offerToSave, !preferences.isNeverSaved(p.origin) else { return }
        prompting = true
        let choice = await prompts.confirmSave(origin: p.origin, username: p.username, isUpdate: p.isUpdate, in: webView)
        prompting = false
        switch choice {
        case .save:
            try? vault.save(Login(origin: p.origin, username: p.username, password: p.password, created: now()))
            savedHook?()
        case .notNow: break
        case .never: preferences.addNever(p.origin)
        }
    }

    /// Called after a login is saved so the Settings list can refresh.
    public var savedHook: (@MainActor () -> Void)?
}
