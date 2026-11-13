import Foundation

/// Search-engine autocomplete ("github" -> "github login", "github copilot"...), as Arc and every
/// other browser offers while typing. Only the built-in engines have a known endpoint; a custom
/// engine gets none. Building the request and reading the answer are pure so they can be tested.
public enum SearchSuggestions {
    /// The autocomplete URL for `query`, or nil for an engine without one.
    public static func endpoint(for engine: SearchEngine, query: String) -> URL? {
        let template: String
        switch engine.kind {
        case .google: template = "https://suggestqueries.google.com/complete/search?client=firefox&q=%s"
        case .duckDuckGo: template = "https://duckduckgo.com/ac/?type=list&q=%s"
        case .bing: template = "https://api.bing.com/osjson.aspx?query=%s"
        case .brave: template = "https://search.brave.com/api/suggest?q=%s"
        case .ecosia: template = "https://ac.ecosia.org/autocomplete?type=list&q=%s"
        case .custom: return nil
        }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: template.replacingOccurrences(of: "%s", with: encoded))
    }

    /// The request to send for text typed in the command bar, or nil when nothing may be sent:
    /// the setting is off, the window is private, the text looks like an address, or the engine
    /// has no endpoint.
    public static func request(for query: String, engine: SearchEngine, enabled: Bool, isPrivate: Bool) -> URL? {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard enabled, !isPrivate, isWorthAsking(text) else { return nil }
        return endpoint(for: engine, query: text)
    }

    /// The OpenSearch suggestion format all of these share: `["query", ["a", "b", ...], ...]`.
    /// Anything else (or an empty answer) gives no suggestions.
    public static func parse(_ data: Data, query: String, limit: Int = 5) -> [String] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [Any], json.count >= 2,
              let list = json[1] as? [Any] else { return [] }
        var seen: Set<String> = [query.lowercased()]
        var out: [String] = []
        for case let item as String in list {
            let text = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text.count <= 120, seen.insert(text.lowercased()).inserted else { continue }
            out.append(text)
            if out.count == limit { break }
        }
        return out
    }

    /// Worth asking the engine about: plain text of a few letters, not an address.
    public static func isWorthAsking(_ query: String) -> Bool {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 2, text.count <= 80 else { return false }
        return !(text.contains("/") || text.contains("://") || text.contains(":") || (text.contains(".") && !text.contains(" ")))
    }
}
