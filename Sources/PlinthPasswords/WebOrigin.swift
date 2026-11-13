import Foundation

/// A web origin (scheme, host, port): the only unit a saved login is ever matched on.
/// `https://example.com` and `http://example.com` are different origins, as are subdomains and ports.
public struct WebOrigin: Hashable, Sendable, Codable, CustomStringConvertible {
    public let scheme: String
    public let host: String
    /// nil for the scheme's default port.
    public let port: Int?

    public init?(scheme: String, host: String, port: Int?) {
        let scheme = scheme.lowercased()
        let host = host.lowercased()
        guard scheme == "http" || scheme == "https", !host.isEmpty else { return nil }
        let defaultPort = scheme == "https" ? 443 : 80
        self.scheme = scheme
        self.host = host
        self.port = (port == nil || port == 0 || port == defaultPort) ? nil : port
    }

    public init?(url: URL) {
        guard let scheme = url.scheme, let host = url.host else { return nil }
        self.init(scheme: scheme, host: host, port: url.port)
    }

    /// Accepts "https://example.com", "https://example.com/login?x=1" or a bare "example.com" (taken as https).
    public init?(string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let text = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let url = URL(string: text) else { return nil }
        self.init(url: url)
    }

    public var isSecure: Bool { scheme == "https" }

    /// "https://example.com" or "http://localhost:3000".
    public var description: String {
        port.map { "\(scheme)://\(host):\($0)" } ?? "\(scheme)://\(host)"
    }

    /// The host as shown to people: no "www.".
    public var displayHost: String {
        let h = host.hasPrefix("www.") && host.count > 6 ? String(host.dropFirst(4)) : host
        return port.map { "\(h):\($0)" } ?? h
    }

    // MARK: Policy

    /// A saved login may fill a page only when the page is the very origin it was saved for.
    /// That alone rules out an https -> http downgrade and any look-alike or sibling host.
    public static func mayFill(saved: WebOrigin, into page: WebOrigin) -> Bool { saved == page }

    /// Whether submitting the form to `action` is safe for credentials filled on `page`. A form with no action
    /// posts to the page itself. Otherwise the action must stay on the page's origin, or move from http to https on the same host.
    public static func formActionAllowed(page: WebOrigin, action: String?) -> Bool {
        guard let action, !action.trimmingCharacters(in: .whitespaces).isEmpty else { return true }
        guard let url = URL(string: action) else { return false }
        if url.scheme == nil { return true }   // relative
        guard let target = WebOrigin(url: url) else {
            // javascript: handlers are the page's own business; data:/blob: and the like are not.
            return url.scheme?.lowercased() == "javascript"
        }
        if target == page { return true }
        return !page.isSecure && target.isSecure && target.host == page.host
    }
}
