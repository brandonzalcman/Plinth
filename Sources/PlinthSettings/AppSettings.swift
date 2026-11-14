import Foundation
import PlinthRules

/// What a new page shows.
public enum NewPageContent: String, Codable, CaseIterable, Sendable {
    /// The search / address bar opens (the 0.1.0 behaviour).
    case commandBar
    /// The homepage URL loads (falls back to the command bar when no homepage is set).
    case homepage
    /// A blank page (`about:blank`).
    case blank
}

/// How Plinth treats pages at launch.
public enum StartupBehavior: String, Codable, CaseIterable, Sendable {
    /// Bring back the windows and pages that were open (the 0.1.0 behaviour).
    case restoreLastSession
    /// Put the open pages away on the shelf and start with an empty window.
    case startFresh
}

/// Whether Plinth's own chrome is light, dark or follows the Mac.
public enum AppearanceChoice: String, Codable, CaseIterable, Sendable {
    case system, light, dark

    public var displayName: String { rawValue.capitalized }
}

public enum AccentChoice: String, Codable, CaseIterable, Sendable {
    case blue, purple, pink, red, orange, green, graphite
    /// The brand colourways, unlocked by loyalty level (see `PlinthLoyalty`; the raw values match its ids).
    case dusk, meadow, ember, midnight, mono

    public var displayName: String { rawValue.capitalized }

    /// sRGB components 0...255.
    public var rgb: (r: Double, g: Double, b: Double) {
        switch self {
        case .blue: (0x2F, 0x5B, 0xEA)
        case .purple: (0x8B, 0x5C, 0xF6)
        case .pink: (0xE0, 0x4F, 0x9B)
        case .red: (0xE5, 0x48, 0x4D)
        case .orange: (0xF0, 0x8A, 0x24)
        case .green: (0x2E, 0xA0, 0x6B)
        case .graphite: (0x6B, 0x72, 0x80)
        case .dusk: (0xB0, 0x50, 0x9A)
        case .meadow: (0x0F, 0x6B, 0x5B)
        case .ember: (0xB8, 0x36, 0x1E)
        case .midnight: (0x0B, 0x1E, 0x5B)
        case .mono: (0x1C, 0x1C, 0x1A)
        }
    }
}

/// How long sites stay on the bar before fading to the shelf.
public enum FadeBehavior: String, Codable, CaseIterable, Sendable {
    case shorter, standard, longer
    /// Nothing fades by itself; pages leave the bar only when you put them away.
    case never

    public var displayName: String {
        switch self {
        case .shorter: "Shorter"
        case .standard: "Standard"
        case .longer: "Longer"
        case .never: "Never fade"
        }
    }

    /// Multiplier for every lifetime in `FadePolicy`.
    public var lifetimeScale: Double {
        switch self {
        case .shorter: 0.5
        case .standard: 1
        case .longer: 2
        case .never: .infinity
        }
    }
}

/// Every user-changeable setting. Decoding is tolerant: a field missing from an older file takes its default.
public struct AppSettings: Codable, Equatable, Sendable {
    // General
    public var searchEngine = SearchEngine.duckDuckGo

    // Privacy & security
    public var contentBlockerEnabled = true
    public var blockThirdPartyCookies = false
    public var httpsOnly = false
    public var globalPrivacyControl = false
    /// Ask the search engine for suggestions while typing in the command bar (sends the text you type to it).
    public var searchSuggestionsEnabled = true

    // Downloads
    /// Absolute path; nil means the system Downloads folder.
    public var downloadFolder: String? = nil
    public var askWhereToSave = false
    public var openSafeFilesAfterDownload = false

    // Startup & new pages
    public var startup = StartupBehavior.restoreLastSession
    public var newPage = NewPageContent.commandBar
    /// Empty means none.
    public var homepage = ""

    // Appearance & bar
    public var appearance = AppearanceChoice.system
    public var accent = AccentChoice.blue
    /// The app icon: a brand colourway id (`sunrise` is the default and always available).
    public var appIcon = "sunrise"
    public var fadeBehavior = FadeBehavior.standard
    /// 0.5 ... 3, 1 = 100%.
    public var defaultZoom = 1.0
    /// CSS pixels, 9 ... 72. 16 is the web's default.
    public var defaultFontSize = 16
    /// 0 means no minimum, else 6 ... 36.
    public var minimumFontSize = 0

    // AI (the master switch stays in `AISettings`, file `ai-settings.json`)
    public var semanticSearchEnabled = true
    public var pageSummariesEnabled = true

    // First run
    /// Set once the welcome guide has been finished or skipped. "Reset to defaults" keeps it.
    public var hasCompletedOnboarding = false

    public init() {}

    public static let defaults = AppSettings()

    private enum CodingKeys: String, CodingKey {
        case searchEngine, contentBlockerEnabled, blockThirdPartyCookies, httpsOnly, globalPrivacyControl, searchSuggestionsEnabled
        case downloadFolder, askWhereToSave, openSafeFilesAfterDownload
        case startup, newPage, homepage
        case appearance, hasCompletedOnboarding
        case accent, appIcon, fadeBehavior, defaultZoom, defaultFontSize, minimumFontSize
        case semanticSearchEnabled, pageSummariesEnabled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func get<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T { (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback }
        let d = AppSettings()
        searchEngine = get(.searchEngine, d.searchEngine)
        contentBlockerEnabled = get(.contentBlockerEnabled, d.contentBlockerEnabled)
        blockThirdPartyCookies = get(.blockThirdPartyCookies, d.blockThirdPartyCookies)
        httpsOnly = get(.httpsOnly, d.httpsOnly)
        globalPrivacyControl = get(.globalPrivacyControl, d.globalPrivacyControl)
        searchSuggestionsEnabled = get(.searchSuggestionsEnabled, d.searchSuggestionsEnabled)
        downloadFolder = (try? c.decodeIfPresent(String.self, forKey: .downloadFolder)) ?? nil
        askWhereToSave = get(.askWhereToSave, d.askWhereToSave)
        openSafeFilesAfterDownload = get(.openSafeFilesAfterDownload, d.openSafeFilesAfterDownload)
        startup = get(.startup, d.startup)
        newPage = get(.newPage, d.newPage)
        homepage = get(.homepage, d.homepage)
        appearance = get(.appearance, d.appearance)
        hasCompletedOnboarding = get(.hasCompletedOnboarding, d.hasCompletedOnboarding)
        accent = get(.accent, d.accent)
        appIcon = get(.appIcon, d.appIcon)
        fadeBehavior = get(.fadeBehavior, d.fadeBehavior)
        defaultZoom = min(max(get(.defaultZoom, d.defaultZoom), 0.5), 3)
        defaultFontSize = min(max(get(.defaultFontSize, d.defaultFontSize), 9), 72)
        minimumFontSize = get(.minimumFontSize, d.minimumFontSize)
        if minimumFontSize != 0 { minimumFontSize = min(max(minimumFontSize, 6), 36) }
        semanticSearchEnabled = get(.semanticSearchEnabled, d.semanticSearchEnabled)
        pageSummariesEnabled = get(.pageSummariesEnabled, d.pageSummariesEnabled)
    }

    /// The homepage as a URL, when one is set and usable (bare hosts get https).
    public var homepageURL: URL? {
        let text = homepage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if case .url(let url) = AddressResolver().resolve(text) { return url }
        return nil
    }
}

/// Which kinds of data "Clear Browsing Data" removes.
public struct BrowsingDataKinds: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let history = BrowsingDataKinds(rawValue: 1)
    /// Cookies and site data (local storage, IndexedDB, service workers…).
    public static let cookiesAndSiteData = BrowsingDataKinds(rawValue: 2)
    public static let cache = BrowsingDataKinds(rawValue: 4)
    public static let all: BrowsingDataKinds = [.history, .cookiesAndSiteData, .cache]
}

public enum ClearRange: String, CaseIterable, Sendable {
    case lastHour, today, lastWeek, allTime

    public var displayName: String {
        switch self {
        case .lastHour: "Last hour"
        case .today: "Today"
        case .lastWeek: "Last 7 days"
        case .allTime: "All time"
        }
    }

    /// The start of the range; nil means everything.
    public func since(now: Date = Date(), calendar: Calendar = .current) -> Date? {
        switch self {
        case .lastHour: now.addingTimeInterval(-3600)
        case .today: calendar.startOfDay(for: now)
        case .lastWeek: now.addingTimeInterval(-7 * 86400)
        case .allTime: nil
        }
    }
}
