import Testing
import PlinthModel
@testable import PlinthShell

@Suite struct ResumeCardDecisionTests {
    let page = PageID()
    let other = PageID()

    func decide(selected: PageID?, restored: [PageID], isPrivate: Bool = false, summaries: Bool = true,
                enabled: Bool = true, available: Bool = true) -> ResumeCardDecision {
        ResumeCardDecision.decide(selected: selected, restored: restored, isPrivate: isPrivate, summariesEnabled: summaries,
                                  aiEnabled: enabled, aiAvailable: available)
    }

    @Test func aRestoredSelectedPageGetsASummary() {
        #expect(decide(selected: page, restored: [other, page]) == .summarise)
    }

    @Test func onlyThePageThatCameBackGetsACard() {
        #expect(decide(selected: other, restored: [page]) == .none)
        #expect(decide(selected: nil, restored: [page]) == .none)
        #expect(decide(selected: page, restored: []) == .none)
    }

    @Test func summariesNeedTheModel() {
        #expect(decide(selected: page, restored: [page], available: false) == .none)
    }

    @Test func withSummariesOffTheCardStillMarksThePlace() {
        #expect(decide(selected: page, restored: [page], summaries: false) == .placeOnly)
        #expect(decide(selected: page, restored: [page], summaries: false, available: false) == .placeOnly)
        // The AI switch off means no card at all, as on the Mac.
        #expect(decide(selected: page, restored: [page], summaries: false, enabled: false) == .none)
    }

    @Test func neverInAPrivateWindow() {
        #expect(decide(selected: page, restored: [page], isPrivate: true) == .none)
        #expect(decide(selected: page, restored: [page], isPrivate: true, summaries: false) == .none)
    }
}
