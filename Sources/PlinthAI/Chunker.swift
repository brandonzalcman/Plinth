import Foundation

/// Splits text into chunks of at most `maxCharacters` characters.
///
/// Boundaries are preferred in this order: paragraphs (blank lines or line breaks), then
/// sentences, then words. A single word longer than the limit is cut by characters as a last
/// resort. Every chunk is guaranteed to be at most `maxCharacters` long (counted in `Character`s).
///
/// With `overlap > 0`, each chunk after the first begins with up to `overlap` characters taken
/// from the end of the previous chunk (cut at a word boundary), so context that straddles a
/// boundary is not lost. Overlap is capped at half the chunk size and dropped when it would not
/// fit alongside the next piece.
public struct TextChunker: Sendable, Equatable {
    public var maxCharacters: Int
    public var overlap: Int

    public init(maxCharacters: Int, overlap: Int = 0) {
        self.maxCharacters = max(1, maxCharacters)
        self.overlap = max(0, overlap)
    }

    /// The chunks of `text`, in order. Empty or whitespace-only text gives no chunks.
    public func chunks(_ text: String) -> [String] {
        let pieces = Self.pieces(of: text, limit: maxCharacters)
        guard !pieces.isEmpty else { return [] }

        let effectiveOverlap = min(overlap, maxCharacters / 2)
        var result: [String] = []
        var current = ""
        var currentCount = 0

        for piece in pieces {
            if currentCount == 0 {
                current = piece.text; currentCount = piece.count
                continue
            }
            let joined = currentCount + piece.separator.count + piece.count
            if joined <= maxCharacters {
                current += piece.separator + piece.text
                currentCount = joined
                continue
            }
            result.append(current)
            let tail = effectiveOverlap > 0 ? Self.tail(of: current, maxCharacters: effectiveOverlap) : ""
            let tailCount = tail.count
            if tailCount > 0, tailCount + 1 + piece.count <= maxCharacters {
                current = tail + " " + piece.text
                currentCount = tailCount + 1 + piece.count
            } else {
                current = piece.text; currentCount = piece.count
            }
        }
        if currentCount > 0 { result.append(current) }
        return result
    }

    // MARK: - Pieces

    /// An atomic unit that fits in one chunk, plus the separator to put before it when it is
    /// joined to the previous unit.
    struct Piece: Equatable {
        var text: String
        var count: Int
        var separator: String
    }

    static func pieces(of text: String, limit: Int) -> [Piece] {
        var out: [Piece] = []
        for paragraph in paragraphs(of: text) {
            let paragraphCount = paragraph.count
            if paragraphCount <= limit {
                out.append(Piece(text: paragraph, count: paragraphCount, separator: "\n\n"))
                continue
            }
            var first = true
            for sentence in sentences(of: paragraph) {
                let sentenceCount = sentence.count
                if sentenceCount <= limit {
                    out.append(Piece(text: sentence, count: sentenceCount, separator: first ? "\n\n" : " "))
                    first = false
                    continue
                }
                for word in words(of: sentence) {
                    for part in hardSplit(word, limit: limit) {
                        out.append(Piece(text: part, count: part.count, separator: first ? "\n\n" : " "))
                        first = false
                    }
                }
            }
        }
        return out
    }

    /// Non-empty lines, trimmed, with runs of spaces collapsed. Any line break counts as a
    /// paragraph break (extracted page text rarely distinguishes the two).
    static func paragraphs(of text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { collapseSpaces(String($0)) }
            .filter { !$0.isEmpty }
    }

    /// Sentences end after `.`, `!`, `?` or `…` (plus any closing quotes or brackets) when
    /// followed by whitespace.
    static func sentences(of paragraph: String) -> [String] {
        var out: [String] = []
        var current = ""
        let chars = Array(paragraph)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            current.append(c)
            if ".!?…".contains(c) {
                var j = i + 1
                while j < chars.count, "\"'”’)]".contains(chars[j]) { current.append(chars[j]); j += 1 }
                if j >= chars.count || chars[j].isWhitespace {
                    let trimmed = current.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty { out.append(trimmed) }
                    current = ""
                }
                i = j
                continue
            }
            i += 1
        }
        let trimmed = current.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { out.append(trimmed) }
        return out
    }

    static func words(of sentence: String) -> [String] {
        sentence.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    static func hardSplit(_ word: String, limit: Int) -> [String] {
        guard word.count > limit else { return [word] }
        var out: [String] = []
        var rest = Substring(word)
        while !rest.isEmpty {
            out.append(String(rest.prefix(limit)))
            rest = rest.dropFirst(limit)
        }
        return out
    }

    static func collapseSpaces(_ s: String) -> String {
        s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The last at most `maxCharacters` characters of `text`, starting at a word boundary.
    static func tail(of text: String, maxCharacters: Int) -> String {
        guard text.count > maxCharacters else { return collapseSpaces(text) }
        let suffix = text.suffix(maxCharacters)
        // Drop the (probably partial) first word unless the cut landed on a boundary.
        let startsClean = suffix.first?.isWhitespace == true
            || text[text.index(before: suffix.startIndex)].isWhitespace
        let trimmed = startsClean ? Substring(suffix) : suffix.drop { !$0.isWhitespace }
        return collapseSpaces(String(trimmed))
    }
}

/// Text helpers shared by the services.
enum TextUtil {
    /// `text` cut to at most `limit` characters, preferring a sentence end, then a word end,
    /// with an ellipsis when something was removed mid-sentence.
    static func truncate(_ text: String, to limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        guard limit > 1 else { return String(trimmed.prefix(max(0, limit))) }
        let head = trimmed.prefix(limit)
        if let end = head.lastIndex(where: { ".!?…".contains($0) }),
           head.distance(from: head.startIndex, to: end) >= limit / 2 {
            return String(head[...end])
        }
        let room = head.prefix(limit - 1)
        if let space = room.lastIndex(where: \.isWhitespace),
           room.distance(from: room.startIndex, to: space) >= limit / 2 {
            return String(room[..<space]).trimmingCharacters(in: .whitespaces) + "…"
        }
        return String(room) + "…"
    }

    /// FNV-1a 64-bit, stable across launches (unlike `Hasher`).
    static func stableHash(_ parts: [String]) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for part in parts {
            for byte in part.utf8 { hash ^= UInt64(byte); hash &*= 0x0000_0100_0000_01B3 }
            hash ^= 0xFF; hash &*= 0x0000_0100_0000_01B3
        }
        return hash
    }
}
