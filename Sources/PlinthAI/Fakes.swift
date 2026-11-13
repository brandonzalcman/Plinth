import Foundation
import PlinthModel
import Synchronization

/// A deterministic stand-in for the on-device model, for tests and for exercising the UI on a
/// Mac without Apple Intelligence (`PLINTH_AI=fake`).
///
/// It streams the words of its answer cumulatively, with `wordDelay` between words (zero for
/// tests). The answer comes from `responder`, which by default echoes the start of the prompt's
/// last paragraph. Every request is recorded in `requests`.
public final class FakeTextGenerator: TextGenerating {
    public struct Request: Sendable, Equatable {
        public var prompt: String
        public var instructions: String
        /// Characters the request occupies: instructions plus prompt.
        public var size: Int { prompt.count + instructions.count }
    }

    public typealias Responder = @Sendable (_ prompt: String, _ instructions: String) -> String

    private struct State {
        var availability: AIAvailability
        var budget: Int
        var wordDelay: Duration
        var responder: Responder
        var failure: (any Error & Sendable)?
        var requests: [Request] = []
    }

    private let state: Mutex<State>

    public init(availability: AIAvailability = .available, contextCharacterBudget: Int = 9000,
                wordDelay: Duration = .zero, responder: Responder? = nil) {
        state = Mutex(State(availability: availability, budget: contextCharacterBudget, wordDelay: wordDelay,
                            responder: responder ?? FakeTextGenerator.echo))
    }

    /// A generator that always answers `answer`.
    public convenience init(cannedAnswer answer: String, wordDelay: Duration = .zero) {
        self.init(wordDelay: wordDelay, responder: { _, _ in answer })
    }

    public var availability: AIAvailability {
        get { state.withLock { $0.availability } }
        set { state.withLock { $0.availability = newValue } }
    }

    public var contextCharacterBudget: Int {
        get { state.withLock { $0.budget } }
        set { state.withLock { $0.budget = newValue } }
    }

    public var wordDelay: Duration {
        get { state.withLock { $0.wordDelay } }
        set { state.withLock { $0.wordDelay = newValue } }
    }

    public var responder: Responder {
        get { state.withLock { $0.responder } }
        set { state.withLock { $0.responder = newValue } }
    }

    /// When set, every stream throws this after recording the request.
    public var failure: (any Error & Sendable)? {
        get { state.withLock { $0.failure } }
        set { state.withLock { $0.failure = newValue } }
    }

    /// Every request so far, in order.
    public var requests: [Request] { state.withLock { $0.requests } }
    public var prompts: [String] { requests.map(\.prompt) }
    public func resetRequests() { state.withLock { $0.requests.removeAll() } }

    public func stream(prompt: String, instructions: String) -> AsyncThrowingStream<String, Error> {
        let (answer, delay, failure) = state.withLock { s -> (String, Duration, (any Error & Sendable)?) in
            s.requests.append(Request(prompt: prompt, instructions: instructions))
            return (s.responder(prompt, instructions), s.wordDelay, s.failure)
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                if let failure { continuation.finish(throwing: failure); return }
                var soFar = ""
                for word in answer.split(separator: " ", omittingEmptySubsequences: false) {
                    if Task.isCancelled { continuation.finish(throwing: CancellationError()); return }
                    if delay > .zero { try? await Task.sleep(for: delay) }
                    soFar += soFar.isEmpty ? String(word) : " " + word
                    continuation.yield(soFar)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Default responder: "(fake) " plus the first dozen words of the prompt's last paragraph.
    public static let echo: Responder = { prompt, _ in
        let last = prompt.components(separatedBy: "\n\n").last(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ?? prompt
        let words = last.split(whereSeparator: \.isWhitespace).prefix(12)
        return "(fake) " + words.joined(separator: " ")
    }

    /// A responder that gives plausible-looking output for each kind of request, for demos:
    /// resume cards name the title and position, notes repeat the first sentence of the text,
    /// answers restate the question.
    public static let demo: Responder = { prompt, instructions in
        func field(_ name: String) -> String? {
            prompt.components(separatedBy: "\n").first { $0.hasPrefix(name) }
                .map { String($0.dropFirst(name.count)).trimmingCharacters(in: .whitespaces) }
        }
        if instructions.contains("where they left off") {
            let title = field("Page title:") ?? "this page"
            if let position = field("Position:") { return "You were reading \(title), \(position)." }
            return "You were reading \(title)."
        }
        if let question = field("Question:") {
            return "This is a sample answer from the fake model to: \(question)"
        }
        let body = prompt.components(separatedBy: "\n\n").last ?? prompt
        return TextChunker.sentences(of: TextChunker.collapseSpaces(body)).first ?? ""
    }
}

/// Deterministic hashed bag-of-words embeddings: texts that share words are close, texts with no
/// words in common score about zero. Case and punctuation are ignored.
public struct FakeEmbedder: TextEmbedding {
    public var isAvailable: Bool
    public var dimension: Int

    public init(isAvailable: Bool = true, dimension: Int = 256) {
        self.isAvailable = isAvailable
        self.dimension = max(8, dimension)
    }

    public func embed(_ text: String) async -> [Float]? {
        guard isAvailable else { return nil }
        let words = text.lowercased().split { !$0.isLetter && !$0.isNumber }.filter { $0.count > 2 }
        guard !words.isEmpty else { return nil }
        var vector = [Float](repeating: 0, count: dimension)
        for word in words {
            let h = TextUtil.stableHash([String(word)])
            vector[Int(h % UInt64(dimension))] += 1
        }
        return vector
    }
}
