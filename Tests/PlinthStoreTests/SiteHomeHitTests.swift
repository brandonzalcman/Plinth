import Foundation
import Testing
import PlinthModel
@testable import PlinthStore

@MainActor struct SiteHomeHitTests {
    private func entry(_ url: String, title: String, daysAgo: Double = 1) -> HistoryEntry {
        let link = u(url)
        return HistoryEntry(url: link, title: title, name: title, key: SiteKey(URLCanonical.host(link)),
                            visitedAt: Date().addingTimeInterval(-daysAgo * 86_400), dwell: 0)
    }

    @Test func aWellKnownSiteLeadsEvenWithNoHistory() {
        let rig = Rig()
        let results = rig.store.suggestions(for: "github")
        #expect(results.first?.isTopHit == true)
        #expect(results.first?.title == "GitHub")
        #expect(results.first?.target == .history(u("https://github.com/")))
    }

    @Test func aFewLettersOrAnAliasAreEnough() {
        let rig = Rig()
        #expect(rig.store.suggestions(for: "yt").first?.subtitle == "youtube.com")
        #expect(rig.store.suggestions(for: "gith").first?.subtitle == "github.com")
        #expect(rig.store.suggestions(for: "stackov").first?.subtitle == "stackoverflow.com")
    }

    @Test func historyDeepLinksFollowTheFrontPageAndInstallersAreLeftOut() {
        let rig = Rig()
        rig.store.history = [
            entry("https://github.com/brandonzalcman/Plinth/releases/latest/download/Plinth.dmg", title: "a calm browser for Mac"),
            entry("https://release-assets.githubusercontent.com/x/y.zip", title: "a calm browser for Mac"),
            entry("https://github.com/brandonzalcman/Plinth", title: "Plinth"),
        ]
        let results = rig.store.suggestions(for: "github")
        #expect(results.first?.subtitle == "github.com")
        #expect(results.contains { $0.subtitle.hasSuffix(".dmg") || $0.subtitle.hasSuffix(".zip") } == false)
        #expect(results.contains { $0.subtitle == "github.com/brandonzalcman/Plinth" })
    }

    @Test func aHostVisitedOftenBeatsTheTable() {
        let rig = Rig()
        rig.store.history = (0..<8).map { entry("https://gitea.example.org/repo\($0)", title: "Repo \($0)", daysAgo: Double($0)) }
        let results = rig.store.suggestions(for: "git")
        #expect(results.first?.subtitle == "gitea.example.org")
    }

    @Test func addressesAndSeveralWordsGetNoSiteShortcut() {
        let rig = Rig()
        #expect(rig.store.suggestions(for: "github.com/foo").first?.isTopHit != true)
        #expect(rig.store.suggestions(for: "github login").first?.isTopHit != true)
    }
}
