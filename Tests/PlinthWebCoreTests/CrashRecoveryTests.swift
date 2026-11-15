import XCTest
@testable import PlinthWebCore

final class CrashRecoveryTests: XCTestCase {
    func testShownPageReloadsNow() {
        XCTAssertEqual(CrashRecovery.action(isShown: true, alreadyReloaded: false), .reloadNow)
    }

    func testHiddenPageWaitsUntilShown() {
        XCTAssertEqual(CrashRecovery.action(isShown: false, alreadyReloaded: false), .reloadWhenShown)
    }

    func testRepeatedEndingIsLeftAlone() {
        XCTAssertEqual(CrashRecovery.action(isShown: true, alreadyReloaded: true), .leaveAsIs)
        XCTAssertEqual(CrashRecovery.action(isShown: false, alreadyReloaded: true), .leaveAsIs)
    }
}
