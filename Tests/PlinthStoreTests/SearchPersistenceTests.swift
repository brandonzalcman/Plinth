import Foundation
import Testing
import PlinthModel
@testable import PlinthStore

@MainActor @Suite struct SearchTests {
    /// One "report" in each band: an open page, a pin, a shelved page and a history-only URL.
    func populated() -> (Rig, WindowID, open: PageID, pin: SiteID, shelved: PageID) {
        let r = Rig()
        let w = r.store.createWindow()
        let gone = r.open("https://old.com/report-archive", in: w)
        r.store.closePage(gone)
        let pinned = r.open("https://pin.com/report-hub", in: w)
        r.store.pin(site: r.store.window(w)!.sites[0].id)
        let shelved = r.open("https://shelf.com/report-draft", in: w)
        let open = r.open("https://open.com/report-live", in: w)
        r.open("https://other.com/unrelated", in: w)
        r.store.shelve(site: r.store.window(w)!.site(containing: shelved)!.id)
        _ = pinned
        return (r, w, open, r.store.pins[0].id, shelved)
    }

    @Test func bandsComeInOrder() {
        let (r, w, open, pin, shelved) = populated()
        let results = r.store.search("report")
        #expect(results.map(\.target) == [
            .openPage(open, window: w),
            .pin(pin),
            .shelf(entry: r.store.shelf[0].id, page: shelved),
            .history(u("https://old.com/report-archive")),
        ])
        #expect(Set(results.map(\.id)).count == 4)
        #expect(results[0].subtitle == "open.com/report-live")
        #expect(results[0].key == SiteKey("open.com"))
        r.ok()
    }

    @Test func emptyQueryAndNoMatch() {
        let (r, _, _, _, _) = populated()
        #expect(r.store.search("").isEmpty)
        #expect(r.store.search("   ").isEmpty)
        #expect(r.store.search("zebra").isEmpty)
        #expect(r.store.search("report", limit: 0).isEmpty)
    }

    @Test func limitIsRespected() {
        let (r, _, _, _, _) = populated()
        #expect(r.store.search("report", limit: 2).count == 2)
        #expect(r.store.search("report", limit: 3).count == 3)
    }

    @Test func matchesNameTitleURLAndSiteName() {
        let r = Rig()
        let w = r.store.createWindow()
        let a = r.open("https://air.com/booking?ref=zx81", in: w)
        r.store.pageDidUpdate(a, url: nil, title: "Seat map - Example Air", siteNameHint: "Example Air")
        r.store.rename(a, to: "Holiday")
        #expect(r.store.search("holiday").count == 1)   // name
        #expect(r.store.search("SEAT").count == 1)      // title, any case
        #expect(r.store.search("zx81").count == 1)      // URL
        #expect(r.store.search("example").count == 1)   // site name
        #expect(r.store.search("holiday zx81 air").count == 1)
        #expect(r.store.search("holiday zebra").isEmpty)
    }

    @Test func betterMatchesRankHigherWithinABand() {
        let r = Rig()
        let w = r.store.createWindow()
        let inURL = r.open("https://a.com/plan", in: w)
        r.store.pageDidUpdate(inURL, url: nil, title: "Unrelated", siteNameHint: nil)
        let inName = r.open("https://b.com/x", in: w)
        r.store.pageDidUpdate(inName, url: nil, title: "Plan for spring", siteNameHint: nil)
        let midName = r.open("https://c.com/y", in: w)
        r.store.pageDidUpdate(midName, url: nil, title: "The big plan", siteNameHint: nil)
        let results = r.store.search("plan")
        #expect(results.map(\.target) == [.openPage(inName, window: w), .openPage(midName, window: w), .openPage(inURL, window: w)])
    }

    @Test func recencyBreaksTies() {
        let r = Rig()
        let w = r.store.createWindow()
        let first = r.open("https://a.com/notes", in: w)
        let second = r.open("https://b.com/notes", in: w)
        #expect(r.store.search("notes").map(\.target) == [.openPage(second, window: w), .openPage(first, window: w)])
        r.clock.advance()
        r.store.select(first, in: w)
        #expect(r.store.search("notes").map(\.target) == [.openPage(first, window: w), .openPage(second, window: w)])
    }

    @Test func historyIsDeduplicatedAgainstEverythingAbove() {
        let r = Rig()
        let w = r.store.createWindow()
        let a = r.open("https://a.com/recipe", in: w)
        r.store.pageDidUpdate(a, url: u("https://a.com/other"), title: nil, siteNameHint: nil)
        r.store.pageDidUpdate(a, url: u("https://a.com/recipe"), title: nil, siteNameHint: nil)
        // History holds /recipe twice and the page is open on it: one result, the open page.
        #expect(r.store.history.filter { $0.url == u("https://a.com/recipe") }.count == 2)
        #expect(r.store.search("recipe").map(\.target) == [.openPage(a, window: w)])
        r.store.closePage(a)
        #expect(r.store.search("recipe").map(\.target) == [.history(u("https://a.com/recipe"))])
    }

    @Test func diacriticsAreFolded() {
        let r = Rig()
        let w = r.store.createWindow()
        let a = r.open("https://a.com/1", in: w)
        r.store.pageDidUpdate(a, url: nil, title: "Café menu", siteNameHint: nil)
        #expect(r.store.search("cafe").count == 1)
    }
}

@MainActor @Suite struct PersistenceTests {
    @Test func roundTripRestoresEverything() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = Rig(dir: dir)
        let w1 = r.store.createWindow(), w2 = r.store.createWindow()
        let a1 = r.open("https://a.com/1", in: w1)
        let a2 = r.open("https://a.com/2", in: w1)
        let b = r.open("https://b.com/1", in: w1)
        r.open("https://c.com/1", in: w1)
        r.open("https://d.com/1", in: w2)
        let e = r.open("https://e.com/1", in: w2)
        let f = r.open("https://f.com/1", in: w2)
        r.store.pageDidUpdate(a1, url: nil, title: "Alpha - A", siteNameHint: nil)
        r.store.rename(a2, to: "Custom")
        r.store.pageDidScroll(a1, y: 812.5)
        r.store.recordDwell(a1, seconds: 44)
        r.store.setKept(r.store.window(w1)!.sites[0].id, true)
        r.store.split(a1, with: b, in: w1)
        r.store.setSplitFraction(0.35, in: w1)
        r.store.setFrame([1, 2, 1280, 800], for: w1)
        r.store.pin(site: r.store.window(w2)!.site(containing: e)!.id)
        r.store.shelve(site: r.store.window(w2)!.site(containing: f)!.id)
        r.store.closePage(r.open("https://g.com/closed", in: w2))
        try r.store.save()

        let again = Rig(dir: dir)
        #expect(again.store.windows == r.store.windows)
        #expect(again.store.pins == r.store.pins)
        #expect(again.store.shelf == r.store.shelf)
        #expect(again.store.history == r.store.history)
        #expect(again.store.siteStats == r.store.siteStats)
        #expect(again.store.closed == r.store.closed)
        #expect(again.store.recoveredCorruptFile == nil)
        #expect(again.store.window(w1)?.split?.fraction == 0.35)
        again.ok()

        // The closed stack and the page-to-history link both survive.
        let reopened = again.store.reopenClosedPage(in: w2)
        #expect(reopened != nil)
        again.store.recordDwell(a1, seconds: 6)
        #expect(again.store.history.first { $0.url == u("https://a.com/1") }?.dwell == 50)
        again.ok()
    }

    @Test func fileIsAVersionedEnvelope() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = Rig(dir: dir)
        r.open("https://a.com/1", in: r.store.createWindow())
        try r.store.save()
        let data = try Data(contentsOf: dir.appendingPathComponent("state.json"))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["version"] as? Int == 1)
        for key in ["windows", "pins", "shelf", "history", "siteStats", "closed"] {
            #expect(json[key] != nil, "missing \(key)")
        }
    }

    @Test func noStorageDirectoryMeansNoFile() throws {
        let r = Rig()
        r.open("https://a.com/1", in: r.store.createWindow())
        try r.store.save()
        r.store.flush()
    }

    @Test func missingFileStartsEmpty() {
        let dir = tempDir()
        let r = Rig(dir: dir)
        #expect(r.store.windows.isEmpty)
        #expect(r.store.recoveredCorruptFile == nil)
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    @Test func saveCreatesTheDirectory() throws {
        let dir = tempDir().appendingPathComponent("nested/deeper")
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent().deletingLastPathComponent()) }
        let r = Rig(dir: dir)
        r.store.createWindow()
        try r.store.save()
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("state.json").path))
    }

    @Test func corruptFileIsMovedAsideAndStoreStartsEmpty() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("state.json")
        try Data("{ this is not json".utf8).write(to: file)

        let r = Rig(dir: dir)
        #expect(r.store.windows.isEmpty)
        let moved = try #require(r.store.recoveredCorruptFile)
        #expect(moved.lastPathComponent.hasPrefix("state.corrupt-"))
        #expect(moved.pathExtension == "json")
        #expect(try String(contentsOf: moved, encoding: .utf8) == "{ this is not json")
        #expect(!FileManager.default.fileExists(atPath: file.path))

        // The store works and saves normally afterwards.
        r.open("https://a.com/1", in: r.store.createWindow())
        try r.store.save()
        #expect(Rig(dir: dir).store.windows.count == 1)
        r.ok()
    }

    @Test func unknownVersionIsMovedAside() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"version":99,"windows":[]}"#.utf8).write(to: dir.appendingPathComponent("state.json"))
        let r = Rig(dir: dir)
        #expect(r.store.windows.isEmpty)
        #expect(r.store.recoveredCorruptFile != nil)
    }

    @Test func wrongShapeIsMovedAside() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"version":1,"windows":"nope"}"#.utf8).write(to: dir.appendingPathComponent("state.json"))
        #expect(Rig(dir: dir).store.recoveredCorruptFile != nil)
        try Data().write(to: dir.appendingPathComponent("state.json"))
        #expect(Rig(dir: dir).store.recoveredCorruptFile != nil)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("state.corrupt-") }
        #expect(leftovers.count == 2) // same timestamp, two distinct files
    }

    @Test func loadRepairsStateThatBreaksTheRules() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let t = Date(timeIntervalSinceReferenceDate: 1000)
        func page(_ s: String, id: PageID = PageID()) -> Page { Page(id: id, url: u(s), name: "", usage: Usage(at: t)) }
        let dup = PageID()
        let a = Site(key: SiteKey("a.com"), name: "A", pages: [page("https://a.com/1", id: dup), page("https://moved.com/1")])
        var a2 = Site(key: SiteKey("a.com"), name: "A again", pages: [page("https://a.com/2"), page("https://a.com/1", id: dup)])
        a2.currentPageID = PageID()
        let window = WindowState(sites: [a, a2], selectedPageID: PageID(),
                                 split: SplitPair(leading: dup, trailing: PageID(), fraction: 3))
        let entry = ShelfEntry(key: SiteKey("s.com"), name: "S", pages: [page("https://s.com/1"), page("https://t.com/1")], shelvedAt: t)
        let snapshot = StoreSnapshot(version: 1, windows: [window, window], pins: [], shelf: [entry, entry], history: [],
                                     siteStats: [:], closed: [], latestHistory: nil)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try snapshot.encoded().write(to: dir.appendingPathComponent("state.json"))

        let r = Rig(dir: dir)
        #expect(r.store.recoveredCorruptFile == nil)
        #expect(r.store.windows.count == 1)
        #expect(r.store.windows[0].sites.map(\.key.host) == ["a.com", "moved.com"])
        #expect(r.store.windows[0].sites[0].pages.count == 2)
        #expect(r.store.windows[0].split == nil)
        #expect(r.store.windows[0].selectedPageID != nil)
        #expect(Set(r.store.shelf.map(\.key.host)) == ["s.com", "t.com"])
        r.ok()
    }

    @Test func changesAreSavedOnTheirOwn() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = Rig(dir: dir)
        r.store.autosaveDelay = .milliseconds(20)
        let w = r.store.createWindow()
        r.open("https://a.com/1", in: w)
        r.open("https://b.com/1", in: w)
        let file = dir.appendingPathComponent("state.json")
        var waited = 0
        while !FileManager.default.fileExists(atPath: file.path), waited < 200 {
            try await Task.sleep(for: .milliseconds(10))
            waited += 1
        }
        #expect(FileManager.default.fileExists(atPath: file.path))
        try await Task.sleep(for: .milliseconds(100))
        #expect(Rig(dir: dir).store.windows == r.store.windows)
    }

    @Test func flushWritesImmediately() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = Rig(dir: dir)
        r.open("https://a.com/1", in: r.store.createWindow())
        r.store.flush()
        #expect(Rig(dir: dir).store.windows == r.store.windows)
    }
}

@MainActor @Suite struct EventTests {
    @Test func handlersSeeAConsistentStoreAndMayCallBack() {
        let r = Rig()
        let w = r.store.createWindow()
        let a = r.open("https://a.com/1", in: w)
        let b = r.open("https://b.com/1", in: w)
        var problems: [String] = []
        var seen: [StoreEvent] = []
        let store = r.store
        store.onEvent = { event in
            seen.append(event)
            problems += store.checkInvariants()
            if case .pageClosed = event { store.openPage(url: u("https://c.com/1"), in: w) }
        }
        store.closePage(b)
        #expect(problems.isEmpty)
        #expect(seen.first == .pageClosed(b))
        #expect(store.window(w)!.sites.map(\.key.host) == ["a.com", "c.com"])
        _ = a
        r.ok()
    }
}

@MainActor @Suite struct RandomisedTests {
    @Test(arguments: [UInt64(1), 42, 20261113])
    func invariantsHoldThroughTwoThousandOperations(seed: UInt64) throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = Rig(dir: dir)
        r.store.autosaveDelay = .seconds(3600)
        var rng = SeededGenerator(seed: seed)
        let hosts = ["a.com", "www.a.com", "b.com", "c.org", "d.net", "e.io", "f.dev"]
        func randomURL(_ rng: inout SeededGenerator) -> URL {
            u("https://\(hosts.randomElement(using: &rng)!)/p\(Int.random(in: 0..<12, using: &rng))")
        }

        // The fader misbehaves on purpose: random stages, random victims, stale ids.
        final class Dice: @unchecked Sendable { var rng: SeededGenerator; init(_ r: SeededGenerator) { rng = r } }
        let dice = Dice(SeededGenerator(seed: seed &+ 7))
        r.fader.script = { sites, _ in
            var v = FadeVerdict()
            for site in sites {
                if Int.random(in: 0..<4, using: &dice.rng) == 0 { v.siteStages[site.id] = Bool.random(using: &dice.rng) ? .fading : .live }
                if Int.random(in: 0..<8, using: &dice.rng) == 0 { v.sitesToShelve.append(site.id) }
                for page in site.pages {
                    if Int.random(in: 0..<4, using: &dice.rng) == 0 { v.pageStages[page.id] = .fading }
                    if Int.random(in: 0..<8, using: &dice.rng) == 0 { v.pagesToShelve.append(page.id) }
                }
            }
            v.pagesToShelve.append(PageID())
            return v
        }

        var store = r.store
        var operations = 0
        var eventProblems: [String] = []
        store.onEvent = { [unowned store] _ in eventProblems += store.checkInvariants() }

        for step in 0..<2000 {
            r.clock.advance(Double(Int.random(in: 1...40_000, using: &rng)))
            let windows = store.windows
            let w = windows.randomElement(using: &rng)
            let pages = w?.sites.flatMap { $0.pages.map(\.id) } ?? []
            let anyPage = pages.randomElement(using: &rng) ?? PageID()
            let otherPage = pages.randomElement(using: &rng) ?? PageID()
            let anySite = w?.sites.randomElement(using: &rng)?.id ?? SiteID()
            let wid = w?.id ?? WindowID()
            let pin = store.pins.randomElement(using: &rng)

            switch Int.random(in: 0..<34, using: &rng) {
            case 0: if windows.count < 3 { store.createWindow() }
            case 1: if windows.count > 1 && Int.random(in: 0..<4, using: &rng) == 0 { store.closeWindow(wid) }
            case 2, 3, 4, 5: store.openPage(url: randomURL(&rng), in: wid, select: Bool.random(using: &rng))
            case 6, 7: store.openPage(url: randomURL(&rng), in: wid, select: Bool.random(using: &rng), opener: anyPage)
            case 8, 9: store.closePage(anyPage)
            case 10: store.closeSite(anySite)
            case 11, 12: store.reopenClosedPage(in: wid)
            case 13, 14: store.select(anyPage, in: wid)
            case 15: store.selectSite(anySite, in: wid)
            case 16: if let pin { store.selectPin(pin.id, in: wid) }
            case 17: store.selectByShortcut(Int.random(in: 0...10, using: &rng), in: wid)
            case 18: store.selectAdjacent(offset: Bool.random(using: &rng) ? 1 : -1, in: wid)
            case 19, 20, 21:
                let target = Bool.random(using: &rng) ? anyPage : (pin?.page.id ?? anyPage)
                store.pageDidUpdate(target, url: Bool.random(using: &rng) ? randomURL(&rng) : nil,
                                    title: Bool.random(using: &rng) ? "Title \(step)" : nil,
                                    siteNameHint: Int.random(in: 0..<5, using: &rng) == 0 ? "Hint \(step % 3)" : nil)
            case 22: store.rename(anyPage, to: Bool.random(using: &rng) ? "Name \(step)" : nil)
            case 23: store.setKept(anySite, Bool.random(using: &rng))
            case 24: store.moveSite(anySite, toIndex: Int.random(in: -1...6, using: &rng), in: wid)
            case 25: store.pin(site: anySite)
            case 26: if let pin { store.unpin(pin.id, into: wid) }
            case 27: store.split(anyPage, with: otherPage, in: wid)
            case 28: Bool.random(using: &rng) ? store.endSplit(in: wid) : store.setSplitFraction(Double.random(in: 0...1, using: &rng), in: wid)
            case 29: store.runFade()
            case 30: store.shelve(site: anySite)
            case 31:
                if let entry = store.shelf.randomElement(using: &rng) {
                    store.restore(entry: entry.id, page: Bool.random(using: &rng) ? entry.pages.randomElement(using: &rng)?.id : nil, into: wid)
                }
            case 32:
                if let entry = store.shelf.randomElement(using: &rng), Int.random(in: 0..<3, using: &rng) == 0 {
                    store.removeFromShelf(entry: entry.id, page: Bool.random(using: &rng) ? entry.pages.randomElement(using: &rng)?.id : nil)
                }
            default:
                store.pageDidScroll(anyPage, y: Double(step))
                store.recordDwell(anyPage, seconds: 3)
                if let pin { store.resetPin(pin.id) }
                _ = store.search("p\(step % 12)")
            }
            operations += 1

            let problems = store.checkInvariants()
            #expect(problems.isEmpty, "seed \(seed), step \(step): \(problems)")
            if !problems.isEmpty { break }

            // Every so often, go through the disk and carry on with the reloaded store.
            if step % 250 == 249 {
                try store.save()
                let reloaded = BrowserStore(identity: FakeIdentity(), namer: FakeNamer(), fader: r.fader, storageDirectory: dir,
                                            now: { [clock = r.clock] in clock.t })
                reloaded.autosaveDelay = .seconds(3600)
                #expect(reloaded.windows == store.windows)
                #expect(reloaded.pins == store.pins)
                #expect(reloaded.shelf == store.shelf)
                #expect(reloaded.siteStats == store.siteStats)
                #expect(reloaded.closed == store.closed)
                #expect(reloaded.history == store.history)
                reloaded.onEvent = { [unowned reloaded] _ in eventProblems += reloaded.checkInvariants() }
                store = reloaded
            }
        }
        #expect(operations == 2000)
        #expect(eventProblems.isEmpty)
        // The run did real work rather than bouncing off guards.
        #expect(!store.history.isEmpty)
        #expect(!store.siteStats.isEmpty)
    }
}
