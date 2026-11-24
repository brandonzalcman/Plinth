import Foundation
import Testing
@testable import PlinthBrowserImport

@Suite struct BrowserDetectionTests {
    @Test func everyChromiumBrowserHasItsOwnFolderAndKeychainItem() {
        let chromium = ImportSource.allCases.filter { $0.family == .chromium }
        #expect(chromium == [.chrome, .edge, .brave, .arc, .vivaldi, .opera, .chromium])
        #expect(Set(chromium.map(\.dataPath)).count == chromium.count)
        #expect(ImportSource.brave.safeStorageItem! == ("Brave Safe Storage", "Brave"))
        #expect(ImportSource.edge.safeStorageItem! == ("Microsoft Edge Safe Storage", "Microsoft Edge"))
        #expect(ImportSource.vivaldi.safeStorageItem! == ("Vivaldi Safe Storage", "Vivaldi"))
        #expect(ImportSource.opera.safeStorageItem! == ("Opera Safe Storage", "Opera"))
        #expect(ImportSource.arc.safeStorageItem! == ("Arc Safe Storage", "Arc"))
        for source in ImportSource.allCases where source.family != .chromium { #expect(source.safeStorageItem == nil) }
    }

    @Test func familiesAndFolders() {
        #expect(ImportSource.firefox.family == .firefox)
        #expect(ImportSource.zen.family == .firefox)
        #expect(ImportSource.safari.family == .safari)
        #if os(macOS)
        let home = URL(fileURLWithPath: "/Users/someone")
        #expect(ImportSource.brave.dataFolder(home: home).path == "/Users/someone/Library/Application Support/BraveSoftware/Brave-Browser")
        #expect(ImportSource.edge.dataFolder(home: home).path == "/Users/someone/Library/Application Support/Microsoft Edge")
        #expect(ImportSource.opera.dataFolder(home: home).path == "/Users/someone/Library/Application Support/com.operasoftware.Opera")
        #expect(ImportSource.firefox.dataFolder(home: home).path == "/Users/someone/Library/Application Support/Firefox")
        #elseif os(Windows)
        let home = URL(fileURLWithPath: "C:\\Users\\someone")
        #expect(ImportSource.chrome.dataFolder(home: home).path.hasSuffix("AppData/Local/Google/Chrome/User Data"))
        #expect(ImportSource.edge.dataFolder(home: home).path.hasSuffix("AppData/Local/Microsoft/Edge/User Data"))
        #expect(ImportSource.firefox.dataFolder(home: home).path.hasSuffix("AppData/Roaming/Mozilla/Firefox"))
        #expect(!ImportSource.supported.contains(.safari))
        #endif
    }

    @Test func onlyBrowsersWithDataAreInstalled() {
        let home = FakeHome()
        #expect(ImportService.installedSources(home: home.url).isEmpty)
        for source in [ImportSource.brave, .edge, .firefox] { home.dir(home.root(source)) }
        // Arc counts by its own folder, above User Data.
        home.dir(home.url.appendingPathComponent("Library/Application Support/Arc"))
        #expect(ImportService.installedSources(home: home.url) == [.edge, .brave, .arc, .firefox])
    }

    @Test func everyBrowserHasExportSteps() {
        for source in ImportSource.allCases { #expect(!source.passwordExportSteps.isEmpty) }
        #expect(ImportSource.safari.passwordExportSteps.contains("Export All Passwords"))
        #expect(ImportSource.firefox.passwordExportSteps.contains("about:logins"))
        #expect(ImportSource.brave.passwordExportSteps.contains("brave://password-manager"))
    }
}

@Suite struct ProfileDiscoveryTests {
    @Test func localStateNamesAndOrdersProfiles() {
        let home = FakeHome()
        let root = home.root(.chrome)
        for folder in ["Default", "Profile 3", "Profile 1", "System Profile", "Guest Profile"] {
            writeChromiumBookmarks(root.appendingPathComponent(folder))
        }
        writeLocalState(root, names: ["Default": "Personal", "Profile 1": "Work", "Profile 3": "Side project"],
                        order: ["Profile 1", "Default", "Profile 3"])
        let profiles = ChromiumProfiles.discover(.chrome, home: home.url)
        #expect(profiles.map(\.folderName) == ["Profile 1", "Default", "Profile 3"])
        #expect(profiles.map(\.name) == ["Work", "Personal", "Side project"])
    }

    @Test func foldersOnDiskCountWithoutLocalState() {
        let home = FakeHome()
        let root = home.root(.edge)
        writeChromiumHistory(root.appendingPathComponent("Profile 10"), [])
        writeChromiumHistory(root.appendingPathComponent("Profile 2"), [])
        writeChromiumHistory(root.appendingPathComponent("Default"), [])
        home.dir(root.appendingPathComponent("Crashpad"))
        // A folder with no profile files isn't a profile.
        home.dir(root.appendingPathComponent("Profile 4"))
        #expect(ChromiumProfiles.discover(.edge, home: home.url).map(\.folderName) == ["Default", "Profile 2", "Profile 10"])
    }

    @Test func operaKeepsItsMainProfileInTheDataFolder() {
        let home = FakeHome()
        let root = home.root(.opera)
        writeChromiumBookmarks(root)
        writeChromiumBookmarks(root.appendingPathComponent("_side_profiles/abc123"))
        let profiles = ChromiumProfiles.discover(.opera, home: home.url)
        #expect(profiles.map(\.folderName) == ["", "_side_profiles/abc123"])
        #expect(profiles[0].name == "Opera")
    }

    @Test func firefoxPrefersTheInstallDefaultAndReadsAbsolutePaths() {
        let home = FakeHome()
        let root = home.root(.firefox)
        let elsewhere = home.url.appendingPathComponent("Elsewhere/abs.profile")
        writePlaces(root.appendingPathComponent("Profiles/old.default"), bookmarks: [], visits: [])
        writePlaces(root.appendingPathComponent("Profiles/new.default-release"), bookmarks: [], visits: [])
        writePlaces(elsewhere, bookmarks: [], visits: [])
        home.write("""
            [Install4F96D1932A9F858E]
            Default=Profiles/new.default-release
            Locked=1

            [Profile1]
            Name=default
            IsRelative=1
            Path=Profiles/old.default
            Default=1

            [Profile0]
            Name=default-release
            IsRelative=1
            Path=Profiles/new.default-release

            [Profile2]
            Name=moved
            IsRelative=0
            Path=\(elsewhere.path)
            """, to: root.appendingPathComponent("profiles.ini"))
        let candidates = FirefoxProfiles.candidates(root: root).map(\.lastPathComponent)
        #expect(candidates == ["new.default-release", "old.default", "abs.profile"])
        #expect(FirefoxProfiles.primary(root: root)?.lastPathComponent == "new.default-release")
    }

    @Test func firefoxWithoutProfilesIniUsesTheProfilesFolder() {
        let home = FakeHome()
        let root = home.root(.zen)
        home.dir(root.appendingPathComponent("Profiles/empty"))
        writePlaces(root.appendingPathComponent("Profiles/zz.Default (release)"), bookmarks: [], visits: [])
        #expect(FirefoxProfiles.primary(root: root)?.lastPathComponent == "zz.Default (release)")
    }
}
