import Foundation
import Testing
import PlinthLoyalty
import PlinthSettings
@testable import PlinthShell

@Suite struct AccentUnlockTests {
    @Test func baseAccentsAreAlwaysAvailable() {
        for choice in [AccentChoice.blue, .purple, .pink, .red, .orange, .green, .graphite] {
            #expect(choice.unlockLevel == 1)
            #expect(choice.effective(atLevel: 1) == choice)
        }
    }

    @Test func brandColoursUnlockWithTheirColourwaysLevel() {
        #expect(AccentChoice.dusk.unlockLevel == 2)
        #expect(AccentChoice.meadow.unlockLevel == 3)
        #expect(AccentChoice.ember.unlockLevel == 4)
        #expect(AccentChoice.midnight.unlockLevel == 5)
        #expect(AccentChoice.mono.unlockLevel == 6)
    }

    @Test func aLockedBrandColourFallsBackToBlue() {
        #expect(AccentChoice.ember.effective(atLevel: 3) == .blue)
        #expect(AccentChoice.ember.effective(atLevel: 4) == .ember)
        #expect(AccentChoice.mono.effective(atLevel: 6) == .mono)
        #expect(AccentChoice.dusk.effective(atLevel: 1) == .blue)
    }

    @Test func beforeLoyaltyIsSetUpTheChoiceStands() {
        #expect(AccentChoice.midnight.effective(atLevel: nil) == .midnight)
    }
}

@Suite struct LoyaltyEarningTests {
    @Test func anOrdinaryTickCountsTheDay() {
        #expect(LoyaltyEarning.tickEvents(LoyaltySnapshot()) == [.dayOfUse])
    }

    @Test func aPrivateKeyWindowDoesNotCountTheDay() {
        #expect(LoyaltyEarning.tickEvents(LoyaltySnapshot(keyWindowIsPrivate: true)).isEmpty)
    }

    @Test func pinsAndSplitViewEarnTheirMilestones() {
        let events = LoyaltyEarning.tickEvents(LoyaltySnapshot(hasPins: true, hasSplitInOrdinaryWindow: true))
        #expect(events == [.dayOfUse, .milestone(.firstPin), .milestone(.firstSplitView)])
        // Milestones still count while a private window is key, as on the Mac.
        let privately = LoyaltyEarning.tickEvents(LoyaltySnapshot(keyWindowIsPrivate: true, hasPins: true))
        #expect(privately == [.milestone(.firstPin)])
    }

    @Test func eachLevelAfterTheFirstUnlocksOneColourway() {
        #expect(LoyaltyEarning.unlock(for: LoyaltyLevel.level(number: 1)) == nil)
        for level in LoyaltyLevel.all.dropFirst() {
            #expect(LoyaltyEarning.unlock(for: level)?.unlockLevel == level.number)
        }
    }

    @MainActor @Test func ticksPayADayAndAMilestoneOnce() {
        let engine = LoyaltyEngine(deviceID: "test", platform: .mac, fileURL: nil)
        let snapshot = LoyaltySnapshot(hasPins: true)
        for _ in 0..<3 {
            for event in LoyaltyEarning.tickEvents(snapshot) { engine.record(event) }
        }
        #expect(engine.totals.points == LoyaltyRules.dailyPoints + LoyaltyRules.milestonePoints)
    }
}
