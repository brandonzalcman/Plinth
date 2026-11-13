import Foundation
import Testing
import PlinthModel
@testable import PlinthAI

func page(_ url: String = "https://example.com/article", title: String = "Rust ownership", text: String,
          focus: String? = nil, scroll: Double? = nil) -> PageText {
    PageText(url: URL(string: url)!, title: title, text: text, focusExcerpt: focus, scrollFraction: scroll,
             extractedAt: Date(timeIntervalSince1970: 1_000_000))
}

@MainActor
@Suite struct ResumeCardTests {
    @Test func positionPhrases() {
        #expect(ResumeCardService.positionPhrase(nil) == nil)
        #expect(ResumeCardService.positionPhrase(0) == "near the top")
        #expect(ResumeCardService.positionPhrase(0.5) == "about halfway down")
        #expect(ResumeCardService.positionPhrase(0.66) == "about two thirds of the way down")
        #expect(ResumeCardService.positionPhrase(1.4) == "near the end")
        #expect(ResumeCardService.positionPhrase(.nan) == nil)
    }

    @Test func promptUsesTitleFocusAndPosition() async {
        let fake = FakeTextGenerator(cannedAnswer: "You were reading the section on borrowing, about two thirds down.")
        let service = ResumeCardService(generator: fake)
        let card = await service.card(for: PageID(), text: page(text: "Ownership intro.", focus: "Borrowing rules: one mutable reference.", scroll: 0.66))
        #expect(card == "You were reading the section on borrowing, about two thirds down.")
        let prompt = fake.prompts.last!
        #expect(prompt.contains("Rust ownership"))
        #expect(prompt.contains("Borrowing rules"))
        #expect(prompt.contains("about two thirds of the way down"))
    }

    @Test func cachesPerPageAndTextAndInvalidates() async {
        let fake = FakeTextGenerator(cannedAnswer: "You were reading it.")
        let service = ResumeCardService(generator: fake)
        let id = PageID()
        let text = page(text: "Body", scroll: 0.3)
        _ = await service.card(for: id, text: text)
        _ = await service.card(for: id, text: text)
        #expect(fake.requests.count == 1)
        #expect(service.cachedCard(for: id, text: text) == "You were reading it.")

        // Tiny scroll change within the same tenth: still cached. Different text: regenerated.
        _ = await service.card(for: id, text: page(text: "Body", scroll: 0.31))
        #expect(fake.requests.count == 1)
        _ = await service.card(for: id, text: page(text: "Body changed", scroll: 0.3))
        #expect(fake.requests.count == 2)

        service.invalidate(page: id)
        _ = await service.card(for: id, text: page(text: "Body changed", scroll: 0.3))
        #expect(fake.requests.count == 3)
    }

    @Test func concurrentRequestsShareOneGeneration() async {
        let fake = FakeTextGenerator(cannedAnswer: "You were reading the middle part of it.", wordDelay: .milliseconds(5))
        let service = ResumeCardService(generator: fake)
        let id = PageID()
        let text = page(text: "Body")
        async let a = service.card(for: id, text: text)
        async let b = service.card(for: id, text: text)
        let (x, y) = await (a, b)
        #expect(x == y)
        #expect(fake.requests.count == 1)
    }

    @Test func nilWhenUnavailableEmptyOrFailing() async {
        let fake = FakeTextGenerator(availability: .unavailable(reason: "no"), responder: { _, _ in "x" })
        let service = ResumeCardService(generator: fake)
        #expect(await service.card(for: PageID(), text: page(text: "Body")) == nil)
        fake.availability = .available
        #expect(await service.card(for: PageID(), text: page(text: "  ")) == nil)
        struct Boom: Error {}
        fake.failure = Boom()
        #expect(await service.card(for: PageID(), text: page(text: "Body")) == nil)
        #expect(fake.requests.count == 1)
    }

    @Test func longPagesAreCondensedWithinBudget() async {
        let fake = FakeTextGenerator(contextCharacterBudget: 2000, responder: { _, _ in "A note about the page." })
        let service = ResumeCardService(generator: fake)
        let card = await service.card(for: PageID(), text: page(text: longText(paragraphs: 50), focus: String(repeating: "focus ", count: 400), scroll: 0.9))
        #expect(card != nil)
        #expect(fake.requests.count > 1)
        expectWithinBudget(fake, reserve: SummaryPipeline(generator: fake).answerReserve)
    }

    @Test func cleanKeepsTwoSentencesAndStripsQuotes() {
        #expect(ResumeCardService.clean("  \"You were reading A. Then B. Then C.\" ") == "You were reading A. Then B.")
        #expect(ResumeCardService.clean(String(repeating: "word ", count: 200)).count <= ResumeCardService.maxCardCharacters)
    }
}

@Suite struct AskTests {
    func collect(_ stream: AsyncThrowingStream<String, Error>) async throws -> [String] {
        var out: [String] = []
        for try await s in stream { out.append(s) }
        return out
    }

    @Test func streamsCumulativeAnswer() async throws {
        let fake = FakeTextGenerator(cannedAnswer: "It costs ten dollars.")
        let parts = try await collect(AskService(generator: fake).ask("How much?", pages: [page(text: "Price: $10.")], scope: .page))
        #expect(parts == ["It", "It costs", "It costs ten", "It costs ten dollars."])
        #expect(fake.prompts.last!.contains("Question: How much?"))
        #expect(fake.prompts.last!.contains("Price: $10."))
    }

    @Test func splitScopeComparesTwoPages() async throws {
        let fake = FakeTextGenerator(cannedAnswer: "A is cheaper.")
        let pages = [page("https://a.com", title: "Laptop A", text: "A costs $900."),
                     page("https://b.com", title: "Laptop B", text: "B costs $1200."),
                     page("https://c.com", title: "Ignored", text: "C")]
        _ = try await collect(AskService(generator: fake).ask("Which is cheaper?", pages: pages, scope: .split))
        let request = fake.requests.last!
        #expect(request.instructions.contains("compare"))
        #expect(request.prompt.contains("Page 1: Laptop A"))
        #expect(request.prompt.contains("Page 2: Laptop B"))
        #expect(!request.prompt.contains("Ignored"))
    }

    @Test func siteScopeNamesPages() async throws {
        let fake = FakeTextGenerator(cannedAnswer: "ok")
        let pages = (1...3).map { page("https://docs.x.com/\($0)", title: "Doc \($0)", text: "Text \($0)") }
        _ = try await collect(AskService(generator: fake).ask("Where is setup?", pages: pages, scope: .site))
        let request = fake.requests.last!
        #expect(request.instructions.contains("which page"))
        #expect(request.prompt.contains("Page 3: Doc 3"))
    }

    @Test func pageScopeUsesOnlyFirstPage() async throws {
        let fake = FakeTextGenerator(cannedAnswer: "ok")
        _ = try await collect(AskService(generator: fake).ask("Q", pages: [page(text: "first"), page(text: "second")], scope: .page))
        #expect(fake.prompts.last!.contains("first"))
        #expect(!fake.prompts.last!.contains("second"))
    }

    @Test func longPagesAreCondensedTowardTheQuestionWithinBudget() async throws {
        let fake = FakeTextGenerator(contextCharacterBudget: 2500, responder: { prompt, _ in String(prompt.suffix(500)) })
        let pages = [page("https://a.com", title: "A", text: longText(paragraphs: 30)),
                     page("https://b.com", title: "B", text: longText(paragraphs: 30))]
        let parts = try await collect(AskService(generator: fake).ask("What is topic 42?", pages: pages, scope: .split))
        #expect(!parts.isEmpty)
        let mapPrompts = fake.prompts.filter { $0.hasPrefix("Write notes") }
        #expect(!mapPrompts.isEmpty)
        #expect(mapPrompts.allSatisfy { $0.contains("What is topic 42?") })
        expectWithinBudget(fake, reserve: SummaryPipeline(generator: fake).answerReserve)
        // The final request holds both pages.
        #expect(fake.prompts.last!.contains("Page 1: A") && fake.prompts.last!.contains("Page 2: B"))
    }

    @Test func readableErrors() async {
        let unavailable = FakeTextGenerator(availability: .unavailable(reason: "Turn on Apple Intelligence."))
        do {
            _ = try await collect(AskService(generator: unavailable).ask("Q", pages: [page(text: "t")], scope: .page))
            Issue.record("expected an error")
        } catch {
            #expect(error.localizedDescription == "Turn on Apple Intelligence.")
        }
        let fake = FakeTextGenerator()
        await #expect(throws: AIError.emptyQuestion) {
            _ = try await collect(AskService(generator: fake).ask("   ", pages: [page(text: "t")], scope: .page))
        }
        await #expect(throws: AIError.noPageText) {
            _ = try await collect(AskService(generator: fake).ask("Q", pages: [page(text: " ")], scope: .page))
        }
        #expect(fake.requests.isEmpty)
    }

    @Test func cancellingTheConsumerStopsTheStream() async throws {
        let fake = FakeTextGenerator(cannedAnswer: String(repeating: "word ", count: 200), wordDelay: .milliseconds(2))
        let stream = AskService(generator: fake).ask("Q", pages: [page(text: "t")], scope: .page)
        var count = 0
        for try await _ in stream { count += 1; if count == 3 { break } }
        #expect(count == 3)
    }
}
