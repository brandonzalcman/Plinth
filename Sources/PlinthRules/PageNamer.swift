import Foundation
import PlinthModel

/// Turns a raw document title into the short name shown on a page button.
///
/// Rules, in order:
/// 1. Whitespace is collapsed, invisible characters removed, and leading notification markers
///    stripped: "(3) ", "[12] ", "(99+) ", "● ", "• ", "🔴 " (counts of up to three digits only,
///    so "(2024) Report" is left alone).
/// 2. The title is split into segments on a separator standing alone between spaces:
///    — – ― | · • » « › ‹ / : > - (and runs such as "--" or "::").
/// 3. Segments that are the site are dropped: equal to the site name, the host, or the host's
///    registrable label (ignoring case, diacritics and punctuation), optionally padded with generic
///    words ("Home", "Official Site", "Welcome to", ".com"). Pure filler such as "Official Website"
///    is dropped as well. A bare "Home" is kept: it is a page name.
/// 4. The first remaining segment that contains a letter or digit wins.
/// 5. Colon rule. A colon followed by a space ("Title: subtitle") is NOT a separator on its own,
///    so "Re: budget", "Swift: a guide" and "10:30 meeting" stay whole. It splits only when
///    (a) one side is the site ("Amazon.com: Kindle" -> "Kindle"), or (b) the name is over the
///    length cap and the part before the colon is a real title (two or more words, ten or more
///    characters), in which case that part is kept and the subtitle dropped.
/// 6. If nothing is left: the site name; for an empty title, a readable form of the URL's last
///    path component first ("/booking/seat-map.html" -> "Seat map"), then the site name, then the host.
/// 7. The result is capped at 60 characters on a word boundary, ending in "…" when cut.
public struct PageNamer: PageNaming {
    public static let maxLength = 60

    public init() {}

    public func name(title: String, url: URL, siteName: String) -> String {
        let site = Self.clean(siteName)
        let cleaned = Self.stripLeadingMarkers(Self.clean(title))
        guard !cleaned.isEmpty else { return Self.cap(Self.fallback(url: url, siteName: site)) }

        let forms = Self.siteForms(siteName: site, url: url)
        let segments = Self.segments(of: cleaned)
        for segment in segments {
            if let kept = Self.reduce(segment, forms: forms) {
                return Self.cap(Self.dropSubtitleIfLong(kept))
            }
        }
        if !site.isEmpty { return Self.cap(site) }
        if let first = segments.first(where: Self.hasContent) { return Self.cap(first) }
        return Self.cap(Self.fallback(url: url, siteName: site))
    }

    // MARK: - Cleaning

    private static let invisible: Set<Unicode.Scalar> = [
        "\u{200B}", "\u{200C}", "\u{200D}", "\u{200E}", "\u{200F}", "\u{202A}", "\u{202B}",
        "\u{202C}", "\u{202D}", "\u{202E}", "\u{2060}", "\u{FEFF}", "\u{00AD}",
    ]

    static func clean(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars where !invisible.contains(scalar) {
            scalars.append(scalar.properties.isWhitespace || scalar.properties.generalCategory == .control ? " " : scalar)
        }
        return String(scalars).split(separator: " ").joined(separator: " ")
    }

    private static let bullets: Set<Character> = ["●", "•", "◉", "○", "◦", "∙", "*", "🔴", "🟢", "🔵", "🟠", "🟡", "⚫", "⬤"]

    static func stripLeadingMarkers(_ text: String) -> String {
        var text = Substring(text)
        while let first = text.first {
            if first == "(" || first == "[" {
                let close: Character = first == "(" ? ")" : "]"
                guard let end = text.firstIndex(of: close) else { break }
                var inner = text[text.index(after: text.startIndex)..<end]
                if inner.hasSuffix("+") { inner = inner.dropLast() }
                guard (1...3).contains(inner.count), inner.allSatisfy({ $0.isASCII && $0.isNumber }) else { break }
                let rest = text[text.index(after: end)...].drop(while: { $0 == " " })
                guard !rest.isEmpty else { break }
                text = rest
            } else if bullets.contains(first) {
                let rest = text.dropFirst()
                guard rest.first == " " else { break }
                text = rest.drop(while: { $0 == " " })
            } else {
                break
            }
        }
        return String(text)
    }

    // MARK: - Segments

    private static let separatorCharacters: Set<Character> = [
        "—", "–", "―", "|", "｜", "·", "•", "⋅", "∙", "»", "«", "›", "‹", "/", ":", ">", "-",
    ]

    /// Splits on any word made only of separator characters (the text is already single-spaced).
    static func segments(of text: String) -> [String] {
        var result: [String] = []
        var current: [Substring] = []
        for word in text.split(separator: " ") {
            if word.allSatisfy(separatorCharacters.contains) {
                if !current.isEmpty { result.append(current.joined(separator: " ")) }
                current = []
            } else {
                current.append(word)
            }
        }
        if !current.isEmpty { result.append(current.joined(separator: " ")) }
        return result
    }

    static func hasContent(_ text: String) -> Bool {
        text.contains { $0.isLetter || $0.isNumber }
    }

    /// The segment with any site part removed, or nil when nothing of its own remains.
    private static func reduce(_ segment: String, forms: [[String]]) -> String? {
        guard hasContent(segment), !isSiteOrFiller(segment, forms: forms) else { return nil }
        let parts = segment.components(separatedBy: ": ")
        guard parts.count > 1 else { return segment }
        let kept = parts.filter { hasContent($0) && !isSiteOrFiller($0, forms: forms) }
        if kept.count == parts.count { return segment }
        return kept.isEmpty ? nil : kept.joined(separator: ": ")
    }

    private static func dropSubtitleIfLong(_ name: String) -> String {
        guard name.count > maxLength, let colon = name.range(of: ": ") else { return name }
        let head = String(name[..<colon.lowerBound])
        guard head.count >= 10, head.split(separator: " ").count >= 2 else { return name }
        return head
    }

    // MARK: - Site matching

    /// Words that may surround a site name without making the segment a page name.
    private static let genericWords: Set<String> = [
        "home", "homepage", "page", "official", "site", "website", "web", "welcome", "to", "the", "of",
        "online", "com", "org", "net", "io", "co", "www", "inc", "llc", "ltd", "main", "index",
    ]
    /// Words that, on their own, say nothing about the page.
    private static let fillerWords: Set<String> = ["official", "site", "website", "web", "welcome", "to", "the"]

    static func tokens(_ text: String) -> [String] {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        var out = ""
        for ch in folded {
            if ch == "'" || ch == "’" || ch == "‘" { continue }
            out.append(ch.isLetter || ch.isNumber ? ch : " ")
        }
        return out.split(separator: " ").map(String.init)
    }

    private static func siteForms(siteName: String, url: URL) -> [[String]] {
        var forms: [[String]] = []
        func add(_ text: String) {
            let t = tokens(text)
            if !t.isEmpty, !forms.contains(t) { forms.append(t) }
        }
        add(siteName)
        if var host = url.host?.lowercased(), !host.isEmpty {
            if host.hasPrefix("www.") { host.removeFirst(4) }
            add(host)
            if let registrable = DomainRules.registrableDomain(of: host) {
                add(registrable)
                let label = DomainRules.unicodeLabel(String(registrable.split(separator: ".")[0]))
                if label.count >= 3 { add(label) }
            }
        }
        return forms
    }

    private static func isSiteOrFiller(_ segment: String, forms: [[String]]) -> Bool {
        let seg = tokens(segment)
        guard !seg.isEmpty else { return false }
        if seg.allSatisfy(fillerWords.contains) { return true }
        let segCore = seg.filter { !genericWords.contains($0) }.joined()
        for form in forms {
            // The site name as a run of whole words, with only generic words around it.
            if seg.count >= form.count {
                for start in 0...(seg.count - form.count) where Array(seg[start..<start + form.count]) == form {
                    let rest = seg[..<start] + seg[(start + form.count)...]
                    if rest.allSatisfy(genericWords.contains) { return true }
                }
            }
            // Same letters, different spacing: "HackerNews" vs "Hacker News".
            let formCore = form.filter { !genericWords.contains($0) }.joined()
            if !segCore.isEmpty, segCore == formCore { return true }
            if seg.joined() == form.joined() { return true }
        }
        return false
    }

    // MARK: - Fallbacks

    private static func fallback(url: URL, siteName: String) -> String {
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "file" {
            let last = url.lastPathComponent
            if !last.isEmpty, last != "/" { return last }
        } else if scheme == "http" || scheme == "https" {
            if let last = url.pathComponents.last(where: { $0 != "/" }), let readable = readable(last) {
                return readable
            }
        }
        if !siteName.isEmpty { return siteName }
        if var host = url.host?.lowercased(), !host.isEmpty {
            if host.hasPrefix("www.") { host.removeFirst(4) }
            return host
        }
        let whole = clean(url.absoluteString)
        return whole.isEmpty ? "Untitled" : whole
    }

    /// "seat-map.html" -> "Seat map". Nil for index pages and for identifiers.
    static func readable(_ component: String) -> String? {
        var stem = component
        if let dot = stem.lastIndex(of: "."), dot != stem.startIndex {
            let ext = stem[stem.index(after: dot)...]
            if (1...5).contains(ext.count), ext.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) {
                stem = String(stem[..<dot])
            }
        }
        guard stem.contains(where: \.isLetter) else { return nil }
        if stem.count >= 16, stem.allSatisfy({ $0.isHexDigit || $0 == "-" }) { return nil }
        if ["index", "default"].contains(stem.lowercased()) { return nil }
        let words = stem.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == "+" || $0 == " " })
        let text = words.joined(separator: " ")
        guard !text.isEmpty else { return nil }
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    static func cap(_ text: String) -> String {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return "Untitled" }
        guard text.count > maxLength else { return text }
        let limit = maxLength - 1
        var cut = text.prefix(limit)
        let next = text[text.index(text.startIndex, offsetBy: limit)]
        if next != " ", let space = cut.lastIndex(of: " "),
           text.distance(from: text.startIndex, to: space) >= maxLength / 2 {
            cut = cut[..<space]
        }
        let trimmed = String(cut).trimmingCharacters(in: CharacterSet(charactersIn: " ,;:-–—·|/"))
        return (trimmed.isEmpty ? String(text.prefix(limit)) : trimmed) + "…"
    }
}
