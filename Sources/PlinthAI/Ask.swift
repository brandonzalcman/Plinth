import Foundation
import PlinthModel

/// Errors the AI features report. Descriptions are written to be shown to the user as-is.
public enum AIError: Error, LocalizedError, Sendable, Equatable {
    case turnedOff
    case unavailable(reason: String)
    case emptyQuestion
    case noPageText

    public var errorDescription: String? {
        switch self {
        case .turnedOff: "On-device AI is turned off. You can turn it on in Settings."
        case .unavailable(let reason): reason
        case .emptyQuestion: "Type a question to ask."
        case .noPageText: "There is no readable text on this page to ask about."
        }
    }
}

/// Answers questions about one page, every open page of a site, or the two pages of a split.
///
/// Long pages are first condensed (through `SummaryPipeline`) to the parts relevant to the
/// question, so the final request fits the model's context. The answer is streamed cumulatively.
public struct AskService: Sendable {
    public let generator: any TextGenerating
    private let pipeline: SummaryPipeline

    /// Longest question sent to the model.
    public static let maxQuestionCharacters = 500

    public init(generator: any TextGenerating) {
        self.generator = generator
        self.pipeline = SummaryPipeline(generator: generator)
    }

    /// Streams the whole answer so far, ending when the model finishes. Throws `AIError` when the
    /// model is unavailable, the question is empty, or no page has text. Cancelling the consumer
    /// cancels the work.
    public func ask(_ question: String, pages: [PageText], scope: AskScope) -> AsyncThrowingStream<String, Error> {
        let generator = self.generator
        let pipeline = self.pipeline
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if case .unavailable(let reason) = generator.availability { throw AIError.unavailable(reason: reason) }
                    if generator.availability == .turnedOff { throw AIError.turnedOff }
                    let request = try await Self.buildRequest(question: question, pages: pages, scope: scope, pipeline: pipeline)
                    for try await partial in generator.stream(prompt: request.prompt, instructions: request.instructions) {
                        try Task.checkCancellation()
                        continuation.yield(partial.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Prompt building

    struct Request: Sendable, Equatable { var prompt: String; var instructions: String }

    /// The pages actually used for a scope: `.page` uses the first, `.split` the first two.
    static func effectivePages(_ pages: [PageText], scope: AskScope) -> [PageText] {
        let withText = pages.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        switch scope {
        case .page: return Array(withText.prefix(1))
        case .split: return Array(withText.prefix(2))
        case .site: return withText
        }
    }

    static func instructions(scope: AskScope, pageCount: Int) -> String {
        let base = """
            You answer questions about web pages the user has open, using only the page text given. \
            Be concise: a few plain sentences, no markdown, no headings. If the pages do not say, \
            answer that the page does not say.
            """
        switch (scope, pageCount) {
        case (.split, 2):
            return base + " The user is comparing two pages side by side: compare them directly and point out where they agree and differ."
        case (_, 2...):
            return base + " Several pages are given: name which page (by its title) says what."
        default:
            return base
        }
    }

    static func header(question: String) -> String { "Question: \(question)\n\n" }
    static let footer = "\nAnswer the question."

    static func pageLabel(_ page: PageText, index: Int, count: Int) -> String {
        let title = TextUtil.truncate(page.title.isEmpty ? (page.url.host() ?? page.url.absoluteString) : page.title, to: 150)
        return count > 1 ? "Page \(index + 1): \(title)\n" : "Page: \(title)\n"
    }

    static func buildRequest(question rawQuestion: String, pages rawPages: [PageText], scope: AskScope,
                             pipeline: SummaryPipeline) async throws -> Request {
        let question = TextUtil.truncate(TextChunker.collapseSpaces(rawQuestion), to: maxQuestionCharacters)
        guard !question.isEmpty else { throw AIError.emptyQuestion }
        let pages = effectivePages(rawPages, scope: scope)
        guard !pages.isEmpty else { throw AIError.noPageText }

        let instructions = instructions(scope: scope, pageCount: pages.count)
        let labels = pages.enumerated().map { pageLabel($1, index: $0, count: pages.count) }
        let overhead = header(question: question).count + footer.count + labels.reduce(0) { $0 + $1.count + 2 }
        let room = pipeline.sourceBudget(instructions: instructions, promptOverhead: overhead)
        let perPage = max(100, room / pages.count)

        var prompt = header(question: question)
        for (i, page) in pages.enumerated() {
            try Task.checkCancellation()
            let body = page.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let fitted = body.count <= perPage ? body
                : try await pipeline.condense(body, focus: question, maxCharacters: perPage)
            prompt += labels[i] + (fitted.isEmpty ? SummaryPipeline.nothingRelevant : fitted) + "\n\n"
        }
        prompt += footer
        return Request(prompt: prompt, instructions: instructions)
    }
}
