import Foundation
import Observation
import PlinthModel

/// The one AI object the app shell uses: resume cards, ask, and semantic history, all behind the
/// master switch.
///
/// While the switch is off every call is a no-op: `resumeCard` returns nil, `ask` finishes at
/// once with `AIError.turnedOff`, `indexIfNeeded` does nothing and `semanticSearch` returns no
/// matches. Turning it off cancels work in progress. Removing pages from the index always works.
@MainActor
@Observable
public final class AIService {
    /// `.turnedOff` while the switch is off, otherwise the model's availability as of the last
    /// refresh (refreshed on every call and by `refreshAvailability()`).
    public private(set) var availability: AIAvailability
    public private(set) var isEnabled: Bool

    @ObservationIgnored public let generator: any TextGenerating
    @ObservationIgnored public let embedder: any TextEmbedding
    @ObservationIgnored public let resumeCards: ResumeCardService
    @ObservationIgnored public let askService: AskService
    @ObservationIgnored public let semanticIndex: SemanticIndex
    @ObservationIgnored private let settings: AISettings
    @ObservationIgnored private var inFlight: [UUID: Task<Void, Never>] = [:]

    public init(storageDirectory: URL, generator: any TextGenerating, embedder: any TextEmbedding) {
        self.generator = generator
        self.embedder = embedder
        self.settings = AISettings(storageDirectory: storageDirectory)
        self.resumeCards = ResumeCardService(generator: generator)
        self.askService = AskService(generator: generator)
        self.semanticIndex = SemanticIndex(storageDirectory: storageDirectory, embedder: embedder)
        let enabled = settings.isEnabled
        self.isEnabled = enabled
        self.availability = enabled ? generator.availability : .turnedOff
    }

    /// The production service (Foundation Models + NaturalLanguage). With the environment
    /// variable `PLINTH_AI=fake` it uses `FakeTextGenerator` (with the demo responder and a short
    /// per-word delay) and `FakeEmbedder` instead, so the UI works on a Mac without the model.
    public static func makeDefault(storageDirectory: URL) -> AIService {
        if ProcessInfo.processInfo.environment["PLINTH_AI"]?.lowercased() == "fake" {
            return AIService(storageDirectory: storageDirectory,
                             generator: FakeTextGenerator(wordDelay: .milliseconds(35), responder: FakeTextGenerator.demo),
                             embedder: FakeEmbedder())
        }
        return AIService(storageDirectory: storageDirectory,
                         generator: FoundationModelsGenerator(), embedder: NaturalLanguageEmbedder())
    }

    // MARK: - Switch

    /// Re-reads the model's availability (it can change, e.g. when the model finishes downloading).
    public func refreshAvailability() {
        let value = isEnabled ? generator.availability : .turnedOff
        if value != availability { availability = value }
    }

    /// Turns the AI features on or off and saves the choice. Turning off cancels in-flight work.
    public func setEnabled(_ enabled: Bool) {
        settings.setEnabled(enabled)
        isEnabled = enabled
        if !enabled {
            for (_, task) in inFlight { task.cancel() }
            inFlight.removeAll()
            resumeCards.invalidateAll()
        }
        refreshAvailability()
    }

    // MARK: - Resume cards

    /// A one or two sentence "where you left off" card, or nil when off, unavailable or failed.
    public func resumeCard(for page: PageID, text: PageText) async -> String? {
        refreshAvailability()
        guard availability.isAvailable else { return nil }
        let card = await resumeCards.card(for: page, text: text)
        return isEnabled ? card : nil
    }

    /// Forgets the cached card for a page (call when it navigates or closes).
    public func invalidateResumeCard(page: PageID) {
        resumeCards.invalidate(page: page)
    }

    // MARK: - Ask

    /// Streams the cumulative answer. Finishes with an `AIError` (user-readable description) when
    /// the switch is off or the model is unavailable, and with `AIError.turnedOff` if the switch
    /// is turned off mid-answer.
    public func ask(_ question: String, pages: [PageText], scope: AskScope) -> AsyncThrowingStream<String, Error> {
        refreshAvailability()
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        switch availability {
        case .turnedOff:
            continuation.finish(throwing: AIError.turnedOff)
            return stream
        case .unavailable(let reason):
            continuation.finish(throwing: AIError.unavailable(reason: reason))
            return stream
        case .available:
            break
        }
        let inner = askService.ask(question, pages: pages, scope: scope)
        let id = UUID()
        let task = Task { [weak self] in
            do {
                for try await partial in inner { continuation.yield(partial) }
                if self?.isEnabled == false { continuation.finish(throwing: AIError.turnedOff) }
                else { continuation.finish() }
            } catch {
                continuation.finish(throwing: self?.isEnabled == false ? AIError.turnedOff : error)
            }
            self?.inFlight[id] = nil
        }
        inFlight[id] = task
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    // MARK: - Semantic history

    /// Adds the visit to the semantic index when the switch is on, the embedder works, and the
    /// visit qualifies (`SemanticIndex.shouldIndex`: 30 s dwell, http/https).
    public func indexIfNeeded(entry: HistoryEntry, text: PageText) async {
        guard isEnabled, embedder.isAvailable, SemanticIndex.shouldIndex(entry) else { return }
        let index = semanticIndex
        let id = UUID()
        let task = Task { _ = await index.add(entry: entry, text: text.text) }
        inFlight[id] = task
        await task.value
        inFlight[id] = nil
    }

    /// Past pages by meaning, best first. Empty when off or the embedder is unavailable.
    public func semanticSearch(_ query: String, limit: Int) async -> [SemanticMatch] {
        guard isEnabled, embedder.isAvailable else { return [] }
        let matches = await semanticIndex.search(query, limit: limit)
        return isEnabled ? matches : []
    }

    /// Removes a page from the semantic index (works even while the switch is off).
    public func removeFromSemanticIndex(url: URL) async {
        await semanticIndex.remove(url: url)
    }

    /// Empties the semantic index (works even while the switch is off).
    public func clearSemanticIndex() async {
        await semanticIndex.removeAll()
    }

    /// Writes any pending index changes (call on quit).
    public func flush() async {
        await semanticIndex.flush()
    }
}
