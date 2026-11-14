import XCTest
@testable import PlinthWeb

final class HTTPSOnlyTests: XCTestCase {
    func testUpgradesPlainHTTP() {
        XCTAssertEqual(HTTPSOnly.upgraded(URL(string: "http://example.com/a?b=1#c")!)?.absoluteString, "https://example.com/a?b=1#c")
        XCTAssertEqual(HTTPSOnly.upgraded(URL(string: "http://example.com:80/")!)?.absoluteString, "https://example.com/")
        XCTAssertEqual(HTTPSOnly.upgraded(URL(string: "http://example.com:8080/")!)?.absoluteString, "https://example.com:8080/")
        XCTAssertEqual(HTTPSOnly.upgraded(URL(string: "HTTP://Example.com/")!)?.scheme, "https")
    }

    func testLeavesOthersAlone() {
        for text in ["https://example.com", "ftp://example.com", "file:///tmp/a", "about:blank",
                     "http://localhost:3000", "http://127.0.0.1:8000/x", "http://[::1]:8080/", "http://10.0.0.5/",
                     "http://printer.local/", "http://app.localhost/", "http://site.test/", "http://a.b.test:81/"] {
            XCTAssertNil(HTTPSOnly.upgraded(URL(string: text)!), text)
        }
        XCTAssertFalse(HTTPSOnly.shouldUpgrade(URL(string: "http://192.168.1.1")!))
        XCTAssertTrue(HTTPSOnly.shouldUpgrade(URL(string: "http://localhost.example.com")!))
        XCTAssertTrue(HTTPSOnly.shouldUpgrade(URL(string: "http://contest.com")!))
    }

    func testFallbackEligibility() {
        XCTAssertTrue(HTTPSOnly.isFallbackEligible(urlErrorCode: NSURLErrorSecureConnectionFailed))
        XCTAssertTrue(HTTPSOnly.isFallbackEligible(urlErrorCode: NSURLErrorCannotConnectToHost))
        XCTAssertFalse(HTTPSOnly.isFallbackEligible(urlErrorCode: NSURLErrorCancelled))
        XCTAssertFalse(HTTPSOnly.isFallbackEligible(urlErrorCode: NSURLErrorCannotFindHost))
    }
}

final class PageScriptTests: XCTestCase {
    /// The Mac page script embeds the shared meta collector.
    func testPageScriptUsesSharedCollector() {
        XCTAssertTrue(PageScript.source.contains("function plinthCollectMeta()"))
        XCTAssertTrue(PageScript.source.contains("var meta = plinthCollectMeta();"))
    }

    @MainActor
    func testUniqueDestinationForwardsToSharedNaming() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data().write(to: folder.appendingPathComponent("a.pdf"))
        XCTAssertEqual(WebViewPool.uniqueDestination(in: folder, suggested: "a.pdf").lastPathComponent, "a 2.pdf")
    }
}
