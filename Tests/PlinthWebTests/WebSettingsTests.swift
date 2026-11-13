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
