import Foundation
import Testing
import PlinthModel
@testable import PlinthAI

func tempDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "plinth-ai-tests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func visit(_ url: String, title: String, dwell: TimeInterval = 60, key: String? = nil) -> HistoryEntry {
    let u = URL(string: url)!
    return HistoryEntry(url: u, title: title, name: title, key: SiteKey(key ?? u.host() ?? "x"),
                        visitedAt: Date(timeIntervalSince1970: 1_000), dwell: dwell)
}

/// A clock that advances one second per reading.
final class TickClock: Sendable {
    private let base = Date(timeIntervalSince1970: 2_000_000)
    private let ticks = Counter()
    func now() -> Date { base.addingTimeInterval(TimeInterval(ticks.increment())) }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() -> Int { lock.withLock { value += 1; return value } }
}

@Suite struct SemanticIndexTests {
    @Test func thirtySecondRuleAndWebOnly() {
        #expect(SemanticIndex.shouldIndex(visit("https://a.com", title: "A", dwell: 30)))
        #expect(SemanticIndex.shouldIndex(visit("http://a.com", title: "A", dwell: 300)))
        #expect(!SemanticIndex.shouldIndex(visit("https://a.com", title: "A", dwell: 29.9)))
        #expect(!SemanticIndex.shouldIndex(visit("file:///tmp/a.html", title: "A", dwell: 300)))
        #expect(!SemanticIndex.shouldIndex(visit("about:blank", title: "A", dwell: 300)))
    }

    @Test func normalisedKeys() {
        let k = SemanticIndex.normalizedKey(for:)
        #expect(k(URL(string: "HTTPS://Example.COM/Path/#frag")!) == "https://example.com/Path")
        #expect(k(URL(string: "https://example.com:443")!) == "https://example.com/")
        #expect(k(URL(string: "https://example.com/a?q=1")!) == "https://example.com/a?q=1")
        #expect(k(URL(string: "https://example.com/a/")!) == k(URL(string: "https://example.com/a")!))
    }

    @Test func embeddingInputIsTitlePlusPrefix() {
        let input = SemanticIndex.embeddingInput(title: " Title ", text: String(repeating: "x", count: 5000))
        #expect(input.hasPrefix("Title\n"))
        #expect(input.count == "Title\n".count + SemanticIndex.textPrefixLength)
    }

    @Test func addSearchRemove() async {
        let index = SemanticIndex(storageDirectory: tempDirectory(), embedder: FakeEmbedder(), saveDelay: .zero)
        #expect(await index.add(entry: visit("https://cooking.com/pasta", title: "Fresh pasta recipe"),
                                text: "How to make fresh pasta dough with eggs and flour, then roll and cut tagliatelle."))
        #expect(await index.add(entry: visit("https://space.com/mars", title: "Mars rover news"),
                                text: "The rover drilled a rock sample in the Martian crater and sent images home."))
        #expect(await !index.add(entry: visit("https://short.com", title: "Quick look", dwell: 5), text: "pasta"))
        #expect(await index.count == 2)

        let hits = await index.search("pasta dough eggs flour", limit: 5)
        #expect(hits.first?.url.absoluteString == "https://cooking.com/pasta")
        #expect(hits.first?.title == "Fresh pasta recipe")
        #expect(hits.first?.key == SiteKey("cooking.com"))
        #expect(!hits.contains { $0.url.host() == "space.com" })  // below the minimum score

        #expect(await index.search("", limit: 5).isEmpty)
        #expect(await index.search("pasta", limit: 0).isEmpty)
        #expect(await index.search("zzzz qqqq", limit: 5).isEmpty)

        #expect(await index.contains(url: URL(string: "https://cooking.com/pasta#top")!))
        await index.remove(url: URL(string: "https://cooking.com/pasta/")!)
        #expect(await !index.contains(url: URL(string: "https://cooking.com/pasta")!))
        await index.removeAll()
        #expect(await index.count == 0)
    }

    @Test func reAddingTheSameUrlReplaces() async {
        let index = SemanticIndex(storageDirectory: tempDirectory(), embedder: FakeEmbedder(), saveDelay: .zero)
        let first = visit("https://a.com/p", title: "Old title")
        await index.add(entry: first, text: "gardening tomatoes")
        let second = visit("https://a.com/p#x", title: "New title")
        await index.add(entry: second, text: "gardening tomatoes")
        #expect(await index.count == 1)
        let entry = await index.entry(for: URL(string: "https://a.com/p")!)
        #expect(entry?.title == "New title")
        #expect(entry?.historyEntryID == second.id)
    }

    @Test func unavailableEmbedderIndexesNothing() async {
        let index = SemanticIndex(storageDirectory: tempDirectory(), embedder: FakeEmbedder(isAvailable: false), saveDelay: .zero)
        #expect(await !index.add(entry: visit("https://a.com", title: "Title words"), text: "body words"))
        #expect(await index.search("title", limit: 5).isEmpty)
    }

    @Test func capDropsOldestEntries() async {
        let clock = TickClock()
        let index = SemanticIndex(storageDirectory: tempDirectory(), embedder: FakeEmbedder(), maxEntries: 3,
                                  saveDelay: .zero, now: { clock.now() })
        for i in 0..<5 { await index.add(entry: visit("https://a.com/\(i)", title: "Page number \(i)"), text: "common words here") }
        #expect(await index.count == 3)
        #expect(await !index.contains(url: URL(string: "https://a.com/0")!))
        #expect(await !index.contains(url: URL(string: "https://a.com/1")!))
        #expect(await index.contains(url: URL(string: "https://a.com/4")!))
    }

    @Test func persistenceRoundTrip() async throws {
        let dir = tempDirectory()
        let entry = visit("https://cooking.com/pasta", title: "Fresh pasta recipe")
        do {
            let index = SemanticIndex(storageDirectory: dir, embedder: FakeEmbedder(), saveDelay: .seconds(60))
            await index.add(entry: entry, text: "pasta dough eggs flour")
            await index.add(entry: visit("https://space.com/mars", title: "Mars rover"), text: "rover crater")
            // Not yet written (debounced) until flushed.
            #expect(!FileManager.default.fileExists(atPath: index.fileURL.path()))
            await index.flush()
            #expect(FileManager.default.fileExists(atPath: index.fileURL.path()))
        }
        let reloaded = SemanticIndex(storageDirectory: dir, embedder: FakeEmbedder())
        #expect(await reloaded.count == 2)
        let stored = await reloaded.entry(for: entry.url)
        #expect(stored?.historyEntryID == entry.id)
        #expect(stored?.site == SiteKey("cooking.com"))
        let original = await FakeEmbedder().embed(SemanticIndex.embeddingInput(title: entry.title, text: "pasta dough eggs flour"))!
        #expect(stored?.vector == SemanticIndex.normalized(original))
        #expect(await reloaded.search("fresh pasta", limit: 1).first?.url == entry.url)
    }

    @Test func debouncedSaveHappensOnItsOwn() async throws {
        let dir = tempDirectory()
        let index = SemanticIndex(storageDirectory: dir, embedder: FakeEmbedder(), saveDelay: .milliseconds(20))
        await index.add(entry: visit("https://a.com", title: "Garden tomatoes"), text: "soil")
        try await Task.sleep(for: .milliseconds(300))
        #expect(FileManager.default.fileExists(atPath: index.fileURL.path()))
        #expect(await SemanticIndex(storageDirectory: dir, embedder: FakeEmbedder()).count == 1)
    }

    @Test func corruptFileLoadsEmpty() async throws {
        let dir = tempDirectory()
        try Data("not json".utf8).write(to: dir.appending(path: SemanticIndex.fileName))
        let index = SemanticIndex(storageDirectory: dir, embedder: FakeEmbedder())
        #expect(await index.count == 0)
    }

    @Test func removeSite() async {
        let index = SemanticIndex(storageDirectory: tempDirectory(), embedder: FakeEmbedder(), saveDelay: .zero)
        await index.add(entry: visit("https://a.com/1", title: "One alpha"), text: "x words")
        await index.add(entry: visit("https://a.com/2", title: "Two alpha"), text: "x words")
        await index.add(entry: visit("https://b.com/1", title: "Three alpha"), text: "x words")
        await index.remove(site: SiteKey("a.com"))
        #expect(await index.count == 1)
    }

    @Test func fakeEmbedderSimilarity() async {
        let e = FakeEmbedder()
        let a = SemanticIndex.normalized(await e.embed("pasta recipe with eggs")!)!
        let b = SemanticIndex.normalized(await e.embed("an eggs pasta recipe")!)!
        let c = SemanticIndex.normalized(await e.embed("rocket launch schedule")!)!
        #expect(SemanticIndex.dot(a, b) > 0.9)
        #expect(SemanticIndex.dot(a, c) < 0.3)
        #expect(await e.embed("a an") == nil)
    }
}

@Suite struct SemanticPassageTests {
    @Test func passagesAreTitleThenDistinctShortPieces() {
        let text = (0..<40).map { "Paragraph \($0) talks about something else entirely, at some length." }.joined(separator: "\n\n")
        let pieces = SemanticIndex.passages(title: " Sourdough ", text: text)
        #expect(pieces.first == "Sourdough")
        #expect(pieces.count == 1 + SemanticIndex.maxPassages)
        #expect(pieces.dropFirst().allSatisfy { $0.count <= 300 })
        #expect(Set(pieces).count == pieces.count)
    }

    @Test func aShortQueryFindsAPageByItsTitleDespiteLongBodyText() async {
        let index = SemanticIndex(storageDirectory: tempDirectory(), embedder: FakeEmbedder(), saveDelay: .zero)
        let body = String(repeating: "Mix flour water starter fold proof overnight. ", count: 200)
        _ = await index.add(entry: visit("https://bake.example/s", title: "Sourdough bread recipe"), text: body)
        _ = await index.add(entry: visit("https://rust.example/b", title: "Rust borrowing"), text: String(repeating: "references checker ", count: 300))
        let hits = await index.search("sourdough", limit: 5)
        #expect(hits.first?.url.host() == "bake.example")
        // Passage vectors survive a reload.
        let reloaded = SemanticIndex(storageDirectory: index.fileURL.deletingLastPathComponent(), embedder: FakeEmbedder(), saveDelay: .zero)
        #expect(await reloaded.entry(for: URL(string: "https://bake.example/s")!)?.passageVectors.isEmpty == false)
    }
}
