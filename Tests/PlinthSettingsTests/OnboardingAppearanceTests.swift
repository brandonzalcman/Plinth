import Foundation
import Testing
@testable import PlinthSettings

private func tempDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "plinth-onb-\(UUID().uuidString)", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite @MainActor struct AppearanceSettingTests {
    @Test func defaultsToSystemAndNotOnboarded() {
        #expect(AppSettings.defaults.appearance == .system)
        #expect(!AppSettings.defaults.hasCompletedOnboarding)
    }

    @Test func persistsAcrossReload() {
        let dir = tempDirectory()
        let store = SettingsStore(storageDirectory: dir)
        store.update { $0.appearance = .dark; $0.hasCompletedOnboarding = true }
        let reloaded = SettingsStore(storageDirectory: dir)
        #expect(reloaded.value.appearance == .dark)
        #expect(reloaded.value.hasCompletedOnboarding)
    }

    @Test func unknownAppearanceFallsBackToSystem() throws {
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"appearance":"sepia"}"#.utf8))
        #expect(s.appearance == .system)
    }

    @Test func resetKeepsOnboardingFlagButResetsAppearance() {
        let store = SettingsStore(storageDirectory: tempDirectory())
        store.update { $0.appearance = .light; $0.hasCompletedOnboarding = true; $0.accent = .pink }
        store.resetToDefaults()
        #expect(store.value.appearance == .system)
        #expect(store.value.accent == .blue)
        #expect(store.value.hasCompletedOnboarding)
    }
}

@Suite struct OnboardingFlowTests {
    @Test func startsWithIntroThenCards() {
        var flow = OnboardingFlow()
        #expect(flow.phase == .intro && flow.currentCard == nil)
        flow.introDone()
        #expect(flow.cardIndex == 0 && flow.currentCard == .bar)
    }

    @Test func walksForwardAndBackAndFinishesOnLastCard() {
        var flow = OnboardingFlow()
        flow.introDone()
        for _ in 1..<OnboardingFlow.cards.count { flow.next() }
        #expect(flow.isLastCard && flow.currentCard == .getStarted && !flow.isFinished)
        flow.back()
        #expect(!flow.isLastCard)
        flow.next(); flow.next()
        #expect(flow.isFinished)
        flow.back(); flow.next()
        #expect(flow.isFinished)
    }

    @Test func backStopsAtFirstCard() {
        var flow = OnboardingFlow(startingAtCard: 0)
        flow.back()
        #expect(flow.cardIndex == 0)
    }

    @Test func skipFinishesFromAnywhere() {
        var a = OnboardingFlow(); a.skip(); #expect(a.isFinished)
        var b = OnboardingFlow(startingAtCard: 2); b.skip(); #expect(b.isFinished)
    }

    @Test func startingCardClamps() {
        #expect(OnboardingFlow(startingAtCard: 99).isLastCard)
        #expect(OnboardingFlow(startingAtCard: -3).cardIndex == 0)
        #expect(OnboardingFlow(startingAtCard: nil).phase == .intro)
    }

    @Test func showsOnlyForANewProfile() {
        #expect(OnboardingFlow.shouldShowAtLaunch(hasCompleted: false, profileHadWindows: false))
        #expect(!OnboardingFlow.shouldShowAtLaunch(hasCompleted: true, profileHadWindows: false))
        #expect(!OnboardingFlow.shouldShowAtLaunch(hasCompleted: false, profileHadWindows: true))
    }
}
