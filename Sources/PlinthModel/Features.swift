import Foundation

// Contracts for the version 1 features added after the bar: groups, navigation info for the
// web layer, downloads, on-device AI, and sync. Value types and protocols only.

// MARK: - Groups

public struct GroupID: Hashable, Codable, Sendable {
    public let raw: UUID
    public init(_ raw: UUID = UUID()) { self.raw = raw }
}

/// Sites the user agreed to treat as one group. Global (not per window), persisted.
public struct SiteGroup: Identifiable, Codable, Sendable, Equatable {
    public let id: GroupID
    /// Distinct, in the order they were suggested.
    public var keys: [SiteKey]
    /// Short display name, e.g. "Docs, Mail & Calendar".
    public var name: String
    public var createdAt: Date

    public init(id: GroupID = GroupID(), keys: [SiteKey], name: String, createdAt: Date) {
        self.id = id; self.keys = keys; self.name = name; self.createdAt = createdAt
    }
}

/// A prompt to group sites that have been open together for a while in one window.
/// Plain rules, no model. Ignoring it changes nothing.
public struct GroupSuggestion: Sendable, Equatable, Hashable {
    public var window: WindowID
    /// Sorted by host so the same set always compares equal.
    public var keys: [SiteKey]
    /// Display names of the sites, in `keys` order.
    public var siteNames: [String]

    public init(window: WindowID, keys: [SiteKey], siteNames: [String]) {
        self.window = window; self.keys = keys; self.siteNames = siteNames
    }
}

// MARK: - Navigation (web layer -> shell)

public enum NavigationKind: String, Sendable, Equatable {
    /// The user clicked a link (WKNavigationType.linkActivated).
    case linkClick
    case formSubmit
    case backForward
    case reload
    /// Script-driven navigation, server redirects, typed loads: never diverted.
    case other
}

/// What the web layer knows about a main-frame navigation it is about to allow.
public struct NavigationRequest: Sendable, Equatable {
    public var url: URL
    public var kind: NavigationKind
    /// The URL of the page the navigation starts from, when there is one.
    public var sourceURL: URL?
    /// The page asked for a new window/target (target=_blank) rather than navigating itself.
    public var wantsNewPage: Bool

    public init(url: URL, kind: NavigationKind, sourceURL: URL?, wantsNewPage: Bool = false) {
        self.url = url; self.kind = kind; self.sourceURL = sourceURL; self.wantsNewPage = wantsNewPage
    }
}

// MARK: - Downloads

public struct DownloadItem: Identifiable, Sendable, Equatable {
    public enum State: Sendable, Equatable { case running, finished, failed(String), cancelled }
    public let id: UUID
    public var filename: String
    /// 0...1, or nil when the size is unknown.
    public var progress: Double?
    public var state: State
    /// Where the file is (or will be) written.
    public var fileURL: URL?
    public var startedAt: Date
    /// Bytes written so far.
    public var receivedBytes: Int64
    /// The expected size, nil when the server did not say.
    public var totalBytes: Int64?
    /// A smoothed transfer rate while running, nil until it has been measured.
    public var bytesPerSecond: Double?
    /// Where it came from (shown as the host under the name).
    public var sourceURL: URL?

    public init(id: UUID = UUID(), filename: String, progress: Double?, state: State, fileURL: URL?, startedAt: Date,
                receivedBytes: Int64 = 0, totalBytes: Int64? = nil, bytesPerSecond: Double? = nil, sourceURL: URL? = nil) {
        self.id = id; self.filename = filename; self.progress = progress; self.state = state
        self.fileURL = fileURL; self.startedAt = startedAt
        self.receivedBytes = receivedBytes; self.totalBytes = totalBytes
        self.bytesPerSecond = bytesPerSecond; self.sourceURL = sourceURL
    }
}

// MARK: - On-device AI

/// Whether inference and embedding may run right now.
public enum AIAvailability: Sendable, Equatable {
    case available
    /// The master switch is off.
    case turnedOff
    /// The system model cannot run on this Mac (not eligible, Apple Intelligence off, model not ready, …).
    case unavailable(reason: String)

    public var isAvailable: Bool { self == .available }
}

/// Readable text pulled from a page, already capped by the extractor.
public struct PageText: Sendable, Equatable, Codable {
    public var url: URL
    public var title: String
    public var text: String
    /// Text around the current scroll position (what the reader was looking at), when known.
    public var focusExcerpt: String?
    /// 0...1 how far down the page the reader is.
    public var scrollFraction: Double?
    public var extractedAt: Date

    public init(url: URL, title: String, text: String, focusExcerpt: String? = nil,
                scrollFraction: Double? = nil, extractedAt: Date) {
        self.url = url; self.title = title; self.text = text; self.focusExcerpt = focusExcerpt
        self.scrollFraction = scrollFraction; self.extractedAt = extractedAt
    }
}

/// A language model. The production one wraps Apple's Foundation Models; tests use a fake.
public protocol TextGenerating: Sendable {
    /// Model-level availability (never `.turnedOff`: the switch lives above this).
    var availability: AIAvailability { get }
    /// About how many characters of prompt (instructions + prompt) fit in one request.
    var contextCharacterBudget: Int { get }
    /// Streams the answer. Each element is the WHOLE answer so far (cumulative), not a delta.
    func stream(prompt: String, instructions: String) -> AsyncThrowingStream<String, Error>
}

public extension TextGenerating {
    /// Runs `stream` to completion and returns the final text.
    func respond(prompt: String, instructions: String) async throws -> String {
        var last = ""
        for try await partial in stream(prompt: prompt, instructions: instructions) { last = partial }
        return last
    }
}

/// Sentence embeddings. Production: NaturalLanguage; tests: a fake.
public protocol TextEmbedding: Sendable {
    var isAvailable: Bool { get }
    /// nil when the text cannot be embedded (empty, unsupported language, model missing).
    func embed(_ text: String) async -> [Float]?
}

/// What "ask" is about.
public enum AskScope: String, Sendable, Equatable, CaseIterable {
    /// The selected page.
    case page
    /// Every open page of the selected page's site in this window.
    case site
    /// The two pages of the split on screen (compare).
    case split
}

/// One semantic-history hit.
public struct SemanticMatch: Sendable, Equatable {
    public var url: URL
    public var title: String
    public var key: SiteKey
    /// Cosine similarity, higher is closer.
    public var score: Double

    public init(url: URL, title: String, key: SiteKey, score: Double) {
        self.url = url; self.title = title; self.key = key; self.score = score
    }
}

// MARK: - Sync

/// The synced part of the store. Windows are never synced; each Mac publishes its open pages
/// separately as a read-only `DeviceOpenPages`.
public struct SyncPayload: Sendable, Equatable, Codable {
    public var pins: [PinnedSite]
    public var shelf: [ShelfEntry]
    public var history: [HistoryEntry]

    public init(pins: [PinnedSite], shelf: [ShelfEntry], history: [HistoryEntry]) {
        self.pins = pins; self.shelf = shelf; self.history = history
    }
}

public struct OpenPageSummary: Sendable, Equatable, Codable, Hashable {
    public var url: URL
    public var name: String
    public var title: String
    public var key: SiteKey

    public init(url: URL, name: String, title: String, key: SiteKey) {
        self.url = url; self.name = name; self.title = title; self.key = key
    }
}

/// One Mac's open pages, as other Macs see them (read-only there).
public struct DeviceOpenPages: Sendable, Equatable, Codable, Identifiable {
    public var id: String { deviceID }
    public var deviceID: String
    public var deviceName: String
    public var updatedAt: Date
    public var pages: [OpenPageSummary]

    public init(deviceID: String, deviceName: String, updatedAt: Date, pages: [OpenPageSummary]) {
        self.deviceID = deviceID; self.deviceName = deviceName; self.updatedAt = updatedAt; self.pages = pages
    }
}
