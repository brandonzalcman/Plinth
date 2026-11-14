import Foundation
import Testing
import PlinthModel
@testable import PlinthStore

@Suite struct SuggestionIndexUpdateTests {
    private let base = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func entry(_ host: String, minutesAgo: Double, dwell: TimeInterval = 0) -> HistoryEntry {
        HistoryEntry(url: u("https://\(host)/"), title: host, name: host, key: SiteKey(host),
                     visitedAt: base.addingTimeInterval(-minutesAgo * 60), dwell: dwell)
    }

    /// The incremental index must equal one built from scratch.
    private func expectSameAsRebuild(_ index: SuggestionIndex, _ history: [HistoryEntry], sourceLocation: SourceLocation = #_sourceLocation) {
        let fresh = SuggestionIndex(history: history)
        #expect(Set(index.aggregates.keys) == Set(fresh.aggregates.keys), sourceLocation: sourceLocation)
        for (key, a) in fresh.aggregates {
            guard let b = index.aggregates[key] else { continue }
            #expect(a.visits == b.visits && a.lastVisit == b.lastVisit && a.dwell == b.dwell
                    && a.samples.sorted() == b.samples.sorted(), "\(key)", sourceLocation: sourceLocation)
        }
    }

    private func list(_ n: Int) -> [HistoryEntry] { (1...n).map { entry("h\($0).com", minutesAgo: Double($0)) } }

    @Test func atTheCapOneNewVisitDropsTheOldestFromTheIndex() {
        let old = list(5)
        var index = SuggestionIndex(history: old)
        let capped = [entry("new.com", minutesAgo: 0)] + old.dropLast()
        index.update(with: capped)
        #expect(index.aggregates[URLCanonical.key(u("https://new.com/"))] != nil)
        #expect(index.aggregates[URLCanonical.key(u("https://h5.com/"))] == nil)
        expectSameAsRebuild(index, capped)
    }

    @Test func repeatVisitsAtTheCapKeepCountsRight() {
        var old = (0..<6).map { entry(($0 % 2 == 0) ? "a.com" : "b.com", minutesAgo: Double($0 + 1), dwell: 10) }
        var index = SuggestionIndex(history: old)
        for step in 1...4 {   // each new visit pushes the oldest off the end
            old = [entry("a.com", minutesAgo: -Double(step), dwell: 5)] + old.dropLast()
            index.update(with: old)
            expectSameAsRebuild(index, old)
        }
    }

    @Test func aMergeAtTheCapStillIndexesTheOlderRemoteVisit() {
        let old = list(5)
        var index = SuggestionIndex(history: old)
        // One new local visit in front; one remote visit older than most of the list sits inside it; same length.
        let remote = entry("remote.com", minutesAgo: 3.5)
        let merged = Array(([entry("new.com", minutesAgo: 0)] + old + [remote]).sorted { $0.visitedAt > $1.visitedAt }.prefix(5))
        index.update(with: merged)
        #expect(index.aggregates[URLCanonical.key(u("https://remote.com/"))] != nil)
        expectSameAsRebuild(index, merged)
    }

    @Test func aDeletedEntryLeavesTheIndexEvenWhenAVisitWasAdded() {
        let old = list(5)
        var index = SuggestionIndex(history: old)
        var changed = old
        changed.remove(at: 2) // h3.com deleted
        changed.insert(entry("new.com", minutesAgo: 0), at: 0)
        index.update(with: changed)
        #expect(index.aggregates[URLCanonical.key(u("https://h3.com/"))] == nil)
        expectSameAsRebuild(index, changed)
    }

    @Test func aRangedDeleteFromAnotherDeviceWithNewVisitsRebuilds() {
        let old = list(6)
        var index = SuggestionIndex(history: old)
        // Entries 2 and 3 removed from the middle, plus a new visit.
        let changed = [entry("new.com", minutesAgo: 0), old[0], old[3], old[4], old[5]]
        index.update(with: changed)
        #expect(index.aggregates[URLCanonical.key(u("https://h2.com/"))] == nil)
        expectSameAsRebuild(index, changed)
    }

    @Test func aMergeWithOlderEntriesRebuilds() {
        let old = [entry("b.com", minutesAgo: 10), entry("c.com", minutesAgo: 20)]
        var index = SuggestionIndex(history: old)
        let merged = [entry("new.com", minutesAgo: 0), old[0], entry("older.com", minutesAgo: 15), old[1]]
        index.update(with: merged)
        #expect(index.aggregates.count == 4)
        expectSameAsRebuild(index, merged)
    }
}

@Suite struct SuggestionIndexExactListTests {
    private let base = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private func entry(_ host: String, minutesAgo: Double, dwell: TimeInterval = 0) -> HistoryEntry {
        HistoryEntry(url: u("https://\(host)/"), title: host, name: host, key: SiteKey(host),
                     visitedAt: base.addingTimeInterval(-minutesAgo * 60), dwell: dwell)
    }

    @Test func removedEntriesAndSameNumberOfOlderAddedOnesAreReindexed() {
        let old = (1...6).map { entry("h\($0).com", minutesAgo: Double($0)) }
        var index = SuggestionIndex(history: old)
        // h3 removed; an older remote visit added at the end; same length, same first and last... last differs here,
        // so also try with the remote visit inserted before the last one.
        var changed = old
        changed.remove(at: 2)
        changed.insert(entry("remote.com", minutesAgo: 5.5), at: 4)
        #expect(changed.count == old.count && changed.first?.id == old.first?.id && changed.last?.id == old.last?.id)
        index.update(with: changed)
        #expect(index.aggregates[URLCanonical.key(u("https://h3.com/"))] == nil)
        #expect(index.aggregates[URLCanonical.key(u("https://remote.com/"))] != nil)
    }

    @Test func dwellOfTheNewestVisitReachesTheIndex() {
        var list = [entry("a.com", minutesAgo: 0), entry("b.com", minutesAgo: 5)]
        var index = SuggestionIndex(history: list)
        list[0].dwell = 90
        index.update(with: list)
        #expect(index.aggregates[URLCanonical.key(u("https://a.com/"))]?.dwell == 90)
        // After a new visit in front, the old newest one is still refreshed.
        list[0].dwell = 120
        list.insert(entry("c.com", minutesAgo: -1), at: 0)
        index.update(with: list)
        #expect(index.aggregates[URLCanonical.key(u("https://a.com/"))]?.dwell == 120)
    }
}
