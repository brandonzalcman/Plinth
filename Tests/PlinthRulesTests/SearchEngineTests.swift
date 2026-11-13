import Foundation
import Testing
@testable import PlinthRules

@Suite struct SearchEngineTests {
    @Test(arguments: [
        (SearchEngine.Kind.google, "https://www.google.com/search?q="),
        (.duckDuckGo, "https://duckduckgo.com/?q="),
        (.bing, "https://www.bing.com/search?q="),
        (.ecosia, "https://www.ecosia.org/search?q="),
        (.brave, "https://search.brave.com/search?q="),
    ])
    func everyEngineBuildsItsURL(kind: SearchEngine.Kind, prefix: String) {
        let resolver = AddressResolver(engine: SearchEngine(kind: kind))
        #expect(resolver.destination(for: "swift concurrency").absoluteString == prefix + "swift%20concurrency")
        #expect(resolver.searchURL(for: "cats").absoluteString == prefix + "cats")
        // Typed addresses never go to the engine.
        #expect(resolver.destination(for: "example.com").absoluteString == "https://example.com")
    }

    @Test(arguments: SearchEngine.Kind.allCases.filter { $0 != .custom })
    func queryEncoding(kind: SearchEngine.Kind) throws {
        let engine = SearchEngine(kind: kind)
        let prefix = try #require(kind.template).replacingOccurrences(of: "%s", with: "")
        #expect(engine.searchURL(for: "a b").absoluteString == prefix + "a%20b")
        #expect(engine.searchURL(for: "rock & roll").absoluteString == prefix + "rock%20%26%20roll")
        #expect(engine.searchURL(for: "c# language").absoluteString == prefix + "c%23%20language")
        #expect(engine.searchURL(for: "100%").absoluteString == prefix + "100%25")
        #expect(engine.searchURL(for: "a+b=c").absoluteString == prefix + "a%2Bb%3Dc")
        #expect(engine.searchURL(for: "café 日本").absoluteString == prefix + "caf%C3%A9%20%E6%97%A5%E6%9C%AC")
        #expect(engine.searchURL(for: "  padded  ").absoluteString == prefix + "padded")
        // The query survives a round trip through URLComponents.
        let url = engine.searchURL(for: "rock & roll #1")
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value
        #expect(q == "rock & roll #1")
    }

    @Test func customTemplate() {
        let engine = SearchEngine(kind: .custom, customTemplate: "https://search.example.org/find?term=%s&lang=en")
        #expect(engine.searchURL(for: "a & b").absoluteString == "https://search.example.org/find?term=a%20%26%20b&lang=en")
        #expect(AddressResolver(engine: engine).destination(for: "two words").absoluteString
                == "https://search.example.org/find?term=two%20words&lang=en")
        // Surrounding whitespace in the template is ignored.
        let padded = SearchEngine(kind: .custom, customTemplate: "  https://x.org/?q=%s \n")
        #expect(padded.searchURL(for: "hi").absoluteString == "https://x.org/?q=hi")
        // %s may appear in the path.
        #expect(SearchEngine(kind: .custom, customTemplate: "https://x.org/s/%s").searchURL(for: "a b").absoluteString == "https://x.org/s/a%20b")
    }

    @Test(arguments: ["", "https://example.com/?q=", "ftp://example.com/?q=%s", "https:///?q=%s", "not a url %s", "https://exa mple.com/?q=%s", "%s", "javascript:%s"])
    func invalidCustomTemplateFallsBackToDuckDuckGo(template: String) {
        let engine = SearchEngine(kind: .custom, customTemplate: template)
        #expect(engine.effectiveTemplate == SearchEngine.Kind.duckDuckGo.template)
        #expect(AddressResolver(engine: engine).destination(for: "cats dogs").absoluteString == "https://duckduckgo.com/?q=cats%20dogs")
    }

    @Test func isValidTemplate() {
        #expect(SearchEngine.isValid(template: "https://example.com/search?q=%s"))
        #expect(SearchEngine.isValid(template: "http://example.com/?q=%s"))
        #expect(SearchEngine.isValid(template: "HTTPS://Example.com/?q=%s"))
        #expect(SearchEngine.isValid(template: "  https://example.com/?q=%s  "))
        #expect(SearchEngine.isValid(template: "https://example.com:8080/?q=%s"))
        #expect(SearchEngine.isValid(template: "https://example.com/?q=%s&alt=%s"))   // multiple %s
        #expect(SearchEngine.isValid(template: "https://localhost/?q=%s"))
        #expect(!SearchEngine.isValid(template: "https://example.com/?q="))            // no %s
        #expect(!SearchEngine.isValid(template: "ftp://example.com/?q=%s"))            // wrong scheme
        #expect(!SearchEngine.isValid(template: "example.com/?q=%s"))                  // no scheme
        #expect(!SearchEngine.isValid(template: "https://?q=%s"))                      // no host
        #expect(!SearchEngine.isValid(template: "https:///?q=%s"))
        #expect(!SearchEngine.isValid(template: "https://example.com/?q=%s now"))      // whitespace inside
        #expect(!SearchEngine.isValid(template: "https://exa mple.com/?q=%s"))
        #expect(!SearchEngine.isValid(template: ""))
        #expect(!SearchEngine.isValid(template: "   "))
    }

    @Test func multiplePlaceholdersAreAllReplaced() {
        let engine = SearchEngine(kind: .custom, customTemplate: "https://x.org/?q=%s&r=%s")
        #expect(engine.searchURL(for: "a b").absoluteString == "https://x.org/?q=a%20b&r=a%20b")
    }

    @Test func engineCanChangeLive() {
        var resolver = AddressResolver()
        #expect(resolver.destination(for: "hello world").host == "duckduckgo.com")
        resolver.engine = SearchEngine(kind: .google)
        #expect(resolver.destination(for: "hello world").host == "www.google.com")
        resolver.engine = SearchEngine(kind: .custom, customTemplate: "https://kagi.com/search?q=%s")
        #expect(resolver.destination(for: "hello world").host == "kagi.com")
    }

    @Test func engineCodableRoundTrip() throws {
        let engine = SearchEngine(kind: .custom, customTemplate: "https://x.org/?q=%s")
        let back = try JSONDecoder().decode(SearchEngine.self, from: JSONEncoder().encode(engine))
        #expect(back == engine)
    }
}
