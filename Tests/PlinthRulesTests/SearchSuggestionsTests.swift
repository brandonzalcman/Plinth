import Foundation
import Testing
@testable import PlinthRules

struct SearchSuggestionsTests {
    @Test func buildsAnEndpointPerBuiltInEngineAndNoneForCustom() {
        let google = SearchSuggestions.endpoint(for: SearchEngine(kind: .google), query: "git hub&x")
        #expect(google?.host == "suggestqueries.google.com")
        #expect(google?.absoluteString.hasSuffix("q=git%20hub%26x") == true)
        #expect(SearchSuggestions.endpoint(for: SearchEngine(kind: .duckDuckGo), query: "a")?.host == "duckduckgo.com")
        #expect(SearchSuggestions.endpoint(for: SearchEngine(kind: .custom, customTemplate: "https://x.test/?q=%s"), query: "a") == nil)
    }

    @Test func parsesTheOpenSearchShape() {
        let data = Data(#"["github",["github","github login","github copilot","GitHub Login",""],[],[]]"#.utf8)
        #expect(SearchSuggestions.parse(data, query: "github") == ["github login", "github copilot"])
    }

    @Test func junkGivesNothing() {
        #expect(SearchSuggestions.parse(Data("<html>".utf8), query: "a").isEmpty)
        #expect(SearchSuggestions.parse(Data("[]".utf8), query: "a").isEmpty)
        #expect(SearchSuggestions.parse(Data(#"["a","nope"]"#.utf8), query: "a").isEmpty)
    }

    @Test func onlyPlainTextIsWorthAsking() {
        #expect(SearchSuggestions.isWorthAsking("github login"))
        #expect(!SearchSuggestions.isWorthAsking("g"))
        #expect(!SearchSuggestions.isWorthAsking("github.com"))
        #expect(!SearchSuggestions.isWorthAsking("https://github.com/x"))
        #expect(!SearchSuggestions.isWorthAsking("localhost:3000"))
    }

    @Test func sendsNothingInAPrivateWindowOrWhenOffOrForAnAddress() {
        let google = SearchEngine(kind: .google)
        let url = SearchSuggestions.request(for: " github ", engine: google, enabled: true, isPrivate: false)
        #expect(url?.host == "suggestqueries.google.com")
        #expect(SearchSuggestions.request(for: "github", engine: google, enabled: true, isPrivate: true) == nil)
        #expect(SearchSuggestions.request(for: "github", engine: google, enabled: false, isPrivate: false) == nil)
        #expect(SearchSuggestions.request(for: "github.com/login", engine: google, enabled: true, isPrivate: false) == nil)
        #expect(SearchSuggestions.request(for: "github", engine: SearchEngine(kind: .custom), enabled: true, isPrivate: false) == nil)
    }
}
