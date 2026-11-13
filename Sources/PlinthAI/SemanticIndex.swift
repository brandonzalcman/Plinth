import Foundation
import PlinthModel

/// One page in the semantic index.
public struct IndexedPage: Sendable, Equatable, Codable {
    /// The normalised URL (see `SemanticIndex.normalizedKey(for:)`).
    public var key: String
    public var url: URL
    public var title: String
    public var site: SiteKey
    public var historyEntryID: UUID
    public var indexedAt: Date
    /// Unit length, so cosine similarity is a dot product. Title plus the start of the text.
    public var vector: [Float]
    /// Extra unit vectors for the title alone and a few short passages. Sentence embeddings of a
    /// long text drown a short query, so a page scores by its best-matching vector.
    public var passageVectors: [[Float]] = []

    public init(key: String, url: URL, title: String, site: SiteKey, historyEntryID: UUID, indexedAt: Date, vector: [Float]) {
        self.key = key; self.url = url; self.title = title; self.site = site
        self.historyEntryID = historyEntryID; self.indexedAt = indexedAt; self.vector = vector
    }

    enum CodingKeys: String, CodingKey { case key, url, title, site, historyEntryID, indexedAt, vector, passages }

    static func decodeVector(_ data: Data) -> [Float] {
        data.withUnsafeBytes { raw in
            stride(from: 0, to: raw.count - raw.count % 4, by: 4).map {
                Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: $0, as: UInt32.self)))
            }
        }
    }

    static func encodeVector(_ vector: [Float]) -> Data {
        var data = Data(capacity: vector.count * 4)
        for v in vector { withUnsafeBytes(of: v.bitPattern.littleEndian) { data.append(contentsOf: $0) } }
        return data
    }

    /// Every vector of the page.
    var allVectors: [[Float]] { [vector] + passageVectors }

    // Vectors are stored as base64 little-endian Float32, about a third the size of a JSON array.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        url = try c.decode(URL.self, forKey: .url)
        title = try c.decode(String.self, forKey: .title)
        site = try c.decode(SiteKey.self, forKey: .site)
        historyEntryID = try c.decode(UUID.self, forKey: .historyEntryID)
        indexedAt = try c.decode(Date.self, forKey: .indexedAt)
        vector = Self.decodeVector(try c.decode(Data.self, forKey: .vector))
        passageVectors = (try c.decodeIfPresent([Data].self, forKey: .passages) ?? []).map(Self.decodeVector)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(key, forKey: .key)
        try c.encode(url, forKey: .url)
        try c.encode(title, forKey: .title)
        try c.encode(site, forKey: .site)
        try c.encode(historyEntryID, forKey: .historyEntryID)
        try c.encode(indexedAt, forKey: .indexedAt)
        try c.encode(Self.encodeVector(vector), forKey: .vector)
        if !passageVectors.isEmpty { try c.encode(passageVectors.map(Self.encodeVector), forKey: .passages) }
    }
}

/// A local embedding index of visited pages, for finding past pages by meaning.
///
/// One entry per normalised URL. Stored in `<storageDirectory>/semantic-index.json`, loaded on
/// init and written atomically shortly after each change (or at once with `flush()`). The oldest
/// entries are dropped beyond `maxEntries`.
public actor SemanticIndex {
    public static let fileName = "semantic-index.json"
    /// Minimum dwell for a visit to be indexed.
    public static let minimumDwell: TimeInterval = 30
    /// Characters of page text embedded with the title.
    public static let textPrefixLength = 1500

    public nonisolated let fileURL: URL
    public nonisolated let maxEntries: Int
    public nonisolated let minimumScore: Double
    private let embedder: any TextEmbedding
    private let saveDelay: Duration
    private let now: @Sendable () -> Date

    private var entries: [String: IndexedPage] = [:]
    private var saveTask: Task<Void, Never>?
    private var dirty = false

    private struct FileFormat: Codable { var version: Int; var entries: [IndexedPage] }

    /// - Parameters:
    ///   - minimumScore: cosine similarity below which a page is not a match. With NaturalLanguage
    ///     sentence embeddings real matches score about 0.34-0.6 and unrelated pages up to about 0.3.
    ///   - saveDelay: how long after a change the file is written (coalescing bursts); `.zero`
    ///     writes immediately after every change.
    public init(storageDirectory: URL, embedder: any TextEmbedding, maxEntries: Int = 5000,
                minimumScore: Double = 0.3, saveDelay: Duration = .seconds(2),
                now: @escaping @Sendable () -> Date = Date.init) {
        self.fileURL = storageDirectory.appending(path: Self.fileName)
        self.embedder = embedder
        self.maxEntries = max(1, maxEntries)
        self.minimumScore = minimumScore
        self.saveDelay = saveDelay
        self.now = now
        if let data = try? Data(contentsOf: fileURL),
           let file = try? JSONDecoder().decode(FileFormat.self, from: data) {
            for entry in file.entries { entries[entry.key] = entry }
        }
    }

    // MARK: - Rules

    /// True when a visit is worth indexing: at least 30 s frontmost and an http(s) URL.
    public static func shouldIndex(_ entry: HistoryEntry) -> Bool {
        guard entry.dwell >= minimumDwell, let scheme = entry.url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    /// The identity of a page in the index: lowercased scheme and host, no fragment, no default
    /// port, no trailing slash (except the root). The query is kept.
    public static func normalizedKey(for url: URL) -> String {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        c.scheme = c.scheme?.lowercased()
        c.host = c.host?.lowercased()
        c.fragment = nil
        if (c.scheme == "http" && c.port == 80) || (c.scheme == "https" && c.port == 443) { c.port = nil }
        if c.path.count > 1, c.path.hasSuffix("/") { c.path.removeLast() }
        if c.path.isEmpty { c.path = "/" }
        if c.query?.isEmpty == true { c.query = nil }
        return c.string ?? url.absoluteString
    }

    /// The text that gets embedded for a page.
    public static func embeddingInput(title: String, text: String) -> String {
        let body = TextChunker.collapseSpaces(String(text.prefix(textPrefixLength * 2)))
        return title.trimmingCharacters(in: .whitespacesAndNewlines) + "\n" + String(body.prefix(textPrefixLength))
    }

    /// Short pieces embedded on their own: the title, then up to `maxPassages` distinct passages
    /// of about 300 characters spread over the first part of the text.
    static let maxPassages = 4
    static func passages(title: String, text: String) -> [String] {
        var pieces: [String] = []
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { pieces.append(t) }
        var seen = Set<String>()
        for chunk in TextChunker(maxCharacters: 300).chunks(String(text.prefix(6000))) {
            let c = TextChunker.collapseSpaces(chunk)
            guard c.count >= 40, seen.insert(c).inserted else { continue }
            pieces.append(c)
            if pieces.count > maxPassages { break }
        }
        return pieces
    }

    // MARK: - Operations

    public var count: Int { entries.count }

    public func contains(url: URL) -> Bool { entries[Self.normalizedKey(for: url)] != nil }

    public func entry(for url: URL) -> IndexedPage? { entries[Self.normalizedKey(for: url)] }

    /// Embeds and stores the page for `entry` (replacing any previous entry for the same URL).
    /// Returns false when the entry does not qualify or the text cannot be embedded.
    @discardableResult
    public func add(entry: HistoryEntry, text: String) async -> Bool {
        guard Self.shouldIndex(entry), embedder.isAvailable else { return false }
        let title = entry.title.isEmpty ? entry.name : entry.title
        guard let raw = await embedder.embed(Self.embeddingInput(title: title, text: text)),
              let vector = Self.normalized(raw), !Task.isCancelled else { return false }
        var passages: [[Float]] = []
        for piece in Self.passages(title: title, text: text) {
            if Task.isCancelled { return false }
            if let raw = await embedder.embed(piece), let v = Self.normalized(raw), v.count == vector.count { passages.append(v) }
        }
        let key = Self.normalizedKey(for: entry.url)
        var page = IndexedPage(key: key, url: entry.url, title: title, site: entry.key,
                               historyEntryID: entry.id, indexedAt: now(), vector: vector)
        page.passageVectors = passages
        entries[key] = page
        trim()
        changed()
        return true
    }

    /// Pages closest in meaning to `query`, best first, scoring at least `minimumScore`.
    public func search(_ query: String, limit: Int) async -> [SemanticMatch] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard limit > 0, !trimmed.isEmpty, !entries.isEmpty, embedder.isAvailable,
              let raw = await embedder.embed(trimmed), let q = Self.normalized(raw) else { return [] }
        var scored: [(IndexedPage, Double)] = []
        for entry in entries.values where entry.vector.count == q.count {
            let score = entry.allVectors.map { Self.dot($0, q) }.max() ?? 0
            if score >= minimumScore { scored.append((entry, score)) }
        }
        scored.sort { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.indexedAt > $1.0.indexedAt }
        return scored.prefix(limit).map { SemanticMatch(url: $0.0.url, title: $0.0.title, key: $0.0.site, score: $0.1) }
    }

    public func remove(url: URL) {
        if entries.removeValue(forKey: Self.normalizedKey(for: url)) != nil { changed() }
    }

    /// Removes every page of a site (for "forget this site").
    public func remove(site: SiteKey) {
        let before = entries.count
        entries = entries.filter { $0.value.site != site }
        if entries.count != before { changed() }
    }

    public func removeAll() {
        entries.removeAll()
        changed()
    }

    /// Writes pending changes now.
    public func flush() {
        saveTask?.cancel(); saveTask = nil
        guard dirty else { return }
        save()
    }

    // MARK: - Internals

    private func trim() {
        guard entries.count > maxEntries else { return }
        let excess = entries.count - maxEntries
        for old in entries.values.sorted(by: { $0.indexedAt < $1.indexedAt }).prefix(excess) {
            entries[old.key] = nil
        }
    }

    private func changed() {
        dirty = true
        if saveDelay <= .zero { save(); return }
        guard saveTask == nil else { return }
        let delay = saveDelay
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.delayedSave()
        }
    }

    private func delayedSave() {
        saveTask = nil
        if dirty { save() }
    }

    private func save() {
        dirty = false
        let file = FileFormat(version: 1, entries: entries.values.sorted { $0.indexedAt < $1.indexedAt })
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(file).write(to: fileURL, options: .atomic)
        } catch {
            dirty = true
        }
    }

    static func normalized(_ v: [Float]) -> [Float]? {
        var sum: Float = 0
        for x in v { sum += x * x }
        guard sum > 0, sum.isFinite else { return nil }
        let inv = 1 / sum.squareRoot()
        return v.map { $0 * inv }
    }

    static func dot(_ a: [Float], _ b: [Float]) -> Double {
        var s: Float = 0
        for i in 0..<min(a.count, b.count) { s += a[i] * b[i] }
        return Double(s)
    }
}
