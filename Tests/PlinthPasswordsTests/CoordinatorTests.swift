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
        for site in ["https://evil.test", "https://a.com:8443", "https://a.com.evil.test", "https://login.a.com", "http://a.com"] {
            #expect(await run(c, .focus(token: 1, isNewPassword: false, action: nil), at: site).isEmpty, "\(site)")
        }
    }

    @Test func wwwAndBareHostShareLogins() async {
        let (c, _, _, _) = make([saved("https://www.a.com", "amy", "pw1")])
        #expect(await run(c, .focus(token: 1, isNewPassword: false, action: nil), at: "https://a.com/login").count == 1)
        let (d, _, _, _) = make([saved("https://a.com", "amy", "pw1")])
        #expect(await run(d, .focus(token: 1, isNewPassword: false, action: nil), at: "https://www.a.com/login").count == 1)
    }

    @Test func httpLoginFillsItsHTTPSUpgrade() async {
        let (c, _, _, _) = make([saved("http://a.com", "amy", "pw1")])
        #expect(await run(c, .focus(token: 1, isNewPassword: false, action: nil), at: "https://a.com").count == 1)
    }

    @Test func typedUserNameIsNeverOverwritten() async {
        let (c, _, _, prompts) = make([saved("https://a.com", "amy", "pw1")])
        #expect(await run(c, .focus(token: 1, isNewPassword: false, action: nil, username: "bob"), at: "https://a.com").isEmpty)
        let calls = await run(c, .focus(token: 2, isNewPassword: false, action: nil, username: "AMY"), at: "https://a.com")
        #expect(calls.map(\.2) == ["pw1"] && prompts.chooseCalls == 0)
    }

    @Test func typedUserNameChoosesAmongSeveral() async {
        let (c, _, _, prompts) = make([saved("https://a.com", "amy", "pw1"), saved("https://a.com", "bob", "pw2")])
        let calls = await run(c, .focus(token: 1, isNewPassword: false, action: nil, username: "bob"), at: "https://a.com")
        #expect(calls.map(\.2) == ["pw2"] && prompts.chooseCalls == 0)
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

    @Test func scriptRunsInAnIsolatedWorldInEveryFrame() {
        #expect(!PasswordPageScript.userScript().isForMainFrameOnly)
        #expect(PasswordPageScript.userScript().source == PasswordPageScript.source)
        #expect(PasswordPageScript.source.contains("isTrusted"))
        #expect(!PasswordPageScript.source.contains("console."))
        // The only way a page can fake input is blocked: the test flag is read from the script's own world, never set by it.
        #expect(!PasswordPageScript.source.contains("__plinthPwTest ="))
    }
}

@MainActor
@Suite struct TwoStepTests {
    @Test func identifierFieldFillsTheUserNameOnly() async {
        let (c, _, _, _) = make([saved("https://a.com", "amy", "pw1")])
        let calls = await run(c, .focusIdentifier(token: 4, action: nil), at: "https://a.com/signin")
        #expect(calls.count == 1 && calls[0].0 == 4 && calls[0].1 == "amy" && calls[0].2 == "")
    }

    @Test func identifierFieldOtherOriginsNeverFill() async {
        let (c, _, _, _) = make([saved("https://a.com", "amy", "pw1")])
        #expect(await run(c, .focusIdentifier(token: 4, action: nil), at: "https://evil.test").isEmpty)
    }

    @Test func passwordStepWithoutAUserNameFieldIsSavedUnderTheFirstStepsName() async throws {
        let (c, vault, _, prompts) = make()
        _ = await run(c, .identifier(username: "amy@a.com"), at: "https://a.com/signin")
        _ = await run(c, .submit(username: "", password: "pw1", isNewPassword: false, action: nil), at: "https://a.com/signin/pwd")
        _ = await run(c, .loaded(hasPassword: false), at: "https://a.com/home")
        #expect(prompts.savePrompts.map(\.username) == ["amy@a.com"])
        #expect(try vault.password(for: LoginKey(origin: origin("https://a.com"), username: "amy@a.com")) == "pw1")
    }

    @Test func passwordStepWithoutAnyUserNameSavesNothing() async {
        let (c, _, _, prompts) = make()
        _ = await run(c, .submit(username: "", password: "pw1", isNewPassword: false, action: nil), at: "https://a.com")
        _ = await run(c, .settled, at: "https://a.com")
        #expect(prompts.savePrompts.isEmpty)
    }

    @Test func theFirstStepsNameChoosesTheLoginOnTheSecond() async {
        let (c, _, _, prompts) = make([saved("https://a.com", "amy", "pw1"), saved("https://a.com", "bob", "pw2")])
        _ = await run(c, .identifier(username: "bob"), at: "https://a.com")
        let calls = await run(c, .focus(token: 1, isNewPassword: false, action: nil), at: "https://a.com")
        #expect(calls.map(\.2) == ["pw2"] && prompts.chooseCalls == 0)
    }

    @Test func theFirstStepsNameIsForgottenAfterAWhile() async {
        var clock = Date(timeIntervalSince1970: 0)
        let prompts = FakePrompts()
        let c = PasswordsCoordinator(vault: InMemoryVault(), preferences: PasswordPreferences(storageDirectory: nil), prompts: prompts, now: { clock })
        _ = await run(c, .identifier(username: "amy"), at: "https://a.com")
        clock = Date(timeIntervalSince1970: 700)
        _ = await run(c, .submit(username: "", password: "pw", isNewPassword: false, action: nil), at: "https://a.com")
        _ = await run(c, .settled, at: "https://a.com")
        #expect(prompts.savePrompts.isEmpty)
    }

    @Test func theFirstStepsNameDoesNotCarryToAnotherSite() async {
        let (c, _, _, prompts) = make()
        _ = await run(c, .identifier(username: "amy"), at: "https://a.com")
        _ = await run(c, .submit(username: "", password: "pw", isNewPassword: false, action: nil), at: "https://evil.test")
        _ = await run(c, .settled, at: "https://evil.test")
        #expect(prompts.savePrompts.isEmpty)
    }
}

@MainActor
@Suite struct FrameAndOriginTests {
    private func runIn(_ c: PasswordsCoordinator, _ event: PageEvent, at site: String, main: Bool) async {
        await c.handle(event, origin: origin(site), webView: nil, isMainFrame: main) { _, _, _ in }
    }

    @Test func anAdFramesLoadDoesNotResolveTheLogin() async {
        let (c, _, _, prompts) = make()
        await runIn(c, .submit(username: "amy", password: "pw", isNewPassword: false, action: nil), at: "https://a.com", main: true)
        await runIn(c, .loaded(hasPassword: false), at: "https://ads.test", main: false)
        await runIn(c, .settled, at: "https://ads.test", main: false)
        #expect(prompts.savePrompts.isEmpty)
        await runIn(c, .settled, at: "https://a.com", main: true)
        #expect(prompts.savePrompts.count == 1)
    }

    @Test func aLoginInAFrameIsSavedForTheFramesOwnOrigin() async throws {
        let (c, vault, _, prompts) = make()
        await runIn(c, .submit(username: "amy", password: "pw", isNewPassword: false, action: nil), at: "https://auth.a.com", main: false)
        await runIn(c, .settled, at: "https://auth.a.com", main: false)
        #expect(prompts.savePrompts.first?.origin == origin("https://auth.a.com"))
        #expect(try vault.list().map(\.origin) == [origin("https://auth.a.com")])
    }

    @Test func aFramesLoginIsNeverFilledFromThePagesOrigin() async {
        // Saved for the embedding page; the frame is another origin.
        let (c, _, _, _) = make([saved("https://a.com", "amy", "pw1")])
        var filled = 0
        await c.handle(.focus(token: 1, isNewPassword: false, action: nil), origin: origin("https://pay.test"), webView: nil, isMainFrame: false) { _, _, _ in filled += 1 }
        #expect(filled == 0)
    }

    @Test func updatesKeepTheOriginTheLoginWasSavedUnder() async throws {
        let (c, vault, _, _) = make([saved("https://www.a.com", "amy", "old")])
        _ = await run(c, .submit(username: "amy", password: "new", isNewPassword: false, action: nil), at: "https://a.com")
        _ = await run(c, .settled, at: "https://a.com")
        #expect(try vault.list().count == 1)
        #expect(try vault.password(for: LoginKey(origin: origin("https://www.a.com"), username: "amy")) == "new")
    }

    @Test func anHTTPLoginMovesToHTTPSWhenSavedAgain() async throws {
        let (c, vault, _, _) = make([saved("http://a.com", "amy", "old")])
        _ = await run(c, .submit(username: "amy", password: "new", isNewPassword: false, action: nil), at: "https://a.com")
        _ = await run(c, .settled, at: "https://a.com")
        #expect(try vault.list().map(\.origin) == [origin("https://a.com")])
        #expect(try vault.password(for: LoginKey(origin: origin("https://a.com"), username: "amy")) == "new")
    }

    @Test func neverForASiteAppliesToItsWwwTwin() {
        let prefs = PasswordPreferences(storageDirectory: nil)
        prefs.addNever(origin("https://a.com"))
        #expect(prefs.isNeverSaved(origin("https://www.a.com")))
        #expect(!prefs.isNeverSaved(origin("https://b.a.com")))
    }

    @Test func decodesTheTwoStepMessages() {
        #expect(PageEvent(body: ["kind": "focusIdentifier", "token": 2, "action": ""]) == .focusIdentifier(token: 2, action: ""))
        #expect(PageEvent(body: ["kind": "identifier", "username": "amy"]) == .identifier(username: "amy"))
        #expect(PageEvent(body: ["kind": "identifier", "username": ""]) == nil)
        #expect(PageEvent(body: ["kind": "focus", "token": 3, "username": "amy"]) == .focus(token: 3, isNewPassword: false, action: nil, username: "amy"))
    }
}
