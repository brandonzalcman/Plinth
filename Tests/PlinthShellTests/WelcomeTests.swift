import Testing
@testable import PlinthShell

@Suite struct WelcomeFlowTests {
    @Test func startsWithTheIntroThenTheFirstCard() {
        var flow = WelcomeFlow()
        #expect(flow.phase == .intro)
        #expect(flow.currentCard == nil)
        flow.introDone()
        #expect(flow.currentCard == .layout)
        #expect(flow.isFirstCard)
    }

    @Test func theCardsCoverWhatIsNewHereInOrder() {
        #expect(WelcomeFlow.cards == [.layout, .sidebar, .railAndSplit, .fading, .meaning, .extensions, .points, .getStarted])
        for card in WelcomeFlow.cards {
            #expect(!card.title.isEmpty)
            #expect(!card.message.isEmpty)
        }
    }

    @Test func nextWalksEveryCardThenFinishes() {
        var flow = WelcomeFlow()
        flow.next()
        var seen: [WelcomeCard] = []
        while let card = flow.currentCard {
            seen.append(card)
            flow.next()
        }
        #expect(seen == WelcomeFlow.cards)
        #expect(flow.isFinished)
        flow.next()
        #expect(flow.isFinished)
    }

    @Test func backStopsAtTheFirstCard() {
        var flow = WelcomeFlow(startingAtCard: 1)
        flow.back()
        #expect(flow.cardIndex == 0)
        flow.back()
        #expect(flow.cardIndex == 0)
    }

    @Test func theLastCardFinishesOnNext() {
        var flow = WelcomeFlow(startingAtCard: WelcomeFlow.cards.count - 1)
        #expect(flow.isLastCard)
        #expect(flow.currentCard == .getStarted)
        flow.next()
        #expect(flow.isFinished)
    }

    @Test func aStartingCardOutOfRangeClamps() {
        #expect(WelcomeFlow(startingAtCard: -3).cardIndex == 0)
        #expect(WelcomeFlow(startingAtCard: 99).cardIndex == WelcomeFlow.cards.count - 1)
        #expect(WelcomeFlow(startingAtCard: nil).phase == .intro)
    }

    @Test func stepDotsJumpToACardButNotPastTheEnds() {
        var flow = WelcomeFlow()
        flow.go(to: 4)
        #expect(flow.currentCard == .meaning)
        flow.go(to: 40)
        #expect(flow.cardIndex == 4)
        flow.skip()
        flow.go(to: 1)
        #expect(flow.isFinished)
    }

    @Test func skipFinishesFromAnywhere() {
        var intro = WelcomeFlow()
        intro.skip()
        #expect(intro.isFinished)
        var middle = WelcomeFlow(startingAtCard: 3)
        middle.skip()
        #expect(middle.isFinished)
    }
}

@Suite struct WelcomeLaunchTests {
    @Test func aNewProfileSeesTheGuide() {
        #expect(WelcomeLaunch.decide(hasCompleted: false, profileHadWindows: false, override: nil, scripted: false) == .show)
    }

    @Test func aProfileFromBeforeTheGuideIsMarkedAsSeen() {
        #expect(WelcomeLaunch.decide(hasCompleted: false, profileHadWindows: true, override: nil, scripted: false) == .markSeen)
    }

    @Test func onceSeenItStaysAway() {
        #expect(WelcomeLaunch.decide(hasCompleted: true, profileHadWindows: false, override: nil, scripted: false) == .nothing)
        #expect(WelcomeLaunch.decide(hasCompleted: true, profileHadWindows: true, override: nil, scripted: false) == .nothing)
    }

    @Test func scriptedLaunchesLeaveItOutAndRememberNothing() {
        #expect(WelcomeLaunch.decide(hasCompleted: false, profileHadWindows: false, override: nil, scripted: true) == .nothing)
        #expect(WelcomeLaunch.decide(hasCompleted: false, profileHadWindows: true, override: nil, scripted: true) == .nothing)
    }

    @Test func theTestSwitchWins() {
        #expect(WelcomeLaunch.decide(hasCompleted: true, profileHadWindows: true, override: "1", scripted: true) == .show)
        #expect(WelcomeLaunch.decide(hasCompleted: false, profileHadWindows: false, override: "0", scripted: false) == .nothing)
    }
}
