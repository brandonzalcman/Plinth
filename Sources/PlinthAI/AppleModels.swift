import Foundation
import FoundationModels
import NaturalLanguage
import PlinthModel
import Synchronization

/// `TextGenerating` backed by Apple's on-device model (Foundation Models).
/// Each request uses a fresh `LanguageModelSession`, so requests never share context.
public struct FoundationModelsGenerator: TextGenerating {
    /// The on-device model takes about 4096 tokens (instructions, prompt and answer together).
    /// At a conservative ~3 characters per token, 9000 characters of input leaves room for the answer.
    public var contextCharacterBudget: Int

    public init(contextCharacterBudget: Int = 9000) {
        self.contextCharacterBudget = contextCharacterBudget
    }

    public var availability: AIAvailability {
        Self.map(SystemLanguageModel.default.availability)
    }

    static func map(_ availability: SystemLanguageModel.Availability) -> AIAvailability {
        switch availability {
        case .available:
            return .available
        case .unavailable(.deviceNotEligible):
            return .unavailable(reason: "This Mac can’t run Apple Intelligence, which the on-device AI features need.")
        case .unavailable(.appleIntelligenceNotEnabled):
            return .unavailable(reason: "Turn on Apple Intelligence in System Settings to use the on-device AI features.")
        case .unavailable(.modelNotReady):
            return .unavailable(reason: "The on-device model is still downloading or getting ready. Try again in a little while.")
        case .unavailable:
            return .unavailable(reason: "The on-device model isn’t available right now.")
        }
    }

    public func stream(prompt: String, instructions: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let session = LanguageModelSession(instructions: instructions)
                    for try await snapshot in session.streamResponse(to: prompt) {
                        try Task.checkCancellation()
                        continuation.yield(snapshot.content)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// `TextEmbedding` backed by NaturalLanguage sentence embeddings. The language is detected per
/// text with `NLLanguageRecognizer`, falling back to English when detection is unsure or that
/// language has no sentence embedding. Loaded embeddings are cached.
public final class NaturalLanguageEmbedder: TextEmbedding {
    /// Detection below this confidence uses English (short queries are often misdetected).
    public static let minimumLanguageConfidence = 0.6

    private let cache = Mutex<[String: NLEmbedding?]>([:])

    public init() {}

    public var isAvailable: Bool { embedding(for: .english) != nil }

    public func embed(_ text: String) async -> [Float]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let language = Self.language(of: trimmed)
        return cache.withLock { cache -> [Float]? in
            let model = Self.load(language, cache: &cache) ?? Self.load(.english, cache: &cache)
            return model?.vector(for: trimmed)?.map(Float.init)
        }
    }

    static func language(of text: String) -> NLLanguage {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(1000)))
        guard let best = recognizer.languageHypotheses(withMaximum: 1).first,
              best.value >= minimumLanguageConfidence else { return .english }
        return best.key
    }

    private func embedding(for language: NLLanguage) -> NLEmbedding? {
        cache.withLock { Self.load(language, cache: &$0) }
    }

    private static func load(_ language: NLLanguage, cache: inout [String: NLEmbedding?]) -> NLEmbedding? {
        if let hit = cache[language.rawValue] { return hit }
        let model = NLEmbedding.sentenceEmbedding(for: language)
        cache[language.rawValue] = .some(model)
        return model
    }
}
