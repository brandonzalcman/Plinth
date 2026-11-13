import SwiftUI
import AppKit
import PlinthRules
import PlinthSettings

/// Default-browser status and registration, kept apart from the view so the action is never run by accident.
enum DefaultBrowser {
    /// True when the app that opens https links is this one.
    static func isDefault() -> Bool {
        guard let handler = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://")!) else { return false }
        return handler.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
    }

    /// Asks macOS to make Plinth the handler of http and https. macOS shows its own confirmation.
    /// Never called from tests: it changes the Mac's default browser.
    static func makeDefault() {
        let workspace = NSWorkspace.shared
        for scheme in ["http", "https"] {
            workspace.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: scheme) { _ in }
        }
    }
}

struct GeneralSettingsView: View {
    let app: AppController
    @Environment(\.settingsTheme) private var t
    @State private var isDefault = DefaultBrowser.isDefault()
    /// The engine kind shown in the picker. Differs from the saved engine while a custom template is not valid yet.
    @State private var pickedKind: SearchEngine.Kind
    @State private var customDraft: String

    init(app: AppController) {
        self.app = app
        let engine = app.settings.value.searchEngine
        _pickedKind = State(initialValue: engine.kind)
        _customDraft = State(initialValue: engine.customTemplate)
    }

    private var savedEngine: SearchEngine { app.settings.value.searchEngine }
    private var draftValid: Bool { SearchEngine.isValid(template: customDraft) }

    var body: some View {
        SettingsPage(title: "General") {
            SettingsCard(heading: "Default browser") {
                SettingsRow(title: isDefault ? "Plinth is your default browser" : "Plinth isn't your default browser",
                            caption: isDefault ? "Links from other apps open in Plinth." : "Links from other apps open in another browser.") {
                    if isDefault {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 18)).foregroundStyle(t.accent)
                            .accessibilityLabel("Default browser")
                    } else {
                        SettingsButton(title: "Make Default", style: .accent) { DefaultBrowser.makeDefault() }
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in isDefault = DefaultBrowser.isDefault() }

            SettingsCard(heading: "Search") {
                SettingsRow(title: "Default search engine", caption: "Used when you type something that isn't an address.") {
                    SettingsMenuPicker(label: "Default search engine",
                                       options: SearchEngine.Kind.allCases.map { ($0, $0.displayName) },
                                       selection: Binding(get: { pickedKind }, set: pick))
                }
                if pickedKind == .custom {
                    SettingsDivider()
                    SettingsRow(title: "Search URL", caption: "Use %s where the search words go, for example https://example.com/search?q=%s") {
                        SettingsTextField(label: "Custom search URL", placeholder: "https://example.com/?q=%s", text: Binding(get: { customDraft }, set: editCustom), width: 280)
                    }
                    customMessage
                }
            }

            SettingsCard(heading: "About") {
                SettingsRow(title: "Plinth", caption: AppVersion.current.displayString) {
                    if let check = app.checkForUpdates {
                        SettingsButton(title: "Check for Updates…", style: .quiet) { check() }
                    }
                }
            }
        }
        .onAppear { isDefault = DefaultBrowser.isDefault() }
    }

    @ViewBuilder private var customMessage: some View {
        let trimmed = customDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            SettingsNote(text: "Enter a search URL. Until then Plinth keeps using \(savedEngine.kind == .custom ? "your last working custom engine" : savedEngine.kind.displayName).", tone: .warning)
        } else if !trimmed.contains("%s") {
            SettingsNote(text: "The URL needs %s where the search words go. Plinth is still using \(describe(savedEngine)).", tone: .warning)
        } else if !draftValid {
            SettingsNote(text: "That isn't a valid web address (it must start with http:// or https:// and have no spaces). Plinth is still using \(describe(savedEngine)).", tone: .error)
        } else {
            SettingsNote(text: "Saved. Searches go to this address.", tone: .good)
        }
    }

    private func describe(_ engine: SearchEngine) -> String { engine.kind == .custom ? "your last working custom engine" : engine.kind.displayName }

    private func pick(_ kind: SearchEngine.Kind) {
        pickedKind = kind
        if kind == .custom {
            // Keep the engine in force until the template is valid.
            if draftValid { app.settings.update { $0.searchEngine = SearchEngine(kind: .custom, customTemplate: customDraft.trimmingCharacters(in: .whitespacesAndNewlines)) } }
        } else {
            app.settings.update { $0.searchEngine = SearchEngine(kind: kind, customTemplate: $0.searchEngine.customTemplate) }
        }
    }

    private func editCustom(_ text: String) {
        customDraft = text
        if SearchEngine.isValid(template: text) {
            app.settings.update { $0.searchEngine = SearchEngine(kind: .custom, customTemplate: text.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
    }
}
