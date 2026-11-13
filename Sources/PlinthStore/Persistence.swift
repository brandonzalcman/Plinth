import Foundation
import PlinthModel

/// A page closed by hand, remembered so it can be reopened where it was.
struct ClosedPage: Codable, Sendable, Equatable {
    var page: Page
    var key: SiteKey
    var siteName: String
    /// The site it was closed from, and its index among that site's pages.
    var siteID: SiteID
    var index: Int
    var window: WindowID
}

/// The on-disk form of the whole store: `state.json`.
struct StoreSnapshot: Codable {
    static let currentVersion = 1
    static let fileName = "state.json"

    var version: Int
    var windows: [WindowState]
    var pins: [PinnedSite]
    var shelf: [ShelfEntry]
    var history: [HistoryEntry]
    /// Keyed by `SiteKey.host`.
    var siteStats: [String: Usage]
    var closed: [ClosedPage]
    /// Page id (UUID string) -> id of the history entry for the page's current visit.
    var latestHistory: [String: UUID]?
    // Added after the first release of version 1: optional so older files still load.
    var groups: [SiteGroup]? = nil
    /// Accumulated co-open time per pair of sites (see Groups.swift for caps and decay).
    var coOpen: [CoOpenRecord]? = nil
    /// Dismissed group suggestions, each a host list sorted ascending.
    var dismissedSuggestions: [[String]]? = nil

    private struct VersionProbe: Decodable { var version: Int }

    enum LoadError: Error { case unknownVersion(Int) }

    static func decode(_ data: Data) throws -> StoreSnapshot {
        let decoder = JSONDecoder()
        let probe = try decoder.decode(VersionProbe.self, from: data)
        guard probe.version == currentVersion else { throw LoadError.unknownVersion(probe.version) }
        return try decoder.decode(StoreSnapshot.self, from: data)
    }

    func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    /// Moves an unreadable state file out of the way so the next save cannot destroy it.
    /// Returns where it went, when the move worked.
    @discardableResult
    static func moveAside(_ file: URL, now: Date) -> URL? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: now)
        let dir = file.deletingLastPathComponent()
        let fm = FileManager.default
        var target = dir.appendingPathComponent("state.corrupt-\(stamp).json")
        var n = 1
        while fm.fileExists(atPath: target.path) {
            n += 1
            target = dir.appendingPathComponent("state.corrupt-\(stamp)-\(n).json")
        }
        do {
            try fm.moveItem(at: file, to: target)
            return target
        } catch {
            return nil
        }
    }
}
