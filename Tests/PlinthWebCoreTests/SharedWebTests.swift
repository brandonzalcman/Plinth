import XCTest
import JavaScriptCore
@testable import PlinthWebCore

final class DownloadSafetyTests: XCTestCase {
    func testSafe() {
        for name in ["a.png", "photo.JPG", "x.heic", "doc.pdf", "song.mp3", "clip.mp4", "movie.mov", "notes.txt", "sound.m4a"] {
            XCTAssertTrue(DownloadSafety.isSafeToOpen(filename: name), name)
        }
    }

    func testUnsafe() {
        for name in ["Setup.app", "run.command", "script.sh", "tool.py", "a.js", "disk.dmg", "pkg.pkg", "arch.zip", "a.tar.gz",
                     "installer.exe", "noextension", "photo.jpg.app", "page.html", "pic.svg", "link.webloc", "x.jar",
                     "unknown.zzzzqq", "", ".png", "main.swift", "a.workflow"] {
            XCTAssertFalse(DownloadSafety.isSafeToOpen(filename: name), name)
        }
        XCTAssertFalse(DownloadSafety.isSafeToOpen(filename: "../../evil.sh"))
    }
}

final class DownloadNamingTests: XCTestCase {
    func testProvisionalName() {
        XCTAssertEqual(DownloadNaming.provisionalName(for: URL(string: "https://a.com/files/report.pdf?x=1")), "report.pdf")
        XCTAssertEqual(DownloadNaming.provisionalName(for: URL(string: "https://a.com/")), "Download")
        XCTAssertEqual(DownloadNaming.provisionalName(for: URL(string: "https://a.com")), "Download")
        XCTAssertEqual(DownloadNaming.provisionalName(for: nil), "Download")
    }

    func testSanitized() {
        XCTAssertEqual(DownloadNaming.sanitized("a/b:c.pdf"), "a-b-c.pdf")
        XCTAssertEqual(DownloadNaming.sanitized("  ..hidden.txt "), "hidden.txt")
        XCTAssertEqual(DownloadNaming.sanitized("..."), "download")
        XCTAssertEqual(DownloadNaming.sanitized(""), "download")
        XCTAssertEqual(DownloadNaming.sanitized("../../evil.sh"), "-..-evil.sh")
    }

    func testUniqueDestination() {
        let folder = URL(fileURLWithPath: "/tmp/dl", isDirectory: true)
        var taken: Set<String> = []
        let exists: (URL) -> Bool = { taken.contains($0.lastPathComponent) }
        XCTAssertEqual(DownloadNaming.uniqueDestination(in: folder, suggested: "report.pdf", exists: exists).lastPathComponent, "report.pdf")
        taken = ["report.pdf", "report 2.pdf"]
        XCTAssertEqual(DownloadNaming.uniqueDestination(in: folder, suggested: "report.pdf", exists: exists).lastPathComponent, "report 3.pdf")
        taken = ["notes"]
        XCTAssertEqual(DownloadNaming.uniqueDestination(in: folder, suggested: "notes", exists: exists).lastPathComponent, "notes 2")
        let path = DownloadNaming.uniqueDestination(in: folder, suggested: "../x.txt", exists: { _ in false })
        XCTAssertEqual(path.deletingLastPathComponent().path, "/tmp/dl")
    }

    func testUniqueDestinationOnDisk() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data().write(to: folder.appendingPathComponent("a.pdf"))
        XCTAssertEqual(DownloadNaming.uniqueDestination(in: folder, suggested: "a.pdf").lastPathComponent, "a 2.pdf")
    }
}

final class DownloadPolicyTests: XCTestCase {
    private func response(_ headers: [String: String]) -> URLResponse {
        HTTPURLResponse(url: URL(string: "https://a.com/f")!, statusCode: 200, httpVersion: nil, headerFields: headers)!
    }

    func testAttachmentAndUnshowable() {
        XCTAssertTrue(DownloadPolicy.shouldDownload(response(["Content-Disposition": "Attachment; filename=a.pdf"]), canShowMIMEType: true))
        XCTAssertFalse(DownloadPolicy.shouldDownload(response(["Content-Disposition": "inline"]), canShowMIMEType: true))
        XCTAssertFalse(DownloadPolicy.shouldDownload(response([:]), canShowMIMEType: true))
        XCTAssertTrue(DownloadPolicy.shouldDownload(response([:]), canShowMIMEType: false))
        let plain = URLResponse(url: URL(string: "file:///a.zip")!, mimeType: "application/zip", expectedContentLength: 1, textEncodingName: nil)
        XCTAssertTrue(DownloadPolicy.shouldDownload(plain, canShowMIMEType: false))
    }
}

final class PageMetaTests: XCTestCase {
    private func icon(_ href: String, rel: String = "icon", sizes: String = "", type: String = "") -> [String: Any] {
        ["href": href, "rel": rel, "sizes": sizes, "type": type]
    }

    func testRanksSmallestAtLeast64First() {
        let ranked = PageMeta.rankedIcons([
            icon("https://a.com/16.png", sizes: "16x16"),
            icon("https://a.com/512.png", sizes: "512x512"),
            icon("https://a.com/96.png", sizes: "96x96"),
            icon("https://a.com/touch.png", rel: "apple-touch-icon"),
            icon("https://a.com/32.png", sizes: "32x32"),
        ]).map(\.lastPathComponent)
        XCTAssertEqual(ranked, ["96.png", "touch.png", "512.png", "32.png", "16.png"])
    }

    func testDefaultSizesAndDuplicates() {
        let ranked = PageMeta.rankedIcons([
            icon("https://a.com/favicon.ico"),
            icon("https://a.com/logo.svg", type: "image/svg+xml"),
            icon("https://a.com/any.png", sizes: "any"),
            icon("https://a.com/plain.png"),
            icon("https://a.com/plain.png", sizes: "16x16"),
            ["rel": "icon"],
        ]).map(\.lastPathComponent)
        XCTAssertEqual(ranked, ["logo.svg", "any.png", "plain.png", "favicon.ico"])
    }

    func testSiteNameAndCurrent() {
        XCTAssertEqual(PageMeta.siteName(["siteName": "  Swift.org \n"]), "Swift.org")
        XCTAssertNil(PageMeta.siteName(["siteName": "   "]))
        XCTAssertNil(PageMeta.siteName(["siteName": String(repeating: "x", count: 81)]))
        XCTAssertNil(PageMeta.siteName([:]))
        let page = URL(string: "https://www.swift.org/blog/")!
        XCTAssertTrue(PageMeta.isCurrent(["url": "https://www.swift.org/other"], pageURL: page))
        XCTAssertFalse(PageMeta.isCurrent(["url": "https://example.com/"], pageURL: page))
        XCTAssertFalse(PageMeta.isCurrent([:], pageURL: page))
    }

    func testIconCandidatesAndFetchOrder() {
        let body: [String: Any] = ["icons": [icon("https://a.com/96.png", sizes: "96x96")]]
        XCTAssertEqual(PageMeta.iconCandidates(body).map(\.absoluteString), ["https://a.com/96.png"])
        XCTAssertEqual(PageMeta.originFavicon(for: URL(string: "http://a.com:8080/x/y")!)?.absoluteString, "http://a.com:8080/favicon.ico")
        XCTAssertNil(PageMeta.originFavicon(for: URL(string: "file:///tmp/a.html")!))
        let order = PageMeta.fetchOrder(candidates: [URL(string: "https://a.com/96.png")!, URL(string: "data:image/png;base64,AA")!],
                                        pageURL: URL(string: "https://a.com/page")!)
        XCTAssertEqual(order.map(\.absoluteString), ["https://a.com/96.png", "https://a.com/favicon.ico"])
        let noDup = PageMeta.fetchOrder(candidates: [URL(string: "https://a.com/favicon.ico")!], pageURL: URL(string: "https://a.com/")!)
        XCTAssertEqual(noDup.count, 1)
    }

    /// The collector is valid JavaScript and behaves on a minimal fake document.
    func testCollectorRuns() throws {
        let context = try XCTUnwrap(JSContext())
        var error: String?
        context.exceptionHandler = { _, value in error = value?.toString() }
        context.evaluateScript("""
        var location = { href: 'https://a.com/p' };
        function link(rel, href, sizes) { return { href: href, getAttribute: function (n) {
          return n === 'rel' ? rel : (n === 'sizes' ? sizes : null); } }; }
        var document = {
          querySelector: function (s) { return s.indexOf('og:site_name') >= 0 ? { getAttribute: function () { return ' A Site ' } } : null; },
          querySelectorAll: function () { return [link('icon', 'https://a.com/i.png', '32x32'), link('stylesheet', 'https://a.com/s.css', ''),
                                                  link('apple-touch-icon', 'https://a.com/t.png', ''), link('icon', 'data:x', '')]; }
        };
        """)
        context.evaluateScript(PageMeta.collectorFunction)
        let result = context.evaluateScript("JSON.stringify(plinthCollectMeta())")?.toString() ?? ""
        XCTAssertNil(error)
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
        XCTAssertEqual(body["siteName"] as? String, "A Site")
        XCTAssertEqual(body["url"] as? String, "https://a.com/p")
        XCTAssertEqual(PageMeta.iconCandidates(body).map(\.lastPathComponent), ["t.png", "i.png"])
    }
}
