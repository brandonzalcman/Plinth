import Foundation

// Bookmark and history import from other browsers, for the Chromium-based apps on the Mac and on
// Windows: the Chromium family (Chrome, Edge, Brave, Arc, Vivaldi, Opera, Chromium), the Firefox
// family (Firefox, Zen) and, on the Mac, Safari. Moved here from the Mac Chromium app.

/// A browser Plinth can import from.
public enum ImportSource: String, CaseIterable, Sendable, Identifiable {
    case safari, chrome, edge, brave, arc, vivaldi, opera, chromium, firefox, zen

    public var id: String { rawValue }

    /// How the browser keeps its data. Browsers in one family share a reader.
    public enum Family: Sendable, Equatable {
        /// `Bookmarks.plist` and `History.db` under ~/Library/Safari.
        case safari
        /// A `Bookmarks` JSON file, a `History` database and a `Login Data` database in each profile folder.
        case chromium
        /// `places.sqlite`, `logins.json` and `key4.db` in each profile listed in `profiles.ini`.
        case firefox
    }

    public var displayName: String {
        switch self {
        case .safari: "Safari"
        case .chrome: "Chrome"
        case .edge: "Microsoft Edge"
        case .brave: "Brave"
        case .arc: "Arc"
        case .vivaldi: "Vivaldi"
        case .opera: "Opera"
        case .chromium: "Chromium"
        case .firefox: "Firefox"
        case .zen: "Zen"
        }
    }

    public var family: Family {
        switch self {
        case .safari: .safari
        case .chrome, .edge, .brave, .arc, .vivaldi, .opera, .chromium: .chromium
        case .firefox, .zen: .firefox
        }
    }

    /// The folder that holds the browser's profiles, relative to the home folder.
    var dataPath: String {
        #if os(Windows)
        switch self {
        case .safari: return "AppData/Local/Plinth-no-Safari-on-Windows"
        case .chrome: return "AppData/Local/Google/Chrome/User Data"
        case .edge: return "AppData/Local/Microsoft/Edge/User Data"
        case .brave: return "AppData/Local/BraveSoftware/Brave-Browser/User Data"
        case .arc: return "AppData/Local/Packages/TheBrowserCompany.Arc_ttt1ap7aakyb4/LocalCache/Local/Arc/User Data"
        case .vivaldi: return "AppData/Local/Vivaldi/User Data"
        case .opera: return "AppData/Roaming/Opera Software/Opera Stable"
        case .chromium: return "AppData/Local/Chromium/User Data"
        case .firefox: return "AppData/Roaming/Mozilla/Firefox"
        case .zen: return "AppData/Roaming/zen"
        }
        #else
        switch self {
        case .safari: "Library/Safari"
        case .chrome: "Library/Application Support/Google/Chrome"
        case .edge: "Library/Application Support/Microsoft Edge"
        case .brave: "Library/Application Support/BraveSoftware/Brave-Browser"
        case .arc: "Library/Application Support/Arc/User Data"
        case .vivaldi: "Library/Application Support/Vivaldi"
        case .opera: "Library/Application Support/com.operasoftware.Opera"
        case .chromium: "Library/Application Support/Chromium"
        case .firefox: "Library/Application Support/Firefox"
        case .zen: "Library/Application Support/zen"
        }
        #endif
    }

    /// The browsers this platform can have: no Safari off the Mac.
    public static var supported: [ImportSource] {
        #if os(macOS)
        allCases
        #else
        allCases.filter { $0 != .safari }
        #endif
    }

    /// The folder that holds the browser's profiles.
    public func dataFolder(home: URL) -> URL { home.appendingPathComponent(dataPath, isDirectory: true) }

    /// The Keychain item ("<Browser> Safe Storage") whose password protects a Chromium-family browser's
    /// saved logins. nil for Safari and the Firefox family.
    public var safeStorageItem: (service: String, account: String)? {
        switch self {
        case .chrome: ("Chrome Safe Storage", "Chrome")
        case .edge: ("Microsoft Edge Safe Storage", "Microsoft Edge")
        case .brave: ("Brave Safe Storage", "Brave")
        case .arc: ("Arc Safe Storage", "Arc")
        case .vivaldi: ("Vivaldi Safe Storage", "Vivaldi")
        case .opera: ("Opera Safe Storage", "Opera")
        case .chromium: ("Chromium Safe Storage", "Chromium")
        case .safari, .firefox, .zen: nil
        }
    }
}
