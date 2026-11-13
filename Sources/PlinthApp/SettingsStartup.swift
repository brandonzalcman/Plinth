import SwiftUI
import PlinthSettings

struct StartupSettingsView: View {
    let app: AppController
    private var settings: SettingsStore { app.settings }

    var body: some View {
        let isHomepage = settings.value.newPage == .homepage
        SettingsPage(title: "Startup & New Pages") {
            SettingsCard(heading: "When Plinth opens") {
                SettingsRow(title: "Start with", caption: settings.value.startup == .restoreLastSession
                            ? "Your windows and pages come back as you left them."
                            : "Open pages go to the shelf and you start with an empty window.") {
                    SettingsSegmented(label: "Start with",
                                      options: [(StartupBehavior.restoreLastSession, "Last session"), (.startFresh, "Fresh start")],
                                      selection: settings.binding(\.startup))
                }
            }
            SettingsCard(heading: "New pages") {
                SettingsRow(title: "A new page shows", caption: caption) {
                    SettingsSegmented(label: "A new page shows",
                                      options: [(NewPageContent.commandBar, "Search bar"), (.homepage, "Homepage"), (.blank, "Blank")],
                                      selection: settings.binding(\.newPage))
                }
                SettingsDivider()
                SettingsRow(title: "Homepage", caption: homepageCaption(isHomepage)) {
                    SettingsTextField(label: "Homepage address", placeholder: "example.com", text: settings.binding(\.homepage), width: 250)
                        .disabled(!isHomepage)
                }
                if isHomepage, !settings.value.homepage.trimmingCharacters(in: .whitespaces).isEmpty, settings.value.homepageURL == nil {
                    SettingsNote(text: "That doesn't look like a web address, so new pages will open the search bar instead.", tone: .warning)
                }
            }
        }
    }

    private var caption: String {
        switch settings.value.newPage {
        case .commandBar: "The search and address bar opens."
        case .homepage: "Your homepage loads. With no valid homepage, the search bar opens."
        case .blank: "An empty page."
        }
    }

    private func homepageCaption(_ enabled: Bool) -> String {
        enabled ? "Bare addresses like example.com get https." : "Choose Homepage above to set one."
    }
}
