import Foundation
import Testing
import PlinthModel
@testable import PlinthReader

@Suite struct ReaderScriptTests {
    let url = URL(string: "https://example.com/a")!

    @Test func parsesTheScriptResult() throws {
        let raw: [String: Any] = ["title": "A page", "text": "Hello world", "focus": "world",
                                  "scrollFraction": NSNumber(value: 0.4)]
        let text = try #require(ReaderScript.pageText(from: raw, pageURL: url, fallbackTitle: "x", limit: 100))
        #expect(text.title == "A page")
        #expect(text.text == "Hello world")
        #expect(text.focusExcerpt == "world")
        #expect(text.scrollFraction == 0.4)
        #expect(text.url == url)
    }

    @Test func capsTextAndClampsScroll() throws {
        let raw: [String: Any] = ["title": "", "text": String(repeating: "a", count: 50), "focus": "",
                                  "scrollFraction": NSNumber(value: 3)]
        let text = try #require(ReaderScript.pageText(from: raw, pageURL: url, fallbackTitle: "Fallback", limit: 10))
        #expect(text.text.count == 10)
        #expect(text.title == "Fallback")
        #expect(text.focusExcerpt == nil)
        #expect(text.scrollFraction == 1)
    }

    @Test func rejectsAnythingElse() {
        #expect(ReaderScript.pageText(from: "nope", pageURL: url, fallbackTitle: nil, limit: 10) == nil)
        #expect(ReaderScript.pageText(from: nil, pageURL: url, fallbackTitle: nil, limit: 10) == nil)
    }

    @Test func argumentsMatchTheScript() {
        let args = ReaderScript.arguments(limit: -5)
        #expect(args["limit"] as? Int == 0)
        #expect(args["focusLength"] as? Int == ReaderScript.focusExcerptLength)
        #expect(ReaderScript.source.contains("focusLength"))
    }
}
