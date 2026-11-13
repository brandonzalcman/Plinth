import Foundation
import Testing
@testable import PlinthRules

@Suite struct AddressResolverTests {
    let resolver = AddressResolver()

    @Test(arguments: [
        ("example.com", "https://example.com"),
        ("  example.com  ", "https://example.com"),
        ("example.com/path", "https://example.com/path"),
        ("example.com/path?x=1#frag", "https://example.com/path?x=1#frag"),
        ("example.com?q=1", "https://example.com?q=1"),
        ("www.example.com", "https://www.example.com"),
        ("sub.domain.co.uk", "https://sub.domain.co.uk"),
        ("example.com:8080", "https://example.com:8080"),
        ("example.com.", "https://example.com."),
        ("EXAMPLE.COM", "https://EXAMPLE.COM"),
        ("x.ai", "https://x.ai"),
        ("lib.rs", "https://lib.rs"),
        ("news.ycombinator.com", "https://news.ycombinator.com"),
        ("xn--bcher-kva.xn--p1ai", "https://xn--bcher-kva.xn--p1ai"),
        ("www.something.zip", "https://www.something.zip"),
        ("build.internal.sh:9000", "https://build.internal.sh:9000"),
        // Explicit schemes
        ("https://example.com", "https://example.com"),
        ("http://example.com/a?b=c", "http://example.com/a?b=c"),
        ("HTTPS://example.com", "HTTPS://example.com"),
        ("http://localhost:8080/x", "http://localhost:8080/x"),
        ("https://example.com/a b", "https://example.com/a%20b"),
        ("file:///Users/someone/a.html", "file:///Users/someone/a.html"),
        ("about:blank", "about:blank"),
        ("mailto:someone@example.com", "mailto:someone@example.com"),
        ("data:text/plain,hi", "data:text/plain,hi"),
        ("myapp://open/thing", "myapp://open/thing"),
        // Local: http
        ("localhost", "http://localhost"),
        ("localhost:3000", "http://localhost:3000"),
        ("localhost:3000/api/v1", "http://localhost:3000/api/v1"),
        ("LOCALHOST:3000", "http://LOCALHOST:3000"),
        ("127.0.0.1", "http://127.0.0.1"),
        ("192.168.1.1:8080/admin", "http://192.168.1.1:8080/admin"),
        ("[::1]:3000", "http://[::1]:3000"),
        ("[::1]", "http://[::1]"),
        ("devbox:8080", "http://devbox:8080"),
        ("intranet/", "http://intranet/"),
        ("myapp.test", "http://myapp.test"),
        ("printer.local/status", "http://printer.local/status"),
    ])
    func urls(input: String, expected: String) throws {
        let url = try #require(URL(string: expected))
        #expect(resolver.resolve(input) == .url(url))
    }

    @Test func unicodeDomainIsAURL() {
        guard case .url(let url) = resolver.resolve("bücher.de") else {
            Issue.record("expected a URL")
            return
        }
        #expect(url.scheme == "https")
        #expect(url.host != nil)
    }

    @Test(arguments: [
        "what is node.js",
        "node.js",
        "hello",
        "hello world",
        "readme.md",
        "setup.py",
        "install.sh",
        "index.html",
        "archive.zip",
        "foo.bar",
        "3.14",
        "1.5",
        "v1.2.3",
        "1.2.3.4.5",
        "256.1.1.1",
        "e.g.",
        "a..b",
        "-foo.com",
        "someone@example.com",
        "define:word",
        "site:example.com swift",
        "javascript:alert(1)",
        "and/or",
        "TCP/IP",
        "src/main.rs",
        "example .com",
        "example.com is down",
        "C++",
        "?",
        "what?",
        "https://",
        "http://what is this",
        "localhost:notaport",
        "example.com:99999",
        "[nope]",
        "about:",
    ])
    func searches(input: String) {
        #expect(resolver.resolve(input) == .search(input))
    }

    @Test func searchQueryIsTrimmed() {
        #expect(resolver.resolve("  hello world \n") == .search("hello world"))
        #expect(resolver.resolve("") == .search(""))
        #expect(resolver.resolve("   ") == .search(""))
    }

    @Test(arguments: [
        ("swift concurrency", "https://duckduckgo.com/?q=swift%20concurrency"),
        ("c++ & rust", "https://duckduckgo.com/?q=c%2B%2B%20%26%20rust"),
        ("café", "https://duckduckgo.com/?q=caf%C3%A9"),
        ("a=b?c#d", "https://duckduckgo.com/?q=a%3Db%3Fc%23d"),
        ("  padded  ", "https://duckduckgo.com/?q=padded"),
        ("", "https://duckduckgo.com/?q="),
    ])
    func searchURL(query: String, expected: String) {
        #expect(resolver.searchURL(for: query).absoluteString == expected)
    }

    @Test func destination() {
        #expect(resolver.destination(for: "example.com").absoluteString == "https://example.com")
        #expect(resolver.destination(for: "what is node.js").absoluteString == "https://duckduckgo.com/?q=what%20is%20node.js")
    }
}
