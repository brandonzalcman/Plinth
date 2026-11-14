import Foundation
import Testing
import PlinthRules
@testable import PlinthSettings

private func tempDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "plinth-settings-\(UUID().uuidString)", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func write(_ json: String, to dir: URL) throws {
    try json.write(to: dir.appending(path: "settings.json"), atomically: true, encoding: .utf8)
}

private func decode(_ json: String) throws -> AppSettings {
    try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
}

@Suite struct AppSettingsTests {
    @Test func defaultsMatchVersion010() {
        let s = AppSettings.defaults
        #expect(s == AppSettings())
        #expect(s.searchEngine == .duckDuckGo)
        #expect(s.contentBlockerEnabled)
        #expect(!s.blockThirdPartyCookies && !s.httpsOnly && !s.globalPrivacyControl)
        #expect(s.downloadFolder == nil && !s.askWhereToSave && !s.openSafeFilesAfterDownload)
        #expect(s.startup == .restoreLastSession)
        #expect(s.newPage == .commandBar)
        #expect(s.homepage.isEmpty)
        #expect(s.accent == .blue)
        #expect(s.fadeBehavior == .standard)
        #expect(s.defaultZoom == 1 && s.defaultFontSize == 16 && s.minimumFontSize == 0)
        #expect(s.semanticSearchEnabled && s.pageSummariesEnabled)
    }

    @Test func emptyObjectDecodesToDefaults() throws {
        #expect(try decode("{}") == .defaults)
    }

    @Test func olderFileMissingFieldsKeepsWhatItHasAndDefaultsTheRest() throws {
        let s = try decode(#"{"accent":"green","httpsOnly":true,"startup":"startFresh"}"#)
        #expect(s.accent == .green && s.httpsOnly && s.startup == .startFresh)
        var expected = AppSettings()
        expected.accent = .green; expected.httpsOnly = true; expected.startup = .startFresh
        #expect(s == expected)
    }

    @Test func unknownEnumValuesFallBackPerField() throws {
        let s = try decode(#"{"accent":"chartreuse","fadeBehavior":"glacial","startup":"teleport","newPage":"hologram","searchEngine":42,"httpsOnly":true}"#)
        #expect(s.accent == .blue && s.fadeBehavior == .standard)
        #expect(s.startup == .restoreLastSession && s.newPage == .commandBar)
        #expect(s.searchEngine == .duckDuckGo)
        #expect(s.httpsOnly)   // the valid field is still read
    }

    @Test func wrongTypesFallBackPerField() throws {
        let s = try decode(#"{"httpsOnly":"yes","defaultZoom":"big","homepage":7,"downloadFolder":5,"contentBlockerEnabled":false}"#)
        #expect(!s.httpsOnly && s.defaultZoom == 1 && s.homepage.isEmpty && s.downloadFolder == nil)
        #expect(!s.contentBlockerEnabled)
    }

    @Test func unknownKeysAreIgnored() throws {
        #expect(try decode(#"{"someFutureThing":{"a":1},"accent":"red"}"#).accent == .red)
    }

    @Test func valuesAreClamped() throws {
        #expect(try decode(#"{"defaultZoom":0.1}"#).defaultZoom == 0.5)
        #expect(try decode(#"{"defaultZoom":9}"#).defaultZoom == 3)
        #expect(try decode(#"{"defaultZoom":1.25}"#).defaultZoom == 1.25)
        #expect(try decode(#"{"defaultFontSize":2}"#).defaultFontSize == 9)
        #expect(try decode(#"{"defaultFontSize":500}"#).defaultFontSize == 72)
        #expect(try decode(#"{"defaultFontSize":20}"#).defaultFontSize == 20)
        #expect(try decode(#"{"minimumFontSize":0}"#).minimumFontSize == 0)
        #expect(try decode(#"{"minimumFontSize":2}"#).minimumFontSize == 6)
        #expect(try decode(#"{"minimumFontSize":99}"#).minimumFontSize == 36)
        #expect(try decode(#"{"minimumFontSize":12}"#).minimumFontSize == 12)
    }

    @Test func codableRoundTrip() throws {
        var s = AppSettings()
        s.searchEngine = SearchEngine(kind: .custom, customTemplate: "https://x.org/?q=%s")
        s.downloadFolder = "/tmp/dl"
        s.homepage = "example.com"
        s.accent = .pink
        s.fadeBehavior = .never
        s.defaultZoom = 1.5
        s.defaultFontSize = 18
        s.minimumFontSize = 10
        s.semanticSearchEnabled = false
        let back = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s))
        #expect(back == s)
    }

    @Test func homepageURLNormalisation() {
        func url(_ text: String) -> String? {
            var s = AppSettings(); s.homepage = text
            return s.homepageURL?.absoluteString
        }
        #expect(url("example.com") == "https://example.com")
        #expect(url("  example.com/start  ") == "https://example.com/start")
        #expect(url("http://example.com") == "http://example.com")
        #expect(url("https://example.com/a?b=1") == "https://example.com/a?b=1")
        #expect(url("localhost:3000") == "http://localhost:3000")
        #expect(url("") == nil)
        #expect(url("   ") == nil)
        #expect(url("just some words") == nil)
        #expect(url("hello") == nil)
    }

    @Test func accentAndFadeHelpers() {
        #expect(AccentChoice.allCases.count == 12)
        for accent in AccentChoice.allCases {
            let c = accent.rgb
            #expect((0...255).contains(c.r) && (0...255).contains(c.g) && (0...255).contains(c.b))
        }
        #expect(FadeBehavior.shorter.lifetimeScale == 0.5)
        #expect(FadeBehavior.standard.lifetimeScale == 1)
        #expect(FadeBehavior.longer.lifetimeScale == 2)
        #expect(FadeBehavior.never.lifetimeScale == .infinity)
    }
}

@Suite struct NewPageActionTests {
    private func settings(_ page: NewPageContent, homepage: String = "") -> AppSettings {
        var s = AppSettings(); s.newPage = page; s.homepage = homepage
        return s
    }

    @Test func commandBarIsTheDefault() {
        #expect(NewPageAction.decide(AppSettings()) == .commandBar)
        #expect(NewPageAction.decide(settings(.commandBar, homepage: "example.com")) == .commandBar)
    }

    @Test func homepageOpensItsURL() {
        #expect(NewPageAction.decide(settings(.homepage, homepage: "example.com")) == .open(URL(string: "https://example.com")!))
        #expect(NewPageAction.decide(settings(.homepage, homepage: "http://intranet.test/")) == .open(URL(string: "http://intranet.test/")!))
    }

    @Test func homepageWithoutAUsableURLFallsBackToTheCommandBar() {
        #expect(NewPageAction.decide(settings(.homepage)) == .commandBar)
        #expect(NewPageAction.decide(settings(.homepage, homepage: "  ")) == .commandBar)
        #expect(NewPageAction.decide(settings(.homepage, homepage: "not an address")) == .commandBar)
    }

    @Test func blankOpensAboutBlank() {
        #expect(NewPageAction.decide(settings(.blank, homepage: "example.com")) == .open(URL(string: "about:blank")!))
    }
}

@MainActor
@Suite struct SettingsStoreTests {
    @Test func missingFileGivesDefaultsAndWritesNothing() {
        let dir = tempDirectory()
        let store = SettingsStore(storageDirectory: dir)
        #expect(store.value == .defaults)
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
        // A no-op update does not write either.
        store.update { $0.accent = .blue }
        store.update { _ in }
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    @Test func missingDirectoryIsCreatedOnFirstChange() {
        let dir = tempDirectory().appending(path: "nested/deeper", directoryHint: .isDirectory)
        let store = SettingsStore(storageDirectory: dir)
        store.update { $0.httpsOnly = true }
        #expect(FileManager.default.fileExists(atPath: store.fileURL.path))
        #expect(SettingsStore(storageDirectory: dir).value.httpsOnly)
    }

    @Test func firstChangeWritesTheFile() {
        let dir = tempDirectory()
        let store = SettingsStore(storageDirectory: dir)
        store.update { $0.accent = .orange }
        #expect(FileManager.default.fileExists(atPath: store.fileURL.path))
        #expect(store.fileURL.lastPathComponent == "settings.json")
    }

    @Test func roundTripsThroughANewInstance() {
        let dir = tempDirectory()
        let store = SettingsStore(storageDirectory: dir)
        store.update {
            $0.searchEngine = SearchEngine(kind: .custom, customTemplate: "https://x.org/?q=%s")
            $0.httpsOnly = true
            $0.downloadFolder = "/tmp/somewhere"
            $0.startup = .startFresh
            $0.newPage = .homepage
            $0.homepage = "example.com"
            $0.accent = .purple
            $0.fadeBehavior = .longer
            $0.defaultZoom = 1.25
            $0.defaultFontSize = 20
            $0.minimumFontSize = 11
            $0.pageSummariesEnabled = false
        }
        let again = SettingsStore(storageDirectory: dir)
        #expect(again.value == store.value)
        #expect(again.value.searchEngine.kind == .custom)
        #expect(again.value.pageSummariesEnabled == false)
        #expect(again.value.semanticSearchEnabled == true)
    }

    @Test func corruptFileGivesDefaultsWithoutCrashing() throws {
        let dir = tempDirectory()
        try write("{ this is not json", to: dir)
        let store = SettingsStore(storageDirectory: dir)
        #expect(store.value == .defaults)
        try write("", to: dir)
        #expect(SettingsStore(storageDirectory: dir).value == .defaults)
        try write("[1,2,3]", to: dir)
        #expect(SettingsStore(storageDirectory: dir).value == .defaults)
        // It recovers on the next change.
        store.update { $0.accent = .red }
        #expect(SettingsStore(storageDirectory: dir).value.accent == .red)
    }

    @Test func olderFileWithMissingFieldsKeepsKnownValues() throws {
        let dir = tempDirectory()
        try write(#"{"version":1,"settings":{"accent":"green","fadeBehavior":"warp","defaultFontSize":3}}"#, to: dir)
        let store = SettingsStore(storageDirectory: dir)
        #expect(store.value.accent == .green)
        #expect(store.value.fadeBehavior == .standard)   // unknown raw value
        #expect(store.value.defaultFontSize == 9)        // clamped
        #expect(store.value.contentBlockerEnabled)       // missing, defaulted
    }

    @Test func observersFireOnlyOnRealChanges() {
        let store = SettingsStore(storageDirectory: tempDirectory())
        var calls: [(AppSettings, AppSettings)] = []
        store.observe { calls.append(($0, $1)) }

        store.update { $0.accent = .blue }          // same as default: no change
        store.update { _ in }
        #expect(calls.isEmpty)

        store.update { $0.accent = .green }
        #expect(calls.count == 1)
        #expect(calls[0].0.accent == .blue && calls[0].1.accent == .green)

        store.update { $0.accent = .green }         // again: nothing
        #expect(calls.count == 1)

        store.update { $0.httpsOnly = true; $0.defaultZoom = 2 }   // two fields, one callback
        #expect(calls.count == 2)
        #expect(!calls[1].0.httpsOnly && calls[1].1.httpsOnly)
        #expect(calls[1].0.defaultZoom == 1 && calls[1].1.defaultZoom == 2)
        #expect(calls[1].0.accent == .green && calls[1].1.accent == .green)
        #expect(store.value == calls[1].1)
    }

    @Test func everyObserverIsCalledAndOldValueIsPreviousState() {
        let store = SettingsStore(storageDirectory: tempDirectory())
        var first = 0, second = 0
        store.observe { _, _ in first += 1 }
        store.observe { _, _ in second += 1 }
        store.update { $0.fadeBehavior = .never }
        store.update { $0.fadeBehavior = .shorter }
        #expect(first == 2 && second == 2)
    }

    @Test func resetToDefaultsNotifiesOnlyWhenSomethingChanged() {
        let store = SettingsStore(storageDirectory: tempDirectory())
        var count = 0
        store.observe { _, _ in count += 1 }
        store.resetToDefaults()
        #expect(count == 0)
        store.update { $0.accent = .red }
        store.resetToDefaults()
        #expect(count == 2)
        #expect(store.value == .defaults)
    }
}

@Suite struct ClearRangeTests {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    /// 2026-03-15 14:30:00 UTC.
    private var now: Date { calendar.date(from: DateComponents(year: 2026, month: 3, day: 15, hour: 14, minute: 30))! }

    @Test func allTimeIsEverything() {
        #expect(ClearRange.allTime.since(now: now, calendar: calendar) == nil)
    }

    @Test func lastHour() {
        #expect(ClearRange.lastHour.since(now: now, calendar: calendar) == now.addingTimeInterval(-3600))
    }

    @Test func todayStartsAtMidnight() {
        let start = ClearRange.today.since(now: now, calendar: calendar)
        #expect(start == calendar.date(from: DateComponents(year: 2026, month: 3, day: 15)))
        // Exactly at midnight, the range starts then; one second before, the previous day.
        let midnight = calendar.date(from: DateComponents(year: 2026, month: 3, day: 15))!
        #expect(ClearRange.today.since(now: midnight, calendar: calendar) == midnight)
        let before = midnight.addingTimeInterval(-1)
        #expect(ClearRange.today.since(now: before, calendar: calendar) == calendar.date(from: DateComponents(year: 2026, month: 3, day: 14)))
    }

    @Test func lastWeekIsSevenTimes24Hours() {
        #expect(ClearRange.lastWeek.since(now: now, calendar: calendar) == now.addingTimeInterval(-7 * 86400))
    }

    @Test func rangesAreOrderedFromNarrowToWide() {
        let starts = [ClearRange.lastHour, .today, .lastWeek].compactMap { $0.since(now: now, calendar: calendar) }
        #expect(starts == starts.sorted(by: >))
        #expect(starts.count == 3)
    }

    @Test func browsingDataKinds() {
        #expect(BrowsingDataKinds.all.contains(.history) && BrowsingDataKinds.all.contains(.cache))
        #expect(BrowsingDataKinds.all.contains(.cookiesAndSiteData))
        #expect(!BrowsingDataKinds([.history]).contains(.cache))
    }
}
