import XCTest
@testable import PlinthWeb

final class DownloadRateTests: XCTestCase {
    func testNeedsTwoSpacedSamples() {
        var rate = DownloadRate()
        XCTAssertNil(rate.sample(bytes: 0, at: 0))
        XCTAssertNil(rate.sample(bytes: 100, at: 0.2))   // too close: folded into the next sample
        XCTAssertEqual(rate.sample(bytes: 1_000_000, at: 1)!, 1_000_000, accuracy: 1)
    }

    func testSmoothsChanges() {
        var rate = DownloadRate()
        rate.sample(bytes: 0, at: 0)
        rate.sample(bytes: 1_000_000, at: 1)
        let next = rate.sample(bytes: 1_000_000, at: 2)!   // stalled for a second
        XCTAssertLessThan(next, 1_000_000)
        XCTAssertGreaterThan(next, 0)
    }
}
