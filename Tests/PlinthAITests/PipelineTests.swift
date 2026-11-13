import Foundation
import Testing
import PlinthModel
@testable import PlinthAI

/// A long article: `paragraphs` paragraphs of numbered sentences.
func longText(paragraphs: Int, sentencesEach: Int = 8) -> String {
    (0..<paragraphs).map { p in
        (0..<sentencesEach).map { s in "Paragraph \(p) sentence \(s) talks about topic number \(p * 10 + s) in some detail." }
            .joined(separator: " ")
    }.joined(separator: "\n\n")
}

/// Asserts that every request fits the generator's budget minus the pipeline's answer reserve.
func expectWithinBudget(_ fake: FakeTextGenerator, reserve: Int, sourceLocation: SourceLocation = #_sourceLocation) {
    let limit = fake.contextCharacterBudget - reserve
    for request in fake.requests {
        #expect(request.size <= limit, "request of \(request.size) > \(limit)", sourceLocation: sourceLocation)
    }
}

@Suite struct PipelineTests {
    @Test func shortTextIsReturnedWithoutCallingTheModel() async throws {
        let fake = FakeTextGenerator(contextCharacterBudget: 2000)
        let pipeline = SummaryPipeline(generator: fake)
        let out = try await pipeline.condense("  Just a little text.  ", maxCharacters: 500)
        #expect(out == "Just a little text.")
        #expect(fake.requests.isEmpty)
    }

    @Test func textThatFitsOneRequestIsReducedOnce() async throws {
        let fake = FakeTextGenerator(contextCharacterBudget: 3000, responder: { _, _ in "A short summary." })
        let pipeline = SummaryPipeline(generator: fake)
        let out = try await pipeline.condense(longText(paragraphs: 2), maxCharacters: 200)
        #expect(out == "A short summary.")
        #expect(fake.requests.count == 1)
        #expect(fake.prompts[0].hasPrefix("Combine these notes"))
        expectWithinBudget(fake, reserve: pipeline.answerReserve)
    }

    @Test func longTextIsMappedAndReducedWithinBudget() async throws {
        // A model that rambles: echoes the whole prompt back. The pipeline must still bound notes.
        let fake = FakeTextGenerator(contextCharacterBudget: 1500, responder: { prompt, _ in prompt })
        let pipeline = SummaryPipeline(generator: fake)
        let text = longText(paragraphs: 40)
        #expect(text.count > 20_000)
        let out = try await pipeline.condense(text, maxCharacters: 400)
        #expect(out.count <= 400)
        #expect(fake.requests.count > 10)
        expectWithinBudget(fake, reserve: pipeline.answerReserve)
    }

    @Test func notesAreBoundedSoTheReduceRecursesAndConverges() async throws {
        let fake = FakeTextGenerator(contextCharacterBudget: 1200, responder: { prompt, _ in
            // Notes as long as the first 300 characters of the chunk.
            String(prompt.components(separatedBy: "Text:\n").last!.prefix(300))
        })
        let pipeline = SummaryPipeline(generator: fake)
        let out = try await pipeline.condense(longText(paragraphs: 60), maxCharacters: 300)
        #expect(out.count <= 300)
        let reducePrompts = fake.prompts.filter { $0.hasPrefix("Combine these notes") }
        #expect(reducePrompts.count <= 1)
        expectWithinBudget(fake, reserve: pipeline.answerReserve)
    }

    @Test func focusIsCarriedIntoEveryMapPrompt() async throws {
        let fake = FakeTextGenerator(contextCharacterBudget: 1500, responder: { _, _ in "note" })
        let pipeline = SummaryPipeline(generator: fake)
        _ = try await pipeline.condense(longText(paragraphs: 10), focus: "What is topic 42?", maxCharacters: 300)
        let mapPrompts = fake.prompts.filter { $0.hasPrefix("Write notes") }
        #expect(!mapPrompts.isEmpty)
        #expect(mapPrompts.allSatisfy { $0.contains("What is topic 42?") })
        expectWithinBudget(fake, reserve: pipeline.answerReserve)
    }

    @Test func longFocusIsTruncatedSoPromptsStillFit() async throws {
        let fake = FakeTextGenerator(contextCharacterBudget: 1500, responder: { _, _ in "note" })
        let pipeline = SummaryPipeline(generator: fake)
        let focus = String(repeating: "why ", count: 1000)
        _ = try await pipeline.condense(longText(paragraphs: 10), focus: focus, maxCharacters: 300)
        expectWithinBudget(fake, reserve: pipeline.answerReserve)
    }

    @Test func nothingRelevantNotesAreDropped() async throws {
        let fake = FakeTextGenerator(contextCharacterBudget: 1500, responder: { _, _ in "Nothing relevant." })
        let pipeline = SummaryPipeline(generator: fake)
        let out = try await pipeline.condense(longText(paragraphs: 10), focus: "unrelated", maxCharacters: 300)
        #expect(out.isEmpty)
    }

    @Test func generatorErrorsPropagate() async {
        struct Boom: Error {}
        let fake = FakeTextGenerator(contextCharacterBudget: 1500)
        fake.failure = Boom()
        let pipeline = SummaryPipeline(generator: fake)
        await #expect(throws: Boom.self) {
            _ = try await pipeline.condense(longText(paragraphs: 10), maxCharacters: 300)
        }
    }
}
