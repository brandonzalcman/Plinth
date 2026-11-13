import Foundation
import PlinthModel
import PlinthRules
import PlinthStore

// CONTRACT (the settings UI codes against this; the import agent implements it behind the same signatures).

public enum ImportSource: String, CaseIterable, Sendable {
    case safari, chrome
    public var displayName: String { self == .safari ? "Safari" : "Chrome" }
}

/// What an import did, in numbers and plain-language notes the UI shows as is.
public struct ImportReport: Sendable, Equatable {
    public var bookmarksImported = 0
    public var historyImported = 0
    /// e.g. "Bookmark folders aren't kept: Plinth has no folders, so bookmarks were added to the shelf by site."
    public var notes: [String] = []
    public init() {}
}

/// A failure with a message fit for the screen.
public struct ImportFailure: Error, Equatable, Sendable {
    public enum Kind: Sendable, Equatable { case notFound, permissionDenied, unreadable }
    public var kind: Kind
    public var message: String
    public init(kind: Kind, message: String) { self.kind = kind; self.message = message }
}

public enum ImportService {
    /// True when the browser's data folder exists (it can still be unreadable: see `permissionDenied`).
    public static func isInstalled(_ source: ImportSource, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool { false }

    /// Reads bookmarks and/or history from `source` and adds them to `store`. Never throws anything but `ImportFailure`
    /// and never crashes on missing, locked or malformed files.
    @MainActor
    public static func run(_ source: ImportSource, bookmarks: Bool, history: Bool, into store: BrowserStore,
                           identity: SiteIdentity, home: URL = FileManager.default.homeDirectoryForCurrentUser) async throws -> ImportReport {
        throw ImportFailure(kind: .notFound, message: "Not implemented yet.")
    }
}
