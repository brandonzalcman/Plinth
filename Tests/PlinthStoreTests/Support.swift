import Foundation
import Testing
import PlinthModel
@testable import PlinthStore

struct FakeIdentity: SiteIdentifying {
    func key(for url: URL) -> SiteKey {
        guard var host = url.host?.lowercased(), !host.isEmpty else { return SiteKey(url.scheme ?? "unknown") }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return SiteKey(host)
    }
    func siteName(for key: SiteKey) -> String {
        let label = key.host.split(separator: ".").first.map(String.init) ?? key.host
        return label.prefix(1).uppercased() + label.dropFirst()
    }
}

/// "Seat map - Example" with site "Example" -> "Seat map". No title -> last path component, else host.
struct FakeNamer: PageNaming {
    func name(title: String, url: URL, siteName: String) -> String {
        var t = title
        let suffix = " - " + siteName
        if t.hasSuffix(suffix) { t.removeLast(suffix.count) }
        if !t.isEmpty { return t }
        let last = url.lastPathComponent
        if !last.isEmpty && last != "/" { return last }
        return url.host ?? url.absoluteString
    }
}

final class FakeFader: FadeEvaluating, @unchecked Sendable {
    struct Call { var sites: [Site]; var stats: [SiteKey: Usage]; var visible: Set<PageID>; var now: Date }
    var calls: [Call] = []
    var script: ([Site], Set<PageID>) -> FadeVerdict = { _, _ in FadeVerdict() }

    func evaluate(sites: [Site], stats: [SiteKey: Usage], visible: Set<PageID>, now: Date) -> FadeVerdict {
        calls.append(Call(sites: sites, stats: stats, visible: visible, now: now))
        return script(sites, visible)
    }
}

final class Clock: @unchecked Sendable {
    var t = Date(timeIntervalSinceReferenceDate: 800_000_000)
    func advance(_ seconds: TimeInterval = 60) { t += seconds }
}

@MainActor final class EventLog {
    var events: [StoreEvent] = []
    func clear() { events = [] }
}

@MainActor struct Rig {
    let store: BrowserStore
    let fader = FakeFader()
    let clock = Clock()
    let log = EventLog()

    init(dir: URL? = nil) {
        let clock = self.clock
        store = BrowserStore(identity: FakeIdentity(), namer: FakeNamer(), fader: fader, storageDirectory: dir, now: { clock.t })
        let log = self.log
        store.onEvent = { log.events.append($0) }
    }

    /// Opens a page after moving the clock on, so every page has its own `lastUsed`.
    @discardableResult func open(_ s: String, in w: WindowID, select: Bool = true, opener: PageID? = nil) -> PageID {
        clock.advance()
        return store.openPage(url: u(s), in: w, select: select, opener: opener)
    }

    func ok(_ comment: Comment? = nil, sourceLocation: SourceLocation = #_sourceLocation) {
        let problems = store.checkInvariants()
        #expect(problems.isEmpty, comment, sourceLocation: sourceLocation)
    }

    /// The bar as text: "a.com[p1,p2] b.com[p3]".
    func bar(_ w: WindowID) -> String {
        (store.window(w)?.sites ?? []).map { site in
            site.key.host + "[" + site.pages.map(\.name).joined(separator: ",") + "]"
        }.joined(separator: " ")
    }
}

func u(_ s: String) -> URL { URL(string: s)! }

func tempDir() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("plinth-store-tests-\(UUID().uuidString)")
}

/// SplitMix64: a small seeded generator so the random test is repeatable.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
