import Foundation
import Testing
import WebKit
@testable import PlinthPasswords

@MainActor
private final class FakePrompts: PasswordPrompting {
    var saveChoice: SaveChoice = .save
    var pick: Int? = 0
    var savePrompts: [(origin: WebOrigin, username: String, isUpdate: Bool)] = []
    var chooseCalls = 0

    func confirmSave(origin: WebOrigin, username: String, isUpdate: Bool, in webView: WKWebView?) async -> SaveChoice {
        savePrompts.append((origin, username, isUpdate))
        return saveChoice
    }
    func choose(from logins: [LoginSummary], origin: WebOrigin, in webView: WKWebView?) async -> LoginSummary? {
        chooseCalls += 1
        return pick.map { logins[$0] }
    }
}

@MainActor
private final class Filled { var calls: [(Int, String, String)] = [] }

@MainActor
private func make(_ logins: [Login] = [], prompts: FakePrompts = FakePrompts()) -> (PasswordsCoordinator, InMemoryVault, PasswordPreferences, FakePrompts) {
    let vault = InMemoryVault(logins)
    let prefs = PasswordPreferences(storageDirectory: nil)
    return (PasswordsCoordinator(vault: vault, preferences: prefs, prompts: prompts), vault, prefs, prompts)
}

@MainActor
private func run(_ c: PasswordsCoordinator, _ event: PageEvent, at site: String) async -> [(Int, String, String)] {
    let filled = Filled()
    await c.handle(event, origin: origin(site), webView: nil) { filled.calls.append(($0, $1, $2)) }
    return filled.calls
}

private func saved(_ site: String, _ user: String, _ pw: String) -> Login {
    Login(origin: origin(site), username: user, password: pw)
}

@MainActor
@Suite struct FillTests {
    @Test func singleMatchFillsWithoutAsking() async {
        let (c, _, _, prompts) = make([saved("https://a.com", "amy", "pw1")])
        let calls = await run(c, .focus(token: 7, isNewPassword: false, action: nil), at: "https://a.com/login")
        #expect(calls.count == 1 && calls[0].0 == 7 && calls[0].1 == "amy" && calls[0].2 == "pw1")
        #expect(prompts.chooseCalls == 0)
    }

    @Test func severalMatchesAskAndFillTheChosenOne() async {
        let prompts = FakePrompts(); prompts.pick = 1
        let (c, _, _, _) = make([saved("https://a.com", "amy", "pw1"), saved("https://a.com", "bob", "pw2")], prompts: prompts)
        let calls = await run(c, .focus(token: 1, isNewPassword: false, action: nil), at: "https://a.com")
        #expect(prompts.chooseCalls == 1)
        #expect(calls.map(\.1) == ["bob"] && calls.map(\.2) == ["pw2"])
    }

    @Test func decliningTheChoiceFillsNothing() async {
        let prompts = FakePrompts(); prompts.pick = nil
        let (c, _, _, _) = make([saved("https://a.com", "amy", "pw1"), saved("https://a.com", "bob", "pw2")], prompts: prompts)
        #expect(await run(c, .focus(token: 1, isNewPassword: false, action: nil), at: "https://a.com").isEmpty)
    }

    @Test func otherOriginsNeverFill() async {
        let (c, _, _, _) = make([saved("https://a.com", "amy", "pw1")])
        for site in ["https://www.a.com", "https://evil.test", "https://a.com:8443", "https://a.com.evil.test"] {
            #expect(await run(c, .focus(token: 1, isNewPassword: false, action: nil), at: site).isEmpty, "\(site)")
        }
    }

    @Test func httpsLoginNeverFillsOnHTTPDowngrade() async {
        let (c, _, _, _) = make([saved("https://a.com", "amy", "pw1")])
        #expect(await run(c, .focus(token: 1, isNewPassword: false, action: nil), at: "http://a.com").isEmpty)
    }

    @Test func formPostingElsewhereIsNotFilled() async {
        let (c, _, _, _) = make([saved("https://a.com", "amy", "pw1")])
        #expect(await run(c, .focus(token: 1, isNewPassword: false, action: "https://evil.test/steal"), at: "https://a.com").isEmpty)
    }

    @Test func newPasswordFieldsAreNotFilled() async {
        let (c, _, _, _) = make([saved("https://a.com", "amy", "pw1")])
        #expect(await run(c, .focus(token: 1, isNewPassword: true, action: nil), at: "https://a.com").isEmpty)
    }

    @Test func vaultFailureFillsNothing() async {
        let (c, vault, _, _) = make([saved("https://a.com", "amy", "pw1")])
        vault.failure = .keychain(status: -1)
        #expect(await run(c, .focus(token: 1, isNewPassword: false, action: nil), at: "https://a.com").isEmpty)
    }
}

@MainActor
@Suite struct SaveTests {
    private func login(_ c: PasswordsCoordinator, _ user: String = "amy", _ pw: String = "pw1", site: String = "https://a.com") async {
        _ = await run(c, .submit(username: user, password: pw, isNewPassword: false, action: nil), at: site)
    }

    @Test func offersAfterTheFormGoesAwayAndSaves() async throws {
        let (c, vault, _, prompts) = make()
        await login(c)
        #expect(prompts.savePrompts.isEmpty)   // not yet: the outcome of the login is unknown
        _ = await run(c, .loaded(hasPassword: false), at: "https://a.com/home")
        #expect(prompts.savePrompts.count == 1 && prompts.savePrompts[0].username == "amy" && !prompts.savePrompts[0].isUpdate)
        #expect(try vault.password(for: LoginKey(origin: origin("https://a.com"), username: "amy")) == "pw1")
    }

    @Test func singlePageAppsSettleWithoutANavigation() async throws {
        let (c, vault, _, prompts) = make()
        await login(c)
        _ = await run(c, .settled, at: "https://a.com")
        #expect(prompts.savePrompts.count == 1)
        #expect(try vault.list().count == 1)
    }

    @Test func aPageThatStillAsksForAPasswordMeansTheLoginFailed() async throws {
        let (c, vault, _, prompts) = make()
        await login(c)
        _ = await run(c, .loaded(hasPassword: true), at: "https://a.com/login?error=1")
        _ = await run(c, .loaded(hasPassword: false), at: "https://a.com/home")
        #expect(prompts.savePrompts.isEmpty)
        #expect(try vault.list().isEmpty)
    }

    @Test func notNowSavesNothing() async throws {
        let prompts = FakePrompts(); prompts.saveChoice = .notNow
        let (c, vault, prefs, _) = make(prompts: prompts)
        await login(c)
        _ = await run(c, .settled, at: "https://a.com")
        #expect(prompts.savePrompts.count == 1)
        #expect(try vault.list().isEmpty)
        #expect(prefs.neverSave.isEmpty)
    }

    @Test func neverRemembersTheSiteAndStopsAsking() async throws {
        let prompts = FakePrompts(); prompts.saveChoice = .never
        let (c, vault, prefs, _) = make(prompts: prompts)
        await login(c)
        _ = await run(c, .settled, at: "https://a.com")
        #expect(prefs.isNeverSaved(origin("https://a.com")))
        await login(c, "bob", "pw9")
        _ = await run(c, .settled, at: "https://a.com")
        #expect(prompts.savePrompts.count == 1)
        #expect(try vault.list().isEmpty)
    }

    @Test func unchangedCredentialsAreNotOfferedAgain() async {
        let (c, _, _, prompts) = make([saved("https://a.com", "amy", "pw1")])
        await login(c)
        _ = await run(c, .settled, at: "https://a.com")
        #expect(prompts.savePrompts.isEmpty)
    }

    @Test func changedPasswordIsOfferedAsAnUpdate() async throws {
        let (c, vault, _, prompts) = make([saved("https://a.com", "amy", "old")])
        await login(c, "amy", "new")
        _ = await run(c, .settled, at: "https://a.com")
        #expect(prompts.savePrompts.count == 1 && prompts.savePrompts[0].isUpdate)
        #expect(try vault.password(for: LoginKey(origin: origin("https://a.com"), username: "amy")) == "new")
    }

    @Test func emptyUserOrPasswordIsIgnored() async {
        let (c, _, _, prompts) = make()
        await login(c, "", "pw")
        await login(c, "amy", "")
        _ = await run(c, .settled, at: "https://a.com")
        #expect(prompts.savePrompts.isEmpty)
    }

    @Test func switchedOffNeverOffers() async {
        let (c, _, prefs, prompts) = make()
        prefs.setOfferToSave(false)
        await login(c)
        _ = await run(c, .settled, at: "https://a.com")
        #expect(prompts.savePrompts.isEmpty)
    }

    @Test func staleSubmissionsExpire() async {
        var clock = Date(timeIntervalSince1970: 0)
        let prompts = FakePrompts()
        let vault = InMemoryVault()
        let prefs = PasswordPreferences(storageDirectory: nil)
        let c = PasswordsCoordinator(vault: vault, preferences: prefs, prompts: prompts, now: { clock })
        _ = await run(c, .submit(username: "amy", password: "pw", isNewPassword: false, action: nil), at: "https://a.com")
        clock = Date(timeIntervalSince1970: 120)
        _ = await run(c, .settled, at: "https://a.com")
        #expect(prompts.savePrompts.isEmpty)
    }
}

@MainActor
@Suite struct PageEventDecodingTests {
    @Test func decodesTheScriptsMessages() {
        #expect(PageEvent(body: ["kind": "focus", "token": 3, "isNewPassword": false, "action": "https://a.com/x"]) == .focus(token: 3, isNewPassword: false, action: "https://a.com/x"))
        #expect(PageEvent(body: ["kind": "submit", "username": "u", "password": "p"]) == .submit(username: "u", password: "p", isNewPassword: false, action: nil))
        #expect(PageEvent(body: ["kind": "loaded", "hasPassword": true]) == .loaded(hasPassword: true))
        #expect(PageEvent(body: ["kind": "settled"]) == .settled)
    }

    @Test func rejectsMalformedOrOversizedMessages() {
        #expect(PageEvent(body: "nope") == nil)
        #expect(PageEvent(body: ["kind": "bogus"]) == nil)
        #expect(PageEvent(body: ["kind": "focus"]) == nil)
        #expect(PageEvent(body: ["kind": "submit", "username": "u", "password": String(repeating: "x", count: 5000)]) == nil)
    }

    @Test func scriptRunsInAnIsolatedWorldAndOnlyMainFrame() {
        #expect(PasswordPageScript.userScript().isForMainFrameOnly)
        #expect(PasswordPageScript.source.contains("isTrusted"))
        #expect(!PasswordPageScript.source.contains("console."))
    }
}
