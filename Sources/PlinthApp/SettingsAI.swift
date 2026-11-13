import SwiftUI
import PlinthModel
import PlinthSettings

struct AISettingsView: View {
    let app: AppController
    private var settings: SettingsStore { app.settings }

    var body: some View {
        let enabled = app.ai.isEnabled
        SettingsPage(title: "On-device AI", subtitle: "Everything runs on this Mac. Nothing you browse is sent anywhere.") {
            SettingsCard(heading: "Master switch") {
                SettingsToggleRow(title: "Use on-device AI", caption: availabilityText,
                                  isOn: Binding(get: { app.ai.isEnabled }, set: { app.ai.setEnabled($0) }))
            }
            SettingsCard(heading: "Features") {
                SettingsToggleRow(title: "Search history by meaning", caption: "Find pages by what they were about, not just the words in their title.",
                                  isOn: settings.binding(\.semanticSearchEnabled)).disabled(!enabled)
                SettingsDivider()
                SettingsToggleRow(title: "Page summaries", caption: "Short summaries on the resume card when you come back to a page.",
                                  isOn: settings.binding(\.pageSummariesEnabled)).disabled(!enabled)
                if !enabled { SettingsNote(text: "Turn on on-device AI to use these.") }
            }
        }
        .onAppear { app.ai.refreshAvailability() }
    }

    private var availabilityText: String {
        switch app.ai.availability {
        case .available: "Ready on this Mac."
        case .turnedOff: "Off. Page summaries, Ask and meaning search are unavailable."
        case .unavailable(let reason): "Not available on this Mac right now: \(reason)"
        }
    }
}
