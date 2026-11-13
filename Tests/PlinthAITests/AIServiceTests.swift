import Foundation
import Testing
import PlinthModel
@testable import PlinthAI

@MainActor
@Suite struct AIServiceTests {
    @Test func settingsDefaultOnAndPersist() {
        let dir = tempDirectory()
        let settings = AISettings(storageDirectory: dir)
        #expect(settings.isEnabled)
        settings.setEnabled(false)
        #expect(!AISettings(storageDirectory: dir).isEnabled)
        AISettings(storageDirectory: dir).setEnabled(true)
        #expect(AISettings(storageDirectory: dir).isEnabled)
    }

    @Test func availabilityFollowsSwitchAndModel() {
        let dir = tempDirectory()
        let fake = FakeTextGenerator(availability: .unavailable(reason: "Not ready"))
        let service = AIService(storageDirectory: dir, generator: fake, embedder: FakeEmbedder())
        #expect(service.availability == .unavailable(reason: "Not ready"))
        fake.availability = .available
        service.refreshAvailability()
        #expect(service.availability == .available)
        service.setEnabled(false)
        #expect(service.availability == .turnedOff)
        #expect(!service.isEnabled)
        // Persisted across launches.
        let again = AIService(storageDirectory: dir, generator: fake, embedder: FakeEmbedder())
        #expect(again.availability == .turnedOff)
        again.setEnabled(true)
        #expect(again.availability == .available)
    }

    @Test func everythingIsANoOpWhenOff() async {
        let fake = FakeTextGenerator(cannedAnswer: "answer")
        let service = AIService(storageDirectory: tempDirectory(), generator: fake, embedder: FakeEmbedder())
        let entry = visit("https://cooking.com/pasta", title: "Pasta recipe")
        await service.indexIfNeeded(entry: entry, text: page(text: "fresh pasta"))
        #expect(await service.semanticSearch("pasta", limit: 5).count == 1)

        service.setEnabled(false)
        #expect(await service.resumeCard(for: PageID(), text: page(text: "Body")) == nil)
        #expect(await service.semanticSearch("pasta", limit: 5).isEmpty)
        await service.indexIfNeeded(entry: visit("https://other.com/x", title: "Other pasta"), text: page(text: "pasta"))
        #expect(await service.semanticIndex.count == 1)
        do {
            for try await _ in service.ask("Q", pages: [page(text: "t")], scope: .page) {}
            Issue.record("expected turnedOff")
        } catch {
            #expect(error as? AIError == .turnedOff)
            #expect(error.localizedDescription.contains("turned off"))
        }
        #expect(fake.requests.isEmpty)

        // Removal still works while off.
        await service.removeFromSemanticIndex(url: entry.url)
        #expect(await service.semanticIndex.count == 0)
    }

    @Test func askStreamsAndUnavailableGivesReadableError() async throws {
        let fake = FakeTextGenerator(cannedAnswer: "Ten dollars.")
        let service = AIService(storageDirectory: tempDirectory(), generator: fake, embedder: FakeEmbedder())
        var last = ""
        for try await partial in service.ask("Price?", pages: [page(text: "$10")], scope: .page) { last = partial }
        #expect(last == "Ten dollars.")

        fake.availability = .unavailable(reason: "Turn on Apple Intelligence in System Settings.")
        do {
            for try await _ in service.ask("Price?", pages: [page(text: "$10")], scope: .page) {}
            Issue.record("expected an error")
        } catch {
            #expect(error.localizedDescription == "Turn on Apple Intelligence in System Settings.")
        }
    }

    @Test func turningOffCancelsAnAnswerInProgress() async {
        let fake = FakeTextGenerator(cannedAnswer: String(repeating: "word ", count: 500), wordDelay: .milliseconds(5))
        let service = AIService(storageDirectory: tempDirectory(), generator: fake, embedder: FakeEmbedder())
        let stream = service.ask("Q", pages: [page(text: "t")], scope: .page)
        var received = 0
        var thrown: Error?
        do {
            for try await _ in stream {
                received += 1
                if received == 2 { service.setEnabled(false) }
            }
        } catch { thrown = error }
        // Words already buffered may still arrive on a slow machine; the answer must not run to the end.
        #expect(received < 500)
        #expect(thrown as? AIError == .turnedOff)
    }

    @Test func resumeCardThroughService() async {
        let fake = FakeTextGenerator(cannedAnswer: "You were reading the intro.")
        let service = AIService(storageDirectory: tempDirectory(), generator: fake, embedder: FakeEmbedder())
        let id = PageID()
        #expect(await service.resumeCard(for: id, text: page(text: "Body")) == "You were reading the intro.")
        #expect(await service.resumeCard(for: id, text: page(text: "Body")) == "You were reading the intro.")
        #expect(fake.requests.count == 1)
        service.invalidateResumeCard(page: id)
        _ = await service.resumeCard(for: id, text: page(text: "Body"))
        #expect(fake.requests.count == 2)
    }

    @Test func indexingRespectsTheThirtySecondRuleAndEmbedder() async {
        let service = AIService(storageDirectory: tempDirectory(), generator: FakeTextGenerator(), embedder: FakeEmbedder())
        await service.indexIfNeeded(entry: visit("https://a.com", title: "Garden", dwell: 10), text: page(text: "tomatoes"))
        #expect(await service.semanticIndex.count == 0)

        let noEmbed = AIService(storageDirectory: tempDirectory(), generator: FakeTextGenerator(), embedder: FakeEmbedder(isAvailable: false))
        await noEmbed.indexIfNeeded(entry: visit("https://a.com", title: "Garden"), text: page(text: "tomatoes"))
        #expect(await noEmbed.semanticSearch("garden", limit: 5).isEmpty)
    }

    @Test func demoResponderMakesPlausibleCards() async {
        let fake = FakeTextGenerator(responder: FakeTextGenerator.demo)
        let card = await ResumeCardService(generator: fake).card(for: PageID(), text: page(text: "Body", scroll: 0.5))
        #expect(card == "You were reading Rust ownership, about halfway down.")
    }

    @Test func makeDefaultBuilds() {
        let service = AIService.makeDefault(storageDirectory: tempDirectory())
        // Whatever this Mac supports, availability is a concrete value and the switch defaults on.
        #expect(service.isEnabled)
        #expect(service.availability != .turnedOff)
    }
}


@MainActor
@Suite struct AIFeatureFlagTests {
    @Test func semanticFlagGatesIndexingAndSearchOnly() async {
        let fake = FakeTextGenerator(cannedAnswer: "answer")
        let service = AIService(storageDirectory: tempDirectory(), generator: fake, embedder: FakeEmbedder())
        let entry = visit("https://cooking.com/pasta", title: "Pasta recipe")
        await service.indexIfNeeded(entry: entry, text: page(text: "fresh pasta"))
        #expect(await service.semanticSearch("pasta", limit: 5).count == 1)

        service.semanticEnabled = false
        #expect(await service.semanticSearch("pasta", limit: 5).isEmpty)
        await service.indexIfNeeded(entry: visit("https://other.com/x", title: "Other pasta"), text: page(text: "pasta"))
        #expect(await service.semanticIndex.count == 1)
        var last = ""
        do { for try await partial in service.ask("Q", pages: [page(text: "t")], scope: .page) { last = partial } } catch {}
        #expect(last == "answer")
        #expect(await service.resumeCard(for: PageID(), text: page(text: "Body text here.")) != nil)
        await service.removeFromSemanticIndex(url: entry.url)
        #expect(await service.semanticIndex.count == 0)

        service.semanticEnabled = true
        await service.indexIfNeeded(entry: entry, text: page(text: "fresh pasta"))
        #expect(await service.semanticSearch("pasta", limit: 5).count == 1)
    }

    @Test func summariesFlagGatesResumeCardsOnly() async {
        let fake = FakeTextGenerator(cannedAnswer: "You were reading about pasta.")
        let service = AIService(storageDirectory: tempDirectory(), generator: fake, embedder: FakeEmbedder())
        #expect(await service.resumeCard(for: PageID(), text: page(text: "Body text here.")) != nil)
        let before = fake.requests.count

        service.summariesEnabled = false
        #expect(await service.resumeCard(for: PageID(), text: page(text: "Other body text.")) == nil)
        #expect(fake.requests.count == before)
        var last = ""
        do { for try await partial in service.ask("Q", pages: [page(text: "t")], scope: .page) { last = partial } } catch {}
        #expect(!last.isEmpty)
        await service.indexIfNeeded(entry: visit("https://cooking.com/pasta", title: "Pasta recipe"), text: page(text: "pasta"))
        #expect(await service.semanticSearch("pasta", limit: 5).count == 1)
    }

    @Test func masterSwitchStillWinsOverFlags() async {
        let service = AIService(storageDirectory: tempDirectory(), generator: FakeTextGenerator(cannedAnswer: "x"), embedder: FakeEmbedder())
        service.setEnabled(false)
        #expect(service.semanticEnabled && service.summariesEnabled)
        #expect(await service.resumeCard(for: PageID(), text: page(text: "Body")) == nil)
        #expect(await service.semanticSearch("pasta", limit: 5).isEmpty)
    }
}

@MainActor
@Suite struct AISettingsFileCompatibility {
    @Test func existingFileFormatIsStillRead() throws {
        let dir = tempDirectory()
        try Data(#"{"isEnabled":false}"#.utf8).write(to: dir.appending(path: "ai-settings.json"))
        #expect(!AISettings(storageDirectory: dir).isEnabled)
        try Data(#"{"isEnabled":true}"#.utf8).write(to: dir.appending(path: "ai-settings.json"))
        #expect(AISettings(storageDirectory: dir).isEnabled)
        #expect(AISettings.fileName == "ai-settings.json")
    }

    @Test func settingsFileIsSeparateAndGarbageMeansOn() throws {
        let dir = tempDirectory()
        try Data("nope".utf8).write(to: dir.appending(path: "ai-settings.json"))
        #expect(AISettings(storageDirectory: dir).isEnabled)
        // Writing the switch writes exactly the old format, nothing else.
        AISettings(storageDirectory: dir).setEnabled(false)
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appending(path: "ai-settings.json"))) as? [String: Bool]
        #expect(json == ["isEnabled": false])
    }
}
