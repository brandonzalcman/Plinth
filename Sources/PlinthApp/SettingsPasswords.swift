import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PlinthImport
import PlinthPasswords

struct PasswordsSettingsView: View {
    let app: AppController
    @State private var query = ""
    @State private var draft: PasswordDraft?
    @State private var message: String?
    @State private var messageIsError = false

    private var controller: PasswordsController { app.passwords }

    var body: some View {
        SettingsPage(title: "Passwords", subtitle: "Plinth keeps logins in your Mac's Keychain and fills them only on the exact site they were saved for.") {
            savingCard
            loginsCard
            if let draft { PasswordEditor(controller: controller, draft: draft, done: { finishEditing($0) }) }
            PasswordImportCards(app: app)
        }
    }

    // MARK: Saving

    private var savingCard: some View {
        SettingsCard(heading: "Saving") {
            SettingsToggleRow(title: "Offer to save passwords", caption: "After you sign in, Plinth asks whether to keep the login.",
                              isOn: Binding(get: { controller.preferences.offerToSave }, set: { controller.preferences.setOfferToSave($0) }))
            ForEach(controller.preferences.neverSave, id: \.self) { origin in
                SettingsDivider()
                SettingsRow(title: origin.displayHost, caption: "Never ask to save passwords here.") {
                    SettingsButton(title: "Remove") { controller.preferences.removeNever(origin) }
                }
            }
        }
    }

    // MARK: List

    private var filtered: [LoginSummary] {
        let all = controller.model.logins
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all }
        return all.filter { $0.origin.host.contains(q) || $0.username.lowercased().contains(q) }
    }

    private var loginsCard: some View {
        SettingsCard(heading: "Saved passwords") {
            HStack(spacing: 10) {
                SettingsTextField(label: "Search passwords", placeholder: "Search", text: $query, width: 220)
                Spacer(minLength: 0)
                SettingsButton(title: "Add…", systemImage: "plus") { draft = PasswordDraft() }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            if let error = controller.model.error {
                SettingsDivider()
                SettingsNote(text: error, tone: .error)
            } else if filtered.isEmpty {
                SettingsDivider()
                SettingsNote(text: controller.model.logins.isEmpty ? "No saved passwords yet. They appear here after you sign in to a site, or import them below." : "No passwords match “\(query)”.")
            }
            ForEach(filtered) { login in
                SettingsDivider()
                PasswordRow(controller: controller, login: login, edit: { draft = $0 })
            }
            if let message {
                SettingsDivider()
                SettingsNote(text: message, tone: messageIsError ? .error : .good)
            }
        }
        .onAppear { controller.model.reload() }
    }

    private func finishEditing(_ outcome: PasswordEditor.Outcome) {
        draft = nil
        switch outcome {
        case .cancelled: break
        case .saved: message = "Saved."; messageIsError = false
        case .failed(let text): message = text; messageIsError = true
        }
        controller.model.reload()
    }
}

struct PasswordDraft: Identifiable {
    let id = UUID()
    var original: LoginKey?
    var site = ""
    var username = ""
    var password = ""
}

// MARK: - One saved login

private struct PasswordRow: View {
    let controller: PasswordsController
    let login: LoginSummary
    var edit: (PasswordDraft) -> Void
    @Environment(\.settingsTheme) private var t
    @State private var revealed: String?
    @State private var confirmingDelete = false
    @State private var problem: String?
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(login.origin.displayHost).font(.system(size: 13, weight: .medium)).foregroundStyle(t.p.primary).lineLimit(1)
                        if !login.origin.isSecure {
                            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(t.amber)
                                .help("Saved for an unsecured (http) site.").accessibilityLabel("Unsecured site")
                        }
                    }
                    Text(login.username.isEmpty ? "No user name" : login.username).font(.system(size: 11.5)).foregroundStyle(t.p.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                if let revealed {
                    Text(revealed).font(.system(size: 12, design: .monospaced)).foregroundStyle(t.p.primary)
                        .textSelection(.enabled).lineLimit(1).truncationMode(.middle).frame(maxWidth: 150, alignment: .trailing)
                }
                IconButton(symbol: revealed == nil ? "eye" : "eye.slash", label: revealed == nil ? "Show password" : "Hide password") { toggleReveal() }
                IconButton(symbol: "doc.on.doc", label: "Copy password") { copy() }
                IconButton(symbol: "pencil", label: "Edit login") { startEdit() }
                IconButton(symbol: "trash", label: "Delete login", destructive: true) { confirmingDelete = true }
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            if let problem { SettingsNote(text: problem, tone: .error) }
        }
        .confirmationDialog("Delete the password for \(login.username.isEmpty ? "this login" : login.username) on \(login.origin.displayHost)?",
                            isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { delete() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This can't be undone.") }
        .onDisappear { hideTask?.cancel() }
    }

    private func secret(reason: String) async -> String? {
        problem = nil
        guard await controller.authenticator.authenticate(reason: reason) else { problem = "Authentication didn't complete, so the password stays hidden."; return nil }
        do {
            if let value = try controller.vault.password(for: login.key) { return value }
            problem = "That password is no longer in the Keychain."
        } catch { problem = "Plinth couldn't read the Keychain right now." }
        return nil
    }

    private func toggleReveal() {
        if revealed != nil { revealed = nil; hideTask?.cancel(); return }
        Task { @MainActor in
            guard let value = await secret(reason: "show the password for \(login.origin.displayHost)") else { return }
            revealed = value
            hideTask?.cancel()
            hideTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(20))
                if !Task.isCancelled { revealed = nil }
            }
        }
    }

    private func copy() {
        Task { @MainActor in
            guard let value = await secret(reason: "copy the password for \(login.origin.displayHost)") else { return }
            controller.copyToClipboard(value)
        }
    }

    private func startEdit() {
        Task { @MainActor in
            guard let value = await secret(reason: "edit the password for \(login.origin.displayHost)") else { return }
            edit(PasswordDraft(original: login.key, site: login.origin.description, username: login.username, password: value))
        }
    }

    private func delete() {
        do { try controller.vault.delete(login.key); controller.model.reload() }
        catch { problem = "Plinth couldn't delete that login." }
    }
}

private struct IconButton: View {
    var symbol: String
    var label: String
    var destructive = false
    var action: () -> Void
    @Environment(\.settingsTheme) private var t
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(destructive ? t.danger : t.p.primary)
                .frame(width: 28, height: 26)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovered ? t.p.hover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

// MARK: - Add / edit

private struct PasswordEditor: View {
    enum Outcome { case cancelled, saved, failed(String) }
    let controller: PasswordsController
    @State var draft: PasswordDraft
    var done: (Outcome) -> Void
    @Environment(\.settingsTheme) private var t
    @State private var showPassword = false
    @State private var error: String?

    init(controller: PasswordsController, draft: PasswordDraft, done: @escaping (Outcome) -> Void) {
        self.controller = controller
        self._draft = State(initialValue: draft)
        self.done = done
    }

    var body: some View {
        SettingsCard(heading: draft.original == nil ? "Add a password" : "Edit password") {
            SettingsRow(title: "Website", caption: "For example https://example.com") {
                SettingsTextField(label: "Website", placeholder: "https://example.com", text: $draft.site, width: 240)
            }
            SettingsDivider()
            SettingsRow(title: "User name") {
                SettingsTextField(label: "User name", placeholder: "name@example.com", text: $draft.username, width: 240)
            }
            SettingsDivider()
            SettingsRow(title: "Password") {
                HStack(spacing: 6) {
                    Group {
                        if showPassword { TextField("Password", text: $draft.password) } else { SecureField("Password", text: $draft.password) }
                    }
                    .textFieldStyle(.plain).font(.system(size: 12.5)).foregroundStyle(t.p.primary)
                    .padding(.horizontal, 12).frame(width: 206, height: 28)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(t.p.inputFill))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(t.p.border, lineWidth: 0.5))
                    .autocorrectionDisabled()
                    .accessibilityLabel("Password")
                    IconButton(symbol: showPassword ? "eye.slash" : "eye", label: showPassword ? "Hide password" : "Show password") { showPassword.toggle() }
                }
            }
            if let error { SettingsNote(text: error, tone: .error) }
            SettingsDivider()
            HStack(spacing: 10) {
                SettingsButton(title: "Save", style: .accent) { save() }
                    .disabled(draft.site.isEmpty || draft.password.isEmpty)
                SettingsButton(title: "Cancel") { done(.cancelled) }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
    }

    private func save() {
        guard let origin = WebOrigin(string: draft.site) else { error = "Enter a website like https://example.com."; return }
        let login = Login(origin: origin, username: draft.username, password: draft.password)
        do {
            if let original = draft.original { try controller.vault.replace(original, with: login) }
            else if (try controller.vault.password(for: login.key)) != nil { error = "A password for that user on that site is already saved. Edit it instead."; return }
            else { try controller.vault.save(login) }
            done(.saved)
        } catch { done(.failed("Plinth couldn't save to the Keychain.")) }
    }
}

// MARK: - Import

private struct PasswordImportCards: View {
    let app: AppController
    @Environment(\.settingsTheme) private var t
    @State private var running: ImportSource?
    @State private var csvRunning = false
    @State private var result: String?
    @State private var failure: ImportFailure?
    @State private var csvError: String?

    private let sources: [ImportSource] = [.chrome, .arc, .zen]

    var body: some View {
        SettingsCard(heading: "Import passwords") {
            ForEach(Array(sources.enumerated()), id: \.element) { index, source in
                if index > 0 { SettingsDivider() }
                let installed = ImportService.isInstalled(source)
                SettingsRow(title: source.displayName, caption: caption(source, installed: installed)) {
                    SettingsButton(title: running == source ? "Importing…" : "Import…") { start(source) }
                        .disabled(!installed || running != nil || csvRunning)
                }
            }
            SettingsDivider()
            SettingsRow(title: "CSV file", caption: "From Safari or the Passwords app (File ▸ Export All Passwords), Chrome, 1Password or Bitwarden. Delete the file afterwards: it holds your passwords as plain text.") {
                SettingsButton(title: "Choose File…") { chooseCSV() }.disabled(running != nil || csvRunning)
            }
            if let result { SettingsDivider(); SettingsNote(text: result, tone: .good) }
            if let csvError { SettingsDivider(); SettingsNote(text: csvError, tone: .error) }
            if let failure {
                SettingsDivider()
                SettingsNote(text: failure.message, tone: isPrimaryPassword(failure) ? .warning : .error)
            }
        }
    }

    private func isPrimaryPassword(_ failure: ImportFailure) -> Bool { failure.message.contains("primary password") }

    private func caption(_ source: ImportSource, installed: Bool) -> String {
        guard installed else { return "\(source.displayName) data wasn't found on this Mac." }
        switch source {
        case .chrome, .arc: return "macOS will ask to let Plinth use “\(source.displayName) Safe Storage”. Choose Allow."
        case .zen: return "Works when Zen has no primary password."
        case .safari: return ""
        }
    }

    private func report(added: Int, duplicates: Int, failed: Int, skipped: Int = 0) {
        var text = "Imported \(added) password\(added == 1 ? "" : "s")."
        if duplicates > 0 { text += " \(duplicates) already saved." }
        if skipped > 0 { text += " \(skipped) skipped (no site, user name or password)." }
        if failed > 0 { text += " \(failed) couldn't be saved to the Keychain." }
        result = text
    }

    private func start(_ source: ImportSource) {
        running = source; result = nil; failure = nil; csvError = nil
        Task { @MainActor in
            defer { running = nil }
            let outcome = await Task.detached { () -> Result<[ImportedLogin], ImportFailure> in
                do throws(ImportFailure) { return .success(try ImportService.passwords(from: source)) }
                catch { return .failure(error) }
            }.value
            switch outcome {
            case .failure(let error): failure = error
            case .success(let imported):
                let logins = imported.compactMap { item -> Login? in
                    guard let origin = WebOrigin(url: item.url) else { return nil }
                    return Login(origin: origin, username: item.username, password: item.password, created: item.created ?? Date())
                }
                let merged = app.passwords.vault.merge(logins)
                app.passwords.model.reload()
                report(added: merged.added, duplicates: merged.duplicates, failed: merged.failed, skipped: imported.count - logins.count)
            }
        }
    }

    private func chooseCSV() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        panel.message = "Choose a CSV file of passwords."
        let apply: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            importCSV(url)
        }
        if let window = app.settingsWindow?.window { panel.beginSheetModal(for: window, completionHandler: apply) } else { panel.begin(completionHandler: apply) }
    }

    private func importCSV(_ url: URL) {
        result = nil; failure = nil; csvError = nil
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { csvError = "Plinth couldn't read that file."; return }
        do {
            let parsed = try CSVImport.parse(text)
            let merged = app.passwords.vault.merge(parsed.logins)
            app.passwords.model.reload()
            report(added: merged.added, duplicates: merged.duplicates, failed: merged.failed, skipped: parsed.skipped)
        } catch {
            csvError = "That file doesn't look like a password export. It needs a header row with URL, user name and password columns."
        }
    }
}
