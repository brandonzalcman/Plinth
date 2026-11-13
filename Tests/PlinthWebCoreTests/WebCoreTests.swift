import XCTest
import WebKit
import PlinthSettings
@testable import PlinthWebCore

final class WebCoreTests: XCTestCase {
    func testBlocklistShipsAndParses() throws {
        let json = try ContentBlocker.source()
        let rules = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
        XCTAssertGreaterThan(rules.count, 50)
        XCTAssertTrue(json.contains("doubleclick"))
    }

    func testCookieRulesParse() throws {
        let rules = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(WebPrivacy.cookieRulesJSON.utf8)) as? [[String: Any]])
        XCTAssertEqual((rules.first?["action"] as? [String: String])?["type"], "block-cookies")
    }

    func testWebsiteDataTypes() {
        XCTAssertTrue(WebPrivacy.websiteDataTypes(for: [.history]).isEmpty)
        let cookies = WebPrivacy.websiteDataTypes(for: [.cookiesAndSiteData])
        XCTAssertTrue(cookies.contains(WKWebsiteDataTypeCookies))
        XCTAssertFalse(cookies.contains(WKWebsiteDataTypeDiskCache))
        XCTAssertTrue(WebPrivacy.websiteDataTypes(for: [.cache]).contains(WKWebsiteDataTypeDiskCache))
    }

    func testGPCScripts() {
        XCTAssertTrue(WebPrivacy.gpcLiveScript(true).contains("defineProperty"))
        XCTAssertTrue(WebPrivacy.gpcLiveScript(false).contains("delete"))
    }
}
