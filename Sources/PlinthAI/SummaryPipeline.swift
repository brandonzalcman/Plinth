import Foundation
import PlinthModel

/// Chunk-and-summarise for a small-context model.
///
/// Apple's on-device model takes about 4096 tokens per request, so a long page cannot be sent in
/// one go. `condense` maps the text to bounded notes chunk by chunk, then reduces the notes,
/// recursing until the result fits the requested size. Every request it sends (instructions plus
/// prompt) stays within the generator's `contextCharacterBudget` minus `answerReserve`.
public struct SummaryPipeline: Sendable {
    public let generator: any TextGenerating
    /// Characters of the budget kept free for the model's answer.
    public var answerReserve: Int
    /// Longest focus (question) carried into a prompt; longer focus text is truncated.
    public static let maxFocusCharacters = 400
    /// Recursion limit for the reduce step; after it, the notes are truncated.
    public static let maxRounds = 6

    public init(generator: any TextGenerating, answerReserve: Int? = nil) {
        self.generator = generator
        self.answerReserve = answerReserve ?? max(200, generator.contextCharacterBudget / 6)
    }

    /// Characters available for source text in one request, given the fixed parts of it.
    public func sourceBudget(instructions: String, promptOverhead: Int) -> Int {
        max(200, generator.contextCharacterBudget - answerReserve - instructions.count - promptOverhead)
    }

    /// Shrinks `text` to at most `maxCharacters`. Text that already fits is returned unchanged
    /// (trimmed) without calling the model. With a `focus` (for example a question), the notes
    /// keep only what bears on it.
    public func condense(_ text: String, focus: String? = nil, maxCharacters: Int) async throws -> String {
        let target = max(50, maxCharacters)
        let focus = focus.map { TextUtil.truncate($0, to: Self.maxFocusCharacters) }
        var current = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var round = 0
        while current.count > target {
            try Task.checkCancellation()
            if round >= Self.maxRounds { return TextUtil.truncate(current, to: target) }
            round += 1

            let budget = sourceBudget(instructions: Self.mapInstructions, promptOverhead: Self.mapOverhead(focus: focus))
            if current.count <= budget {
                // Fits in one request: one reduce call to the final size.
                let reduced = try await reduce(current, focus: focus, maxCharacters: target)
                return TextUtil.truncate(reduced, to: target)
            }
            let chunks = TextChunker(maxCharacters: budget, overlap: min(200, budget / 10)).chunks(current)
            // Each note is bounded so the joined notes shrink every round (at most a third of a chunk).
            let noteLimit = max(120, min(budget / 3, max(target / max(1, chunks.count), target / 4)))
            var notes: [String] = []
            for chunk in chunks {
                try Task.checkCancellation()
                let prompt = Self.mapPrompt(chunk: chunk, focus: focus, noteLimit: noteLimit)
                let note = try await generator.respond(prompt: prompt, instructions: Self.mapInstructions)
                let bounded = TextUtil.truncate(note, to: noteLimit)
                if !bounded.isEmpty, !Self.isNothingRelevant(bounded) { notes.append(bounded) }
            }
            let joined = notes.joined(separator: "\n")
            if joined.count >= current.count { return TextUtil.truncate(joined, to: target) }
            current = joined
        }
        return current
    }

    // MARK: - Prompts

    static let mapInstructions = """
        You take short, factual notes on part of a web page. Write plain sentences, no headings, \
        no bullet symbols, no preamble. Keep names, numbers and specific claims.
        """

    static let nothingRelevant = "Nothing relevant."

    static func mapPrompt(chunk: String, focus: String?, noteLimit: Int) -> String {
        mapHeader(focus: focus, noteLimit: noteLimit) + chunk
    }

    static func mapHeader(focus: String?, noteLimit: Int) -> String {
        var header = "Write notes on this text in at most \(noteLimit) characters."
        if let focus, !focus.isEmpty {
            header += " Keep only what helps answer this question: \(focus) If nothing helps, reply \"\(nothingRelevant)\""
        }
        return header + "\n\nText:\n"
    }

    /// Generous upper bound on the header length (the note limit has at most 6 digits).
    static func mapOverhead(focus: String?) -> Int {
        max(mapHeader(focus: focus, noteLimit: 999_999).count,
            reduceHeader(focus: focus, maxCharacters: 999_999).count)
    }

    static func reduceHeader(focus: String?, maxCharacters: Int) -> String {
        var header = "Combine these notes into one summary of at most \(maxCharacters) characters. Remove repetition."
        if let focus, !focus.isEmpty { header += " Keep what helps answer: \(focus)" }
        return header + "\n\nNotes:\n"
    }

    static func isNothingRelevant(_ note: String) -> Bool {
        note.lowercased().hasPrefix(nothingRelevant.lowercased().dropLast())
    }

    private func reduce(_ text: String, focus: String?, maxCharacters: Int) async throws -> String {
        let prompt = Self.reduceHeader(focus: focus, maxCharacters: maxCharacters) + text
        return try await generator.respond(prompt: prompt, instructions: Self.mapInstructions)
    }
}
