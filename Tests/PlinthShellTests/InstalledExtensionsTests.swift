import Foundation
import Testing
@testable import PlinthShell

@Suite struct InstalledExtensionsTests {
    /// A throwaway profile folder laid out the way Chromium writes one.
    struct Profile {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("plinth-ext-\(UUID().uuidString)")

        func write(_ json: Any, to path: String) throws {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: json).write(to: url)
        }

        func install(id: String, version: String, manifest: [String: Any], locales: [String: [String: Any]] = [:]) throws {
            try write(manifest, to: "Extensions/\(id)/\(version)_0/manifest.json")
            for (locale, messages) in locales {
                try write(messages, to: "Extensions/\(id)/\(version)_0/_locales/\(locale)/messages.json")
            }
        }
    }

    let ublock = "ddkjiahejlhfcafbddmgiahcphecmpfh"
    let darkReader = "eimadpbcbfnmbkopoojfekhnkhdbieeh"

    @Test func readsStoreInstallsWithPopupsAndIcons() throws {
        let p = Profile()
        try p.install(id: ublock, version: "2025.1.1", manifest: [
            "manifest_version": 3, "name": "uBlock Origin Lite", "version": "2025.1.1",
            "action": ["default_popup": "popup.html", "default_icon": ["16": "img/16.png", "32": "img/32.png", "64": "img/64.png"]],
            "icons": ["128": "img/128.png"],
        ])
        try p.write(["extensions": ["settings": [
            ublock: ["path": "\(ublock)/2025.1.1_0", "location": 1, "disable_reasons": 0],
        ]]], to: "Secure Preferences")

        let found = InstalledExtensions.scan(profile: p.root)
        #expect(found.count == 1)
        let ext = try #require(found.first)
        #expect(ext.name == "uBlock Origin Lite")
        #expect(ext.isEnabled)
        #expect(ext.popupURL?.absoluteString == "chrome-extension://\(ublock)/popup.html")
        #expect(ext.iconFile?.lastPathComponent == "32.png")
    }

    @Test func skipsBuiltInComponentsAndResolvesLocalizedNames() throws {
        let p = Profile()
        try p.install(id: darkReader, version: "4.9", manifest: [
            "manifest_version": 2, "name": "__MSG_extension_name__", "default_locale": "en", "version": "4.9",
            "browser_action": ["default_popup": "/ui/popup/index.html", "default_icon": "icons/dr_16.png"],
        ], locales: ["en": ["extension_name": ["message": "Dark Reader"]]])
        try p.write(["extensions": ["settings": [
            darkReader: ["path": "\(darkReader)/4.9_0", "location": 1, "disable_reasons": [1]],
            "mhjfbmdgcfjbbpaeojofohoefgiehjai": ["path": "/Applications/x/pdf", "location": 5],
        ]]], to: "Preferences")

        let found = InstalledExtensions.scan(profile: p.root)
        #expect(found.map(\.name) == ["Dark Reader"])
        #expect(found[0].isEnabled == false)
        #expect(found[0].popupURL?.absoluteString == "chrome-extension://\(darkReader)/ui/popup/index.html")
        #expect(found[0].iconFile?.lastPathComponent == "dr_16.png")
    }

    @Test func unpackedExtensionsUseTheirAbsolutePath() throws {
        let p = Profile()
        let dir = p.root.appendingPathComponent("dev/my-ext")
        try p.write(["name": "Mine", "version": "0.1", "manifest_version": 3], to: "dev/my-ext/manifest.json")
        try p.write(["extensions": ["settings": ["abcdefghijklmnopabcdefghijklmnop": ["path": dir.path, "location": 4]]]],
                    to: "Secure Preferences")
        let found = InstalledExtensions.scan(profile: p.root)
        #expect(found.map(\.name) == ["Mine"])
        #expect(found[0].popupURL == nil)
    }

    @Test func emptyOrMissingProfileFindsNothing() {
        #expect(InstalledExtensions.scan(profile: URL(fileURLWithPath: "/nonexistent-\(UUID())")).isEmpty)
    }
}
