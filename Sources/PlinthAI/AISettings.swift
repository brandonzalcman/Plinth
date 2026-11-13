import Foundation

/// The persisted AI master switch, stored in `<storageDirectory>/ai-settings.json`.
/// A missing or unreadable file means the default: on.
@MainActor
public final class AISettings {
    public static let fileName = "ai-settings.json"
    public let fileURL: URL
    public private(set) var isEnabled: Bool

    private struct FileFormat: Codable { var isEnabled: Bool }

    public init(storageDirectory: URL) {
        fileURL = storageDirectory.appending(path: Self.fileName)
        if let data = try? Data(contentsOf: fileURL),
           let file = try? JSONDecoder().decode(FileFormat.self, from: data) {
            isEnabled = file.isEnabled
        } else {
            isEnabled = true
        }
    }

    /// Sets and saves the switch (atomically).
    public func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(FileFormat(isEnabled: enabled)).write(to: fileURL, options: .atomic)
        } catch {
            // Keep the in-memory value; the next change will try to write again.
        }
    }
}
