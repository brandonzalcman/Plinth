import SwiftUI
import AppKit
import PlinthSettings

struct PrivacySettingsView: View {
    let app: AppController
    @Environment(\.settingsTheme) private var t
    @State private var clearHistory = true
    @State private var clearCookies = true
    @State private var clearCache = true
    @State private var range = ClearRange.lastHour
    @State private var clearing = false
    @State private var result: String?

    private var settings: SettingsStore { app.settings }
    private var kinds: BrowsingDataKinds {
        var k: BrowsingDataKinds = []
        if clearHistory { k.insert(.history) }
        if clearCookies { k.insert(.cookiesAndSiteData) }
        if clearCache { k.insert(.cache) }
        return k
    }

    var body: some View {
        SettingsPage(title: "Privacy & Security") {
            SettingsCard(heading: "Protection") {
                SettingsToggleRow(title: "Block ads and trackers", caption: "Uses the built-in content blocker on every page.", isOn: settings.binding(\.contentBlockerEnabled))
                SettingsDivider()
                SettingsToggleRow(title: "Block third-party cookies", caption: "Stops sites from following you across other sites. Some embedded logins may need it off.", isOn: settings.binding(\.blockThirdPartyCookies))
                SettingsDivider()
                SettingsToggleRow(title: "Always use HTTPS", caption: "Upgrades http links to https. If a site has no secure version, Plinth asks before opening it unsecured.", isOn: settings.binding(\.httpsOnly))
                SettingsDivider()
                SettingsToggleRow(title: "Send Global Privacy Control", caption: "Tells sites you don't want your data sold or shared.", isOn: settings.binding(\.globalPrivacyControl))
            }

            SettingsCard(heading: "Clear browsing data") {
                SettingsRow(title: "Time range") {
                    SettingsMenuPicker(label: "Time range", options: ClearRange.allCases.map { ($0, $0.displayName) }, selection: $range)
                }
                SettingsDivider()
                checkbox("Browsing history", "Pages you've visited and the searches you made.", $clearHistory)
                SettingsDivider()
                checkbox("Cookies and site data", "Signs you out of sites and clears their saved data.", $clearCookies)
                SettingsDivider()
                checkbox("Cached images and files", "Saved copies that help pages load faster.", $clearCache)
                SettingsDivider()
                HStack(spacing: 12) {
                    SettingsButton(title: clearing ? "Clearing…" : "Clear Data…", style: .destructive) { confirm() }
                        .disabled(kinds.isEmpty || clearing)
                    if clearing { ProgressView().controlSize(.small) }
                    if let result {
                        Text(result).font(.system(size: 11.5)).foregroundStyle(t.p.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
            }
        }
    }

    private func checkbox(_ title: String, _ caption: String, _ binding: Binding<Bool>) -> some View {
        SettingsRow(title: title, caption: caption) {
            Toggle(title, isOn: binding).labelsHidden().toggleStyle(.checkbox)
        }
    }

    private func confirm() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        var parts: [String] = []
        if clearHistory { parts.append("your browsing history") }
        if clearCookies { parts.append("cookies and site data (you'll be signed out of sites)") }
        if clearCache { parts.append("cached images and files") }
        let span = range == .allTime ? "of all time" : range.displayName.lowercased()
        alert.messageText = "Clear browsing data?"
        alert.informativeText = "This removes \(parts.joined(separator: ", ")) from \(range == .allTime ? "all time" : span). This can't be undone."
        let clear = alert.addButton(withTitle: "Clear Data")
        clear.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        guard let window = NSApp.keyWindow ?? app.settingsWindow?.window else { return }
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { run() }
        }
    }

    private func run() {
        let kinds = kinds, since = range.since(), range = range
        clearing = true
        result = nil
        Task { @MainActor in
            var removed = 0
            if kinds.contains(.history) { removed = app.store.clearHistory(since: since) }
            if !kinds.isDisjoint(with: [.cookiesAndSiteData, .cache]) {
                await app.pool.clearWebsiteData(kinds, since: since)
            }
            var done: [String] = []
            if kinds.contains(.history) { done.append("\(removed) history \(removed == 1 ? "entry" : "entries")") }
            if kinds.contains(.cookiesAndSiteData) { done.append("cookies and site data") }
            if kinds.contains(.cache) { done.append("cache") }
            result = "Cleared " + done.joined(separator: ", ") + (range == .allTime ? "." : " (\(range.displayName.lowercased())).")
            clearing = false
        }
    }
}
