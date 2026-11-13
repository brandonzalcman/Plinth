import SwiftUI
import AppKit
import PlinthImport

/// Plain-language statement of where imported bookmarks end up. Easy to change.
enum ImportCopy {
    static let bookmarksExplanation = "Plinth has no bookmark folders. Imported bookmarks are added to the shelf, grouped by site."
}

struct ImportSettingsView: View {
    let app: AppController

    var body: some View {
        SettingsPage(title: "Import", subtitle: ImportCopy.bookmarksExplanation) {
            ForEach(ImportSource.allCases, id: \.self) { source in
                ImportCard(app: app, source: source)
            }
        }
    }
}

private struct ImportCard: View {
    let app: AppController
    let source: ImportSource
    @Environment(\.settingsTheme) private var t
    @State private var bookmarks = true
    @State private var history = true
    @State private var running = false
    @State private var report: ImportReport?
    @State private var failure: ImportFailure?
    @State private var installed = false

    var body: some View {
        SettingsCard(heading: "From \(source.displayName)") {
            SettingsRow(title: source.displayName,
                        caption: installed ? "Found on this Mac." : "\(source.displayName) data wasn't found on this Mac.") {
                Image(systemName: installed ? "checkmark.circle.fill" : "minus.circle").font(.system(size: 17))
                    .foregroundStyle(installed ? t.accentText : t.p.tertiary)
                    .accessibilityLabel(installed ? "Installed" : "Not installed")
            }
            SettingsDivider()
            SettingsRow(title: "Bookmarks") { Toggle("Import bookmarks", isOn: $bookmarks).labelsHidden().toggleStyle(.checkbox) }
            SettingsDivider()
            SettingsRow(title: "History") { Toggle("Import history", isOn: $history).labelsHidden().toggleStyle(.checkbox) }
            SettingsDivider()
            HStack(spacing: 12) {
                SettingsButton(title: running ? "Importing…" : "Import…", style: .accent) { start() }
                    .disabled(!installed || running || (!bookmarks && !history))
                if running { ProgressView().controlSize(.small) }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            if let report { result(report) }
            if let failure { problem(failure) }
        }
        .onAppear { installed = ImportService.isInstalled(source) }
    }

    @ViewBuilder private func result(_ report: ImportReport) -> some View {
        SettingsDivider()
        SettingsNote(text: summary(report), tone: .good)
        ForEach(report.notes, id: \.self) { SettingsNote(text: $0) }
    }

    private func summary(_ report: ImportReport) -> String {
        var parts: [String] = []
        if report.bookmarksImported > 0 || bookmarks { parts.append("\(report.bookmarksImported) bookmark\(report.bookmarksImported == 1 ? "" : "s")") }
        if report.historyImported > 0 || history { parts.append("\(report.historyImported) history entr\(report.historyImported == 1 ? "y" : "ies")") }
        return "Imported " + parts.joined(separator: " and ") + "."
    }

    @ViewBuilder private func problem(_ failure: ImportFailure) -> some View {
        SettingsDivider()
        SettingsNote(text: failure.message, tone: .error)
        switch failure.kind {
        case .permissionDenied where source == .safari:
            SettingsNote(text: "Safari keeps its data in a protected folder. In System Settings ▸ Privacy & Security ▸ Full Disk Access, turn on Plinth, then try again.", tone: .warning)
            HStack {
                SettingsButton(title: "Open Full Disk Access") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") { NSWorkspace.shared.open(url) }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14).padding(.bottom, 10)
        case .notFound:
            SettingsNote(text: "Open \(source.displayName) once so it creates its data, then try again.")
        case .permissionDenied, .unreadable:
            SettingsNote(text: "Quit \(source.displayName) and try again.")
        }
    }

    private func start() {
        running = true; report = nil; failure = nil
        let source = source, bookmarks = bookmarks, history = history
        Task { @MainActor in
            do {
                report = try await ImportService.run(source, bookmarks: bookmarks, history: history, into: app.store, identity: app.identity)
            } catch let error as ImportFailure {
                failure = error
            } catch {
                failure = ImportFailure(kind: .unreadable, message: "The import didn't finish.")
            }
            running = false
        }
    }
}
