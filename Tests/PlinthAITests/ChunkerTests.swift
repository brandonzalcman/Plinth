import Foundation
import Testing
import PlinthModel
@testable import PlinthAI

@Suite struct ChunkerTests {
    @Test func emptyTextGivesNoChunks() {
        #expect(TextChunker(maxCharacters: 100).chunks("").isEmpty)
        #expect(TextChunker(maxCharacters: 100).chunks("  \n\n \t ").isEmpty)
    }

    @Test func shortTextIsOneChunk() {
        #expect(TextChunker(maxCharacters: 100).chunks("Hello there.") == ["Hello there."])
    }

    @Test func packsParagraphsTogetherUpToTheLimit() {
        let text = "Alpha one.\n\nBeta two.\n\nGamma three."
        let chunks = TextChunker(maxCharacters: 24).chunks(text)
        #expect(chunks == ["Alpha one.\n\nBeta two.", "Gamma three."])
    }

    @Test func splitsLongParagraphOnSentences() {
        let text = "First sentence here. Second sentence here! Third one? Fourth."
        let chunks = TextChunker(maxCharacters: 25).chunks(text)
        #expect(chunks == ["First sentence here.", "Second sentence here!", "Third one? Fourth."])
    }

    @Test func splitsLongSentenceOnWords() {
        let text = "one two three four five six seven eight nine ten"
        let chunks = TextChunker(maxCharacters: 14).chunks(text)
        #expect(chunks.allSatisfy { $0.count <= 14 })
        #expect(chunks.joined(separator: " ") == text)
        #expect(chunks.first == "one two three")
    }

    @Test func hardSplitsAnOverlongWord() {
        let chunks = TextChunker(maxCharacters: 4).chunks("abcdefghij")
        #expect(chunks == ["abcd", "efgh", "ij"])
    }

    @Test func sentencesKeepClosingQuotesAndDoNotSplitDecimals() {
        let s = TextChunker.sentences(of: "He said \"stop.\" Then 3.5 people left. Done")
        #expect(s == ["He said \"stop.\"", "Then 3.5 people left.", "Done"])
    }

    @Test func overlapCarriesTheTailOfThePreviousChunk() {
        let text = "aaa bbb ccc ddd eee fff ggg hhh iii jjj"
        let chunks = TextChunker(maxCharacters: 16, overlap: 7).chunks(text)
        #expect(chunks.count > 2)
        for (prev, next) in zip(chunks, chunks.dropFirst()) {
            let lastWord = prev.split(separator: " ").last!
            #expect(next.hasPrefix(String(lastWord)) || next.contains(String(lastWord)))
        }
        #expect(chunks.allSatisfy { $0.count <= 16 })
    }

    @Test func neverExceedsTheLimitOnMessyText() {
        var generator = SplitMix(seed: 42)
        let words = ["the", "quick", "brown", "fox.", "jumps!", "over", "lazy", "dogs?", "supercalifragilistic", "a"]
        for limit in [5, 17, 40, 120] {
            for overlap in [0, 3, 30] {
                var text = ""
                for _ in 0..<400 {
                    text += words[Int(generator.next() % UInt64(words.count))]
                    text += generator.next() % 9 == 0 ? "\n\n" : (generator.next() % 13 == 0 ? "\n" : " ")
                }
                let chunks = TextChunker(maxCharacters: limit, overlap: overlap).chunks(text)
                #expect(!chunks.isEmpty)
                #expect(chunks.allSatisfy { $0.count <= limit && !$0.isEmpty })
                if overlap == 0 {
                    // Nothing lost: every word of the source appears in order.
                    let source = text.split(whereSeparator: \.isWhitespace).joined()
                    let rebuilt = chunks.joined().split(whereSeparator: \.isWhitespace).joined()
                    #expect(source == rebuilt)
                }
            }
        }
    }

    @Test func truncatePrefersSentenceThenWordBoundaries() {
        #expect(TextUtil.truncate("Short.", to: 50) == "Short.")
        #expect(TextUtil.truncate("One two three. Four five six seven", to: 20) == "One two three.")
        let cut = TextUtil.truncate("alpha beta gamma delta epsilon", to: 15)
        #expect(cut == "alpha beta…")
        #expect(cut.count <= 15)
        #expect(TextUtil.truncate("abcdefghijklmnop", to: 8).count <= 8)
    }

    @Test func stableHashIsStableAndSeparatesParts() {
        #expect(TextUtil.stableHash(["a", "b"]) == TextUtil.stableHash(["a", "b"]))
        #expect(TextUtil.stableHash(["ab", ""]) != TextUtil.stableHash(["a", "b"]))
    }
}

/// Small deterministic PRNG for fuzz-style tests.
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
