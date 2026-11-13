import Foundation

/// The pure decisions behind "HTTPS-only" mode.
public enum HTTPSOnly {
    /// The https twin of an http URL, or nil when the URL should stay as it is: not http, a local or
    /// development host (localhost, `*.localhost`, `*.local`, `*.test`), or a bare IP address.
    public static func upgraded(_ url: URL) -> URL? {
        guard url.scheme?.lowercased() == "http", let host = url.host(percentEncoded: false)?.lowercased(),
              !host.isEmpty, !isExempt(host: host) else { return nil }
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        parts.scheme = "https"
        // An explicit :80 would point https at the wrong port; any other explicit port is kept.
        if parts.port == 80 { parts.port = nil }
        return parts.url
    }

    public static func shouldUpgrade(_ url: URL) -> Bool { upgraded(url) != nil }

    /// Hosts that stay on http.
    public static func isExempt(host rawHost: String) -> Bool {
        var host = rawHost.lowercased()
        if host.hasSuffix(".") { host.removeLast() }
        if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host == "localhost" || host == "::1" { return true }
        for suffix in [".localhost", ".local", ".test"] where host.hasSuffix(suffix) { return true }
        if host.contains(":") { return true }  // IPv6 literal
        return isIPv4(host)
    }

    private static func isIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { Int($0).map { (0...255).contains($0) } ?? false }
    }

    /// Whether a failed https load (an `NSURLErrorDomain` code) is worth offering the http fallback for:
    /// the server could not be reached over a secure connection.
    public static func isFallbackEligible(urlErrorCode code: Int) -> Bool {
        let codes: Set<Int> = [
            NSURLErrorCannotConnectToHost, NSURLErrorSecureConnectionFailed, NSURLErrorTimedOut,
            NSURLErrorNetworkConnectionLost, NSURLErrorServerCertificateHasBadDate,
            NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasUnknownRoot,
            NSURLErrorServerCertificateNotYetValid, NSURLErrorClientCertificateRejected,
            NSURLErrorClientCertificateRequired,
        ]
        return codes.contains(code)
    }
}
