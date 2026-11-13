import Foundation

/// Decides whether text typed into the address bar is an address or a search.
///
/// - Anything with an explicit `scheme://` is a URL (http/https need a host).
/// - `about:`, `data:`, `file:`, `blob:`, `mailto:`, `tel:` are URLs without the slashes.
///   Any other `word:` prefix ("define:x", "javascript:...") is a search.
/// - Text containing whitespace is a search (unless it began with `scheme://`).
/// - localhost, IPv4/IPv6 addresses, `host:port`, `host/` and names under .local/.test/.internal/.lan
///   are URLs and default to http.
/// - A dotted name is a URL (https) only when its last label is a plausible TLD from an embedded
///   list, is punycode, or the text also carries a port or a `www.` prefix. So "example.com" is a
///   URL while "node.js", "readme.md", "setup.py" and "3.14" are searches.
/// - Email-shaped text ("a@b.com") is a search.
public struct AddressResolver: Sendable {
    public enum Resolved: Equatable, Sendable {
        case url(URL)
        case search(String)
    }

    public init() {}

    public func resolve(_ input: String) -> Resolved {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .search("") }
        let hasSpace = text.contains(where: \.isWhitespace)

        if let colon = text.firstIndex(of: ":"), Self.isSchemeName(text[..<colon]) {
            let scheme = text[..<colon].lowercased()
            let rest = text[text.index(after: colon)...]
            if rest.hasPrefix("//") {
                let candidate = hasSpace ? text.replacingOccurrences(of: " ", with: "%20") : text
                if let url = URL(string: candidate), !candidate.contains(where: \.isWhitespace) {
                    let host = url.host ?? ""
                    let needsHost = ["http", "https", "ws", "wss", "ftp"].contains(scheme)
                    if !needsHost || (!host.isEmpty && !host.contains("%") && !host.contains(" ")) {
                        return .url(url)
                    }
                }
                return .search(text)
            }
            if Self.opaqueSchemes.contains(scheme), !rest.isEmpty, !hasSpace || scheme == "data",
               let url = URL(string: hasSpace ? text.replacingOccurrences(of: " ", with: "%20") : text) {
                return .url(url)
            }
        }
        if hasSpace { return .search(text) }
        return bare(text)
    }

    public func searchURL(for query: String) -> URL {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: Self.unreserved) ?? ""
        return URL(string: "https://duckduckgo.com/?q=" + encoded) ?? URL(string: "https://duckduckgo.com/")!
    }

    /// Where the typed text leads: the URL itself, or the search page for it.
    public func destination(for input: String) -> URL {
        switch resolve(input) {
        case .url(let url): return url
        case .search(let query): return searchURL(for: query)
        }
    }

    // MARK: - Private

    private static let opaqueSchemes: Set<String> = ["about", "data", "file", "blob", "mailto", "tel", "sms", "facetime"]
    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static func isSchemeName(_ text: Substring) -> Bool {
        guard let first = text.first, first.isASCII, first.isLetter else { return false }
        return text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == ".") }
    }

    private static func isPort(_ text: Substring) -> Bool {
        guard (1...5).contains(text.count), text.allSatisfy({ $0.isASCII && $0.isNumber }),
              let value = Int(text) else { return false }
        return value <= 65535
    }

    private static func isLabel(_ label: Substring) -> Bool {
        guard (1...63).contains(label.count), label.first != "-", label.last != "-" else { return false }
        return label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
    }

    private func bare(_ text: String) -> Resolved {
        let cut = text.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) ?? text.endIndex
        let authority = text[..<cut]
        let rest = text[cut...]
        guard !authority.isEmpty, !authority.contains("@") else { return .search(text) }

        func make(_ scheme: String) -> Resolved {
            guard let url = URL(string: scheme + "://" + text), let host = url.host, !host.isEmpty else {
                return .search(text)
            }
            return .url(url)
        }

        if authority.hasPrefix("[") {
            guard let close = authority.firstIndex(of: "]") else { return .search(text) }
            let inner = String(authority[authority.index(after: authority.startIndex)..<close])
            let after = authority[authority.index(after: close)...]
            guard DomainRules.isIPv6(inner), after.isEmpty || (after.hasPrefix(":") && Self.isPort(after.dropFirst())) else {
                return .search(text)
            }
            return make("http")
        }

        var host = authority
        var hasPort = false
        if let colon = authority.lastIndex(of: ":") {
            guard Self.isPort(authority[authority.index(after: colon)...]) else { return .search(text) }
            host = authority[..<colon]
            hasPort = true
        }
        if host.hasSuffix(".") { host = host.dropLast() }
        let name = host.lowercased()
        if name == "localhost" || DomainRules.isIPv4(name) { return make("http") }

        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty, labels.allSatisfy(Self.isLabel) else { return .search(text) }
        if labels.count == 1 {
            // "devbox:8080" and "intranet/" are hosts; "hello" and "and/or" are searches.
            return hasPort || rest == "/" ? make("http") : .search(text)
        }
        let tld = String(labels[labels.count - 1])
        if DomainRules.localTLDs.contains(tld) { return make("http") }
        let alphabetic = tld.count >= 2 && tld.allSatisfy(\.isLetter)
        let plausible = DomainRules.commonTLDs.contains(tld) || tld.hasPrefix("xn--")
            || ((hasPort || labels[0] == "www") && alphabetic)
        return plausible ? make("https") : .search(text)
    }
}
