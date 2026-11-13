import Foundation

/// A web search provider. `AddressResolver` builds search URLs from one.
public struct SearchEngine: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case google, duckDuckGo, bing, ecosia, brave, custom

        public var displayName: String {
            switch self {
            case .google: "Google"
            case .duckDuckGo: "DuckDuckGo"
            case .bing: "Bing"
            case .ecosia: "Ecosia"
            case .brave: "Brave Search"
            case .custom: "Custom"
            }
        }

        /// The template for the built-in engines; `%s` stands for the query.
        public var template: String? {
            switch self {
            case .google: "https://www.google.com/search?q=%s"
            case .duckDuckGo: "https://duckduckgo.com/?q=%s"
            case .bing: "https://www.bing.com/search?q=%s"
            case .ecosia: "https://www.ecosia.org/search?q=%s"
            case .brave: "https://search.brave.com/search?q=%s"
            case .custom: nil
            }
        }
    }

    public var kind: Kind
    /// Used only when `kind == .custom`.
    public var customTemplate: String

    public init(kind: Kind = .duckDuckGo, customTemplate: String = "") {
        self.kind = kind
        self.customTemplate = customTemplate
    }

    public static let duckDuckGo = SearchEngine(kind: .duckDuckGo)

    /// The template in force. A custom engine whose template is invalid falls back to DuckDuckGo.
    public var effectiveTemplate: String {
        if kind == .custom { return Self.isValid(template: customTemplate) ? customTemplate.trimmingCharacters(in: .whitespacesAndNewlines) : Kind.duckDuckGo.template! }
        return kind.template ?? Kind.duckDuckGo.template!
    }

    /// A custom template must be an http(s) URL with a host and contain `%s` at least once.
    public static func isValid(template: String) -> Bool {
        let text = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.contains("%s"), !text.contains(where: \.isWhitespace),
              let url = URL(string: text.replacingOccurrences(of: "%s", with: "test")),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return false }
        return true
    }

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    public func searchURL(for query: String) -> URL {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: Self.unreserved) ?? ""
        let text = effectiveTemplate.replacingOccurrences(of: "%s", with: encoded)
        return URL(string: text) ?? URL(string: "https://duckduckgo.com/")!
    }
}
