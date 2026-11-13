import Foundation
import Testing
import PlinthModel
@testable import PlinthStore

/// Writes a synthetic, duplicate-heavy profile for trying the command bar and the history panel by
/// hand. Does nothing unless `PLINTH_SEED_DIR` names a directory:
///
///     PLINTH_SEED_DIR=/tmp/plinth-seed swift test --filter SeedFixture
///     PLINTH_STORAGE=/tmp/plinth-seed build/Plinth.app/Contents/MacOS/Plinth
///
/// `PLINTH_SEED_COUNT` (default 3000) sets the number of visits. Nothing here is real data.
@MainActor
struct SeedFixture {
    /// The synthetic history, newest first: a few sites visited constantly under many spellings
    /// (fragments, trailing slashes, tracking parameters, http/https, www), plus a long tail.
    static func history(count: Int, now: Date) -> [HistoryEntry] {
        struct Site { var host: String; var title: String; var paths: [String]; var weight: Int }
        let sites = [
            Site(host: "github.com", title: "GitHub", paths: ["", "/acme/plinth", "/acme/plinth/pulls", "/acme/plinth/issues/12", "/acme/website", "/notifications"], weight: 30),
            Site(host: "news.ycombinator.com", title: "Hacker News", paths: ["", "/newest", "/item?id=1001", "/item?id=1002"], weight: 14),
            Site(host: "developer.apple.com", title: "Apple Developer Documentation", paths: ["/documentation/swiftui", "/documentation/webkit", "/documentation/swift", "/news"], weight: 12),
            Site(host: "en.wikipedia.org", title: "Wikipedia", paths: ["/wiki/Browser", "/wiki/WebKit", "/wiki/Swift_(programming_language)", "/wiki/Frecency"], weight: 8),
            Site(host: "www.nytimes.com", title: "The New York Times", paths: ["", "/section/world", "/section/technology"], weight: 8),
            Site(host: "mail.example.com", title: "Inbox", paths: ["/mail/u/0/", "/mail/u/0/#inbox", "/mail/u/0/#starred"], weight: 10),
            Site(host: "docs.example.org", title: "Example Docs", paths: ["/guide", "/guide/install", "/guide/config", "/api"], weight: 6),
        ]
        let variants: [(String, (String) -> String)] = [
            ("https://", { $0 }), ("https://www.", { $0 }), ("http://", { $0 }),
            ("https://", { $0 + "#top" }), ("https://", { $0.hasSuffix("/") ? $0 : $0 + "/" }),
            ("https://", { $0 + (($0.contains("?")) ? "&utm_source=newsletter" : "?utm_source=newsletter") }),
        ]
        var entries: [HistoryEntry] = []
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func next() -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int(seed >> 33) }
        let totalWeight = sites.reduce(0) { $0 + $1.weight }
        for i in 0..<count {
            let minutesAgo = Double(i) * (60.0 * 24 * 45 / Double(count)) + Double(next() % 20)
            let at = now.addingTimeInterval(-minutesAgo * 60)
            if next() % 10 == 0 {
                // The long tail: one-off pages on sites seen a handful of times.
                let n = next() % 400
                let url = URL(string: "https://tail\(n).example.net/read/\(next() % 5)")!
                entries.append(HistoryEntry(url: url, title: "Tail article \(n)", name: "Tail article \(n)", key: SiteKey("tail\(n).example.net"), visitedAt: at, dwell: 5))
                continue
            }
            var pick = next() % totalWeight
            var site = sites[0]
            for candidate in sites { if pick < candidate.weight { site = candidate; break }; pick -= candidate.weight }
            let path = site.paths[next() % site.paths.count]
            let variant = variants[next() % variants.count]
            let spelled = variant.0 + site.host.replacingOccurrences(of: "www.", with: "") + variant.1(path)
            guard let url = URL(string: spelled) else { continue }
            let title = path.isEmpty ? site.title : "\(site.title) - \(path.split(separator: "/").last.map(String.init) ?? "")"
            entries.append(HistoryEntry(url: url, title: title, name: title, key: SiteKey(site.host.replacingOccurrences(of: "www.", with: "")),
                                        visitedAt: at, dwell: Double(next() % 90)))
        }
        return entries.sorted { $0.visitedAt > $1.visitedAt }
    }

    @Test func writeSeedProfile() throws {
        guard let path = ProcessInfo.processInfo.environment["PLINTH_SEED_DIR"], !path.isEmpty else { return }
        let count = Int(ProcessInfo.processInfo.environment["PLINTH_SEED_COUNT"] ?? "") ?? 3_000
        let dir = URL(fileURLWithPath: path)
        let now = Date()
        let store = BrowserStore(identity: FakeIdentity(), namer: FakeNamer(), fader: FakeFader(), storageDirectory: dir, now: { now })
        store.history = Self.history(count: count, now: now)
        // A few open pages, so the "Open" group shows up in the command bar.
        let window = store.createWindow()
        store.openPage(url: URL(string: "https://developer.apple.com/documentation/swiftui")!, in: window, select: true, opener: nil)
        store.openPage(url: URL(string: "https://docs.example.org/guide")!, in: window, select: false, opener: nil)
        try store.save()
    }

    @Test func fixtureIsDuplicateHeavy() {
        let now = Date()
        let history = Self.history(count: 3_000, now: now)
        let pages = Set(history.map { URLCanonical.key($0.url) })
        #expect(history.count == 3_000)
        #expect(pages.count < 700, "3000 visits should be far fewer distinct pages")
    }
}
