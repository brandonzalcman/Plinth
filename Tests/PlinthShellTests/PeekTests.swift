import Foundation
import Testing
@testable import PlinthShell

@Suite struct LinkOpeningTests {
    let web = URL(string: "https://example.com/article")!

    @Test func shiftClickArrivesAsANewWindowAndPeeks() {
        #expect(LinkOpening.decide(.newWindow, userGesture: true, url: web) == .peek)
        #expect(LinkOpening.decide(.newWindow, userGesture: true, url: URL(string: "http://example.com")!) == .peek)
        #expect(LinkOpening.decide(.newWindow, userGesture: true, url: URL(string: "file:///tmp/a.html")!) == .peek)
    }

    @Test func aNewWindowWithoutAClickIsAnOrdinaryPage() {
        #expect(LinkOpening.decide(.newWindow, userGesture: false, url: web) == .page(background: false))
    }

    @Test func onlyWebAndFileAddressesPeek() {
        #expect(LinkOpening.decide(.newWindow, userGesture: true, url: URL(string: "mailto:a@example.com")!) == .page(background: false))
        #expect(LinkOpening.decide(.newWindow, userGesture: true, url: URL(string: "chrome://extensions")!) == .page(background: false))
        #expect(LinkOpening.decide(.newWindow, userGesture: true, url: nil) == .page(background: false))
    }

    @Test func commandClickOpensInTheBackgroundAndCommandShiftInFront() {
        #expect(LinkOpening.decide(.backgroundTab, userGesture: true, url: web) == .page(background: true))
        #expect(LinkOpening.decide(.foregroundTab, userGesture: true, url: web) == .page(background: false))
        #expect(LinkOpening.decide(.currentTab, userGesture: true, url: web) == .page(background: false))
    }

    @Test func scriptedPopupsKeepTheirOwnWindow() {
        #expect(LinkOpening.decide(.popup, userGesture: true, url: web) == .popup)
        #expect(LinkOpening.decide(.popup, userGesture: false, url: web) == .popup)
    }

}
