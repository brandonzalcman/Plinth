import Foundation
import Testing
import PlinthModel
@testable import PlinthRules

@Suite struct SiteIdentityTests {
    let identity = SiteIdentity()

    @Test(arguments: [
        // Prefix stripping
        ("https://www.example.com/a/b?c=d", "example.com"),
        ("https://EXAMPLE.com", "example.com"),
        ("http://m.example.com", "example.com"),
        ("https://mobile.example.com", "example.com"),
        ("https://amp.example.com/story", "example.com"),
        ("https://www.m.example.com", "example.com"),
        ("https://www.bbc.co.uk/news", "bbc.co.uk"),
        ("https://m.youtube.com/watch?v=1", "youtube.com"),
        ("https://example.com./", "example.com"),
        ("https://example.com:8443/", "example.com"),
        // Prefixes that are the site itself are kept
        ("https://amp.dev", "amp.dev"),
        ("https://www.co.uk", "www.co.uk"),
        ("https://m.github.io", "m.github.io"),
        // Real subdomains stay distinct
        ("https://mail.google.com/mail/u/0/", "mail.google.com"),
        ("https://docs.google.com/document/d/1", "docs.google.com"),
        ("https://music.youtube.com", "music.youtube.com"),
        ("https://foo.github.io", "foo.github.io"),
        ("https://bar.github.io", "bar.github.io"),
        ("https://id.wikipedia.org/wiki/X", "id.wikipedia.org"),
        // Sign-in hosts
        ("https://accounts.google.com/signin", "accounts.google.com"),
        ("https://login.microsoftonline.com/common", "login.microsoftonline.com"),
        ("https://accounts.spotify.com", "accounts.spotify.com"),
        ("https://login.example.com", "example.com"),
        ("https://auth.example.com/callback", "example.com"),
        ("https://signin.example.com", "example.com"),
        ("https://sso.example.co.uk", "example.co.uk"),
        ("https://www.login.example.com", "example.com"),
        ("https://login.app.example.com", "login.app.example.com"),
        ("https://login.github.io", "login.github.io"),
        ("https://login.okta.com", "login.okta.com"),
        // Aliases and Wikimedia mobile
        ("https://en.m.wikipedia.org/wiki/Swift", "en.wikipedia.org"),
        ("https://mobile.twitter.com/home", "x.com"),
        ("https://youtu.be/abc", "youtube.com"),
        ("https://old.reddit.com/r/swift", "reddit.com"),
        // Local hosts and IPs keep the port
        ("http://localhost:3000/app", "localhost:3000"),
        ("http://localhost", "localhost"),
        ("http://localhost:80", "localhost"),
        ("https://localhost:443", "localhost"),
        ("http://127.0.0.1:8080", "127.0.0.1:8080"),
        ("http://192.168.1.10/admin", "192.168.1.10"),
        ("http://[::1]:3000/", "[::1]:3000"),
        ("http://devbox:8080", "devbox:8080"),
        ("http://myapp.test:3000", "myapp.test:3000"),
        ("http://www.myapp.local", "www.myapp.local"),
        // Punycode
        ("https://xn--bcher-kva.de/", "xn--bcher-kva.de"),
        ("https://www.xn--bcher-kva.de/", "xn--bcher-kva.de"),
        // Non-web schemes
        ("file:///Users/someone/notes.html", "file"),
        ("about:blank", "about"),
        ("data:text/html,hello", "data"),
        ("blob:https://example.com/1234", "blob"),
    ])
    func key(url: String, expected: String) throws {
        let parsed = try #require(URL(string: url))
        #expect(identity.key(for: parsed) == SiteKey(expected))
    }

    @Test func unicodeHostMatchesItsPunycodeForm() throws {
        let unicode = try #require(URL(string: "https://bücher.de/"))
        let ascii = try #require(URL(string: "https://xn--bcher-kva.de/"))
        #expect(identity.key(for: unicode) == identity.key(for: ascii))
    }

    @Test func schemelessURLIsTreatedAsWeb() throws {
        let url = try #require(URL(string: "www.example.com/path"))
        #expect(identity.key(for: url) == SiteKey("example.com"))
    }

    @Test(arguments: [
        ("mail.google.com", "Gmail"),
        ("docs.google.com", "Google Docs"),
        ("github.com", "GitHub"),
        ("youtube.com", "YouTube"),
        ("news.ycombinator.com", "Hacker News"),
        ("x.com", "X"),
        ("bbc.co.uk", "BBC"),
        ("example.com", "Example"),
        ("blog.example.com", "Example Blog"),
        ("shop.example.co.uk", "Example Shop"),
        ("a.b.example.com", "Example B A"),
        ("my-site.com", "My Site"),
        ("foo.github.io", "Foo"),
        ("api.github.com", "GitHub API"),
        ("foo.google.com", "Google Foo"),
        ("xn--bcher-kva.de", "Bücher"),
        ("localhost:3000", "localhost:3000"),
        ("localhost", "localhost"),
        ("127.0.0.1:8080", "127.0.0.1:8080"),
        ("[::1]:3000", "[::1]:3000"),
        ("myapp.test", "myapp.test"),
        ("file", "Files"),
        ("about", "Blank Page"),
    ])
    func siteName(key: String, expected: String) {
        #expect(identity.siteName(for: SiteKey(key)) == expected)
    }

    @Test func siteNameIsNeverEmpty() {
        for key in ["", ".", "..", "com", "co.uk", "-", "xn--"] {
            #expect(!identity.siteName(for: SiteKey(key)).isEmpty, "key \(key)")
        }
    }

    @Test(arguments: [
        ("example.com", "example.com"),
        ("shop.example.co.uk", "example.co.uk"),
        ("a.b.example.com.au", "example.com.au"),
        ("foo.github.io", "foo.github.io"),
        ("x.foo.github.io", "foo.github.io"),
    ])
    func registrableDomain(host: String, expected: String) {
        #expect(DomainRules.registrableDomain(of: host) == expected)
    }

    @Test func noRegistrableDomain() {
        for host in ["localhost", "co.uk", "github.io", "127.0.0.1", "::1", ""] {
            #expect(DomainRules.registrableDomain(of: host) == nil, "host \(host)")
        }
    }

    @Test func punycode() {
        #expect(DomainRules.decodePunycode("bcher-kva") == "bücher")
        #expect(DomainRules.decodePunycode("mnchen-3ya") == "münchen")
        #expect(DomainRules.unicodeLabel("xn--80ak6aa92e") == "аррӏе")
        #expect(DomainRules.unicodeLabel("plain") == "plain")
        #expect(DomainRules.unicodeLabel("xn--!!") == "xn--!!")
    }
}
