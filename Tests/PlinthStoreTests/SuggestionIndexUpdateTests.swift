import Foundation
import Testing
import PlinthModel
@testable import PlinthStore

@Suite struct SuggestionIndexUpdateTests {
    private let base = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func entry(_ host: String, minutesAgo: Double) -> HistoryEntry {
        HistoryEntry(url: u("https://\(host)/"), title: host, name: host, key: SiteKey(host),
                     visitedAt: base.addingTimeInterval(-minutesAgo * 60))
    }

    @Test func atTheCapOneNewVisitStaysIncremental() {
        let old = (1...5).map { entry("h\($0).com", minutesAgo: Double($0)) }
        var index = SuggestionIndex(history: old)
        // The capped list: one new entry in front, the oldest one dropped.
        let capped = [entry("new.com", minutesAgo: 0)] + old.dropLast()
        index.update(with: capped)
        #expect(index.aggregates[URLCanonical.key(u("https://new.com/"))] != nil)
        // A full rebuild would have forgotten the dropped entry; the incremental path keeps it.
        #expect(index.aggregates[URLCanonical.key(u("https://h5.com/"))] != nil)
        #expect(index.aggregates.count == 6)
    }

    @Test func aMergeWithOlderEntriesRebuilds() {
        let old = [entry("b.com", minutesAgo: 10), entry("c.com", minutesAgo: 20)]
        var index = SuggestionIndex(history: old)
        let merged = [entry("new.com", minutesAgo: 0), old[0], entry("older.com", minutesAgo: 15), old[1]]
        index.update(with: merged)
        #expect(index.aggregates.count == 4)
    }
}
