import Foundation
import Testing
import PlinthModel
@testable import PlinthRules

@Suite struct PinLinkPolicyTests {
    let policy = PinLinkPolicy()
    let pin = SiteKey("mail.example.com")
    let home = URL(string: "https://mail.example.com/inbox")!

    func req(_ url: String, _ kind: NavigationKind = .linkClick, from source: URL? = nil) -> NavigationRequest {
        NavigationRequest(url: URL(string: url)!, kind: kind, sourceURL: source ?? home)
    }

    @Test func divertsOffSiteLinkClick() {
        #expect(policy.shouldDivert(req("https://news.other.org/story"), pinKey: pin))
    }

    @Test func keepsSameSiteLinks() {
        #expect(!policy.shouldDivert(req("https://mail.example.com/thread/1"), pinKey: pin))
        #expect(!policy.shouldDivert(req("https://www.mail.example.com/x"), pinKey: pin))
    }

    @Test(arguments: [NavigationKind.other, .formSubmit, .backForward, .reload])
    func neverDivertsNonClicks(_ kind: NavigationKind) {
        #expect(!policy.shouldDivert(req("https://news.other.org/", kind), pinKey: pin))
    }

    @Test func leavesSignInLinksAlone() {
        #expect(!policy.shouldDivert(req("https://accounts.google.com/o/oauth2/auth?client_id=1"), pinKey: pin))
        #expect(!policy.shouldDivert(req("https://login.microsoftonline.com/common"), pinKey: pin))
        #expect(!policy.shouldDivert(req("https://corp.okta.com/app/x"), pinKey: pin))
        #expect(!policy.shouldDivert(req("https://idp.other.org/saml/sso"), pinKey: pin))
        #expect(!policy.shouldDivert(req("https://other.org/login?next=/"), pinKey: pin))
        #expect(!policy.shouldDivert(req("https://other.org/x?redirect_uri=https%3A%2F%2Fmail.example.com"), pinKey: pin))
    }

    @Test func neverInterferesWhileThePinIsOffSite() {
        let away = URL(string: "https://accounts.google.com/signin")!
        #expect(!policy.shouldDivert(req("https://news.other.org/", from: away), pinKey: pin))
    }

    @Test func ignoresNonWebSchemes() {
        #expect(!policy.shouldDivert(req("mailto:a@b.c"), pinKey: pin))
    }
}
