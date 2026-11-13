import Foundation
import Observation

/// The persisted settings, in `<storageDirectory>/settings.json`. A missing, unreadable or older file
/// yields defaults field by field; nothing is written until a setting changes.
@MainActor
@Observable
public final class SettingsStore {
    public static let fileName = "settings.json"
    public static let currentVersion = 1

    public let fileURL: URL
    public private(set) var value: AppSettings

    @ObservationIgnored private var observers: [(AppSettings, AppSettings) -> Void] = []

    private struct FileFormat: Codable {
        var version: Int
        var settings: AppSettings
    }

    public init(storageDirectory: URL) {
        fileURL = storageDirectory.appending(path: Self.fileName)
        if let data = try? Data(contentsOf: fileURL), let file = try? JSONDecoder().decode(FileFormat.self, from: data) {
            value = file.settings
        } else {
            value = .defaults
        }
    }

    /// Applies `body`, saves, then tells observers (only when something changed).
    public func update(_ body: (inout AppSettings) -> Void) {
        let old = value
        var new = old
        body(&new)
        guard new != old else { return }
        value = new
        save()
        for observer in observers { observer(old, new) }
    }

    /// `handler` runs after every change, on the main actor, with the old and new values.
    public func observe(_ handler: @escaping (_ old: AppSettings, _ new: AppSettings) -> Void) {
        observers.append(handler)
    }

    /// Restores every setting to its default.
    public func resetToDefaults() { update { $0 = .defaults } }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(FileFormat(version: Self.currentVersion, settings: value))
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Keep the in-memory value; the next change tries again.
        }
    }
}
