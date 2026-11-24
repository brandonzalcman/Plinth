import Foundation
import Testing
import PlinthModel
@testable import PlinthShell

@MainActor @Suite struct ShellPreferencesTests {
    @Test func defaultsToTheDockAndRoundTrips() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("plinth-prefs-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = ShellPreferencesStore(directory: dir)
        #expect(store.value.tabLayout == .dock)
        var seen: [TabLayout] = []
        store.observe { _, new in seen.append(new.tabLayout) }
        store.update { $0.tabLayout = .sidebar; $0.sidebarCollapsed = true }
        store.update { $0.tabLayout = .sidebar }   // no change, no notification
        #expect(seen == [.sidebar])
        let reloaded = ShellPreferencesStore(directory: dir)
        #expect(reloaded.value.tabLayout == .sidebar)
        #expect(reloaded.value.sidebarCollapsed)
    }

    @Test func unknownValuesFallBackToDefaults() throws {
        let json = #"{"tabLayout":"floating","sidebarCollapsed":"yes"}"#.data(using: .utf8)!
        let prefs = try JSONDecoder().decode(ShellPreferences.self, from: json)
        #expect(prefs.tabLayout == .dock)
        #expect(prefs.sidebarCollapsed == false)
    }
}
