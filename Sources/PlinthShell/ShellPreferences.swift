import Foundation
import Observation


/// Settings that only the Chromium-based builds (Mac and Windows) have, kept next to the shared
/// `settings.json` in a file of their own, so the shared settings file keeps its format.
public struct ShellPreferences: Codable, Equatable, Sendable {
    /// Bottom dock or sidebar, for every window.
    public var tabLayout: TabLayout = .dock
    /// The sidebar is shrunk to its icon rail.
    public var sidebarCollapsed = false
    /// Pin folders the sidebar shows as a titled list of their pins rather than as one icon tile.
    public var listFolders: Set<UUID> = []

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Unknown or missing values fall back to the defaults rather than failing the whole file.
        tabLayout = (try? c.decode(TabLayout.self, forKey: .tabLayout)) ?? .dock
        sidebarCollapsed = (try? c.decode(Bool.self, forKey: .sidebarCollapsed)) ?? false
        listFolders = (try? c.decode(Set<UUID>.self, forKey: .listFolders)) ?? []
    }
}

/// Loads and saves `ShellPreferences`, and tells observers about changes.
@MainActor
@Observable
public final class ShellPreferencesStore {
    public static let fileName = "chromium-settings.json"
    @ObservationIgnored public let fileURL: URL?
    public private(set) var value: ShellPreferences
    @ObservationIgnored private var observers: [(ShellPreferences, ShellPreferences) -> Void] = []

    /// `directory` nil keeps everything in memory (tests).
    public init(directory: URL?, fileName: String = ShellPreferencesStore.fileName) {
        fileURL = directory?.appendingPathComponent(fileName)
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode(ShellPreferences.self, from: data) {
            value = saved
        } else {
            value = ShellPreferences()
        }
    }

    public func update(_ body: (inout ShellPreferences) -> Void) {
        let old = value
        body(&value)
        guard value != old else { return }
        if let fileURL, let data = try? JSONEncoder().encode(value) { try? data.write(to: fileURL, options: .atomic) }
        for observer in observers { observer(old, value) }
    }

    public func observe(_ handler: @escaping (_ old: ShellPreferences, _ new: ShellPreferences) -> Void) {
        observers.append(handler)
    }
}
