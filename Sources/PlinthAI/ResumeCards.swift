import Foundation
import PlinthModel

/// "Where you left off" cards: one or two sentences built from a page's title, the text around
/// the reader's scroll position and how far down they were.
///
/// Cards are generated lazily (only when asked for) and cached per page, keyed by a hash of the
/// page text, focus excerpt and scroll position (in tenths), so asking again for an unchanged
/// page does not call the model. Concurrent requests for the same page share one generation.
@MainActor
public final class ResumeCardService {
    public let generator: any TextGenerating
    private let pipeline: SummaryPipeline

    /// Longest card returned.
    public nonisolated static let maxCardCharacters = 280
    /// Longest focus excerpt sent to the model.
    nonisolated static let maxFocusCharacters = 1200

    private struct Cached { var hash: UInt64; var card: String }
    private var cache: [PageID: Cached] = [:]
    private var inFlight: [PageID: (hash: UInt64, task: Task<String?, Never>)] = [:]

    public init(generator: any TextGenerating) {
        self.generator = generator
        self.pipeline = SummaryPipeline(generator: generator)
    }

    /// The card for `page`, or nil when the model is unavailable, the page has no text, or
    /// generation fails or is cancelled.
    public func card(for page: PageID, text: PageText) async -> String? {
        guard generator.availability.isAvailable else { return nil }
        let hash = Self.cacheKey(for: text)
        if let cached = cache[page], cached.hash == hash { return cached.card }
        if let running = inFlight[page], running.hash == hash { return await running.task.value }

        inFlight[page]?.task.cancel()
        let pipeline = self.pipeline
        let generator = self.generator
        let task = Task<String?, Never> {
            do { return try await Self.generate(text: text, pipeline: pipeline, generator: generator) }
            catch { return nil }
        }
        inFlight[page] = (hash, task)
        let result = await task.value
        // Only the request that still owns the slot records its result.
        if inFlight[page]?.hash == hash, !task.isCancelled {
            inFlight[page] = nil
            if let result { cache[page] = Cached(hash: hash, card: result) }
        }
        return task.isCancelled ? nil : result
    }

    /// The cached card for `page` if one exists for exactly this text. Never calls the model.
    public func cachedCard(for page: PageID, text: PageText) -> String? {
        guard let cached = cache[page], cached.hash == Self.cacheKey(for: text) else { return nil }
        return cached.card
    }

    /// Forgets the card for `page` (for example when it navigates or closes).
    public func invalidate(page: PageID) {
        cache[page] = nil
        inFlight.removeValue(forKey: page)?.task.cancel()
    }

    /// Forgets every card and cancels any generation in progress.
    public func invalidateAll() {
        cache.removeAll()
        for (_, running) in inFlight { running.task.cancel() }
        inFlight.removeAll()
    }

    // MARK: - Building the card

    nonisolated static func cacheKey(for text: PageText) -> UInt64 {
        let bucket = text.scrollFraction.map { String(Int((min(max($0, 0), 1) * 10).rounded())) } ?? "-"
        return TextUtil.stableHash([text.url.absoluteString, text.title, text.text, text.focusExcerpt ?? "", bucket])
    }

    /// A plain-words position, e.g. "about two thirds of the way down".
    public nonisolated static func positionPhrase(_ fraction: Double?) -> String? {
        guard let fraction, fraction.isFinite else { return nil }
        switch min(max(fraction, 0), 1) {
        case ..<0.08: return "near the top"
        case ..<0.2: return "a little way down"
        case ..<0.3: return "about a quarter of the way down"
        case ..<0.4: return "about a third of the way down"
        case ..<0.6: return "about halfway down"
        case ..<0.7: return "about two thirds of the way down"
        case ..<0.8: return "about three quarters of the way down"
        case ..<0.93: return "most of the way down"
        default: return "near the end"
        }
    }

    nonisolated static let instructions = """
        You write a one or two sentence note that reminds a reader where they left off on a web \
        page. Address the reader as "you", start with "You were reading", name the topic of the \
        part they were on, and mention how far down the page they were when given. Plain text \
        only, no quotes, no preamble.
        """

    nonisolated static func generate(text: PageText, pipeline: SummaryPipeline,
                                     generator: any TextGenerating) async throws -> String? {
        let body = text.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let focus = text.focusExcerpt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !body.isEmpty || !focus.isEmpty else { return nil }

        var header = "Page title: \(TextUtil.truncate(text.title, to: 200))\n"
        if let position = positionPhrase(text.scrollFraction) { header += "Position: \(position)\n" }
        let focusPart = focus.isEmpty ? "" : "Text where the reader stopped:\n\(TextUtil.truncate(focus, to: maxFocusCharacters))\n"
        let overhead = header.count + focusPart.count + 40
        let room = pipeline.sourceBudget(instructions: instructions, promptOverhead: overhead)
        // The whole page is background only; keep it short so the focus excerpt dominates.
        let contextLimit = min(room, 2000)
        let context = body.isEmpty ? "" : try await pipeline.condense(body, maxCharacters: contextLimit)

        var prompt = header
        if !context.isEmpty { prompt += "What the page is about:\n\(context)\n" }
        prompt += focusPart
        prompt += "\nWrite the note."

        let answer = try await generator.respond(prompt: prompt, instructions: instructions)
        let card = clean(answer)
        return card.isEmpty ? nil : card
    }

    /// Trims, strips wrapping quotes and keeps at most two sentences.
    nonisolated static func clean(_ answer: String) -> String {
        var s = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        let quotes: Set<Character> = ["\"", "“", "”", "'"]
        while let f = s.first, let l = s.last, s.count >= 2, quotes.contains(f), quotes.contains(l) {
            s = String(s.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        s = TextChunker.collapseSpaces(s)
        let sentences = TextChunker.sentences(of: s)
        if sentences.count > 2 { s = sentences.prefix(2).joined(separator: " ") }
        return TextUtil.truncate(s, to: maxCardCharacters)
    }
}
