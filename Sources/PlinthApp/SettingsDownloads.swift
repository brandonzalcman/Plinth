import SwiftUI
import AppKit
import PlinthSettings

struct DownloadsSettingsView: View {
    let app: AppController
    @Environment(\.settingsTheme) private var t
    private var settings: SettingsStore { app.settings }

    private var folderText: String {
        guard let path = settings.value.downloadFolder else { return "Downloads" }
        return (path as NSString).abbreviatingWithTildeInPath
    }

    var body: some View {
        SettingsPage(title: "Downloads") {
            SettingsCard(heading: "Location") {
                SettingsRow(title: "Save files to", caption: settings.value.downloadFolder == nil ? "Your Mac's Downloads folder." : nil) {
                    HStack(spacing: 8) {
                        Text(folderText).font(.system(size: 12, weight: .medium)).foregroundStyle(t.p.primary)
                            .lineLimit(1).truncationMode(.middle).frame(maxWidth: 220, alignment: .trailing)
                            .help(settings.value.downloadFolder ?? "Downloads")
                        SettingsButton(title: "Choose…") { choose() }
                        if settings.value.downloadFolder != nil {
                            SettingsButton(title: "Reset") { settings.update { $0.downloadFolder = nil } }
                        }
                    }
                }
                SettingsDivider()
                SettingsToggleRow(title: "Ask where to save each file", caption: "Shows a save dialog for every download.", isOn: settings.binding(\.askWhereToSave))
            }
            SettingsCard(heading: "After downloading") {
                SettingsToggleRow(title: "Open safe files after downloading", caption: "Opens things like images, PDFs and text right away. Apps and scripts never open on their own.", isOn: settings.binding(\.openSafeFilesAfterDownload))
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose where downloads are saved."
        if let path = settings.value.downloadFolder { panel.directoryURL = URL(fileURLWithPath: path) }
        let apply: (NSApplication.ModalResponse) -> Void = { response in
            if response == .OK, let url = panel.url { settings.update { $0.downloadFolder = url.path } }
        }
        if let window = app.settingsWindow?.window { panel.beginSheetModal(for: window, completionHandler: apply) } else { panel.begin(completionHandler: apply) }
    }
}
