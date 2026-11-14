import Foundation
import WebKit

/// What the page script reports. Decoded defensively: the message body comes from a web page's process.
public enum PageEvent: Equatable, Sendable {
    /// `username` is what is already typed in the user name field, if there is one.
    case focus(token: Int, isNewPassword: Bool, action: String?, username: String = "")
    /// A user name field on a sign-in step that has no password field yet (two-step sign-in).
    case focusIdentifier(token: Int, action: String?)
    /// The first step of a two-step sign-in was submitted.
    case identifier(username: String)
    case submit(username: String, password: String, isNewPassword: Bool, action: String?)
    case loaded(hasPassword: Bool)
    case settled

    public init?(body: Any) {
        guard let dict = body as? [String: Any], let kind = dict["kind"] as? String else { return nil }
        let action = dict["action"] as? String
        switch kind {
        case "focus":
            guard let token = (dict["token"] as? NSNumber)?.intValue else { return nil }
            let typed = dict["username"] as? String ?? ""
            guard typed.count <= 512 else { return nil }
            self = .focus(token: token, isNewPassword: dict["isNewPassword"] as? Bool ?? false, action: action, username: typed)
        case "focusIdentifier":
            guard let token = (dict["token"] as? NSNumber)?.intValue else { return nil }
            self = .focusIdentifier(token: token, action: action)
        case "identifier":
            guard let u = dict["username"] as? String, !u.isEmpty, u.count <= 512 else { return nil }
            self = .identifier(username: u)
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
///  - fill only logins saved for the origin of the frame the field is in (`www.` is ignored and an http login may fill
///    its https page; never the other way, never other hosts or ports), only for a form whose action stays on that
///    origin, only after the person clicked into the field;
///  - one match fills at once, several ask which (a user name already typed, or chosen on the first step of a
///    two-step sign-in, picks the match; a different typed name is never overwritten); "new password" fields are never filled;
///  - after a submit, offer to save or update only once the login looks successful (the form is gone), never on
///    sites the person said "never" for, never with an empty user name or password, never in a private window;
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
        /// The saved login this replaces when it moves to another origin (an http login saved again on https).
        var replacing: LoginKey?
        var isMainFrame: Bool
        weak var webView: WKWebView?
        var at: Date
    }
    var pending: Pending?

    /// Who was signing in on the first step of a two-step sign-in; used when the password step has no user name field.
    struct Identifier {
        var origin: WebOrigin
        var username: String
        weak var webView: WKWebView?
        var at: Date
    }
    var identifier: Identifier?
    static let identifierLifetime: TimeInterval = 600
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
        guard let event = PageEvent(body: message.body) else { return }
        let so = message.frameInfo.securityOrigin
        guard let origin = WebOrigin(scheme: so.protocol, host: so.host, port: so.port) else { return }
        let webView = message.webView
        let frame = message.frameInfo
        let isMainFrame = frame.isMainFrame
        Task { @MainActor in
            await self.handle(event, origin: origin, webView: webView, isMainFrame: isMainFrame) { token, username, password in
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

    public func handle(_ event: PageEvent, origin: WebOrigin, webView: WKWebView?, isMainFrame: Bool = true,
                       fill: @escaping (_ token: Int, _ username: String, _ password: String) async -> Void) async {
        switch event {
        case .focus(let token, let isNewPassword, let action, let typed):
            guard !isNewPassword, WebOrigin.formActionAllowed(page: origin, action: action) else { return }
            guard var matches = try? vault.logins(for: origin), !matches.isEmpty else { return }
            if !typed.isEmpty {
                // Never overwrite a user name the person typed: fill only a login saved for that name.
                matches = matches.filter { $0.username.caseInsensitiveCompare(typed) == .orderedSame }
            } else if let who = recentIdentifier(origin: origin, webView: webView) {
                let narrowed = matches.filter { $0.username.caseInsensitiveCompare(who) == .orderedSame }
                if !narrowed.isEmpty { matches = narrowed }
            }
            guard !matches.isEmpty else { return }
            let chosen = matches.count == 1 ? matches[0] : await prompts.choose(from: matches, origin: origin, in: webView)
            guard let chosen, WebOrigin.mayFill(saved: chosen.origin, into: origin),
                  let secret = try? vault.password(for: chosen.key) else { return }
            await fill(token, chosen.username, secret)

        case .focusIdentifier(let token, let action):
            guard WebOrigin.formActionAllowed(page: origin, action: action),
                  let matches = try? vault.logins(for: origin), !matches.isEmpty else { return }
            let chosen = matches.count == 1 ? matches[0] : await prompts.choose(from: matches, origin: origin, in: webView)
            guard let chosen, WebOrigin.mayFill(saved: chosen.origin, into: origin) else { return }
            // Only the user name: the password step that follows finds this login again.
            identifier = Identifier(origin: origin, username: chosen.username, webView: webView, at: now())
            await fill(token, chosen.username, "")

        case .identifier(let username):
            guard !Self.isPrivate(webView) else { return }
            identifier = Identifier(origin: origin, username: username, webView: webView, at: now())

        case .submit(let typed, let password, _, let action):
            // A private window offers to fill but never to save.
            guard !Self.isPrivate(webView), preferences.offerToSave, !password.isEmpty, !preferences.isNeverSaved(origin),
                  WebOrigin.formActionAllowed(page: origin, action: action) else { return }
            let username = typed.isEmpty ? (recentIdentifier(origin: origin, webView: webView) ?? "") : typed
            guard !username.isEmpty else { return }
            // The same login may be saved under www., or under http before the site moved to https.
            let found = (try? vault.logins(for: origin))?.first { $0.username == username }
            let existing = found.flatMap { try? vault.password(for: $0.key) }
            if existing == password { pending = nil; return }
            let target = found.map { $0.origin.scheme == origin.scheme ? $0.origin : origin } ?? origin
            let replacing = found.flatMap { $0.origin == target ? nil : $0.key }
            pending = Pending(origin: target, username: username, password: password, isUpdate: found != nil, replacing: replacing,
                              isMainFrame: isMainFrame, webView: webView, at: now())

        case .loaded(let hasPassword):
            // A page that still asks for a password right after a submit means the login failed.
            guard let p = pending, isMainFrame || WebOrigin.mayFill(saved: p.origin, into: origin) else { return }
            if hasPassword { pending = nil } else { await offerPending(webView: webView) }

        case .settled:
            guard let p = pending, isMainFrame || WebOrigin.mayFill(saved: p.origin, into: origin) else { return }
            await offerPending(webView: webView)
        }
    }

    private func recentIdentifier(origin: WebOrigin, webView: WKWebView?) -> String? {
        guard let i = identifier, now().timeIntervalSince(i.at) < Self.identifierLifetime, i.webView === webView,
              WebOrigin.mayFill(saved: i.origin, into: origin) || WebOrigin.mayFill(saved: origin, into: i.origin) else { return nil }
        return i.username
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
            let login = Login(origin: p.origin, username: p.username, password: p.password, created: now())
            if let old = p.replacing { try? vault.replace(old, with: login) } else { try? vault.save(login) }
            savedHook?()
        case .notNow: break
        case .never: preferences.addNever(p.origin)
        }
    }

    /// Called after a login is saved so the Settings list can refresh.
    public var savedHook: (@MainActor () -> Void)?
}
