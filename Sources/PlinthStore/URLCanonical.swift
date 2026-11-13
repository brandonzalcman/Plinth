import Foundation

/// Decides when two addresses are "the same page" for suggestions and history.
///
/// The key ignores the scheme (http/https), a leading `www.`, a default port, the fragment, a
/// trailing slash or `index.html`, tracking parameters (utm_*, fbclid, gclid, ...) and the
/// order of the remaining query parameters. Host is lowercased; the path is not.
/// String based, because it runs for every history entry.
enum URLCanonical {
    static func key(_ url: URL) -> String {
        key(url.absoluteString)
    }

    static func key(_ address: String) -> String {
        var s = Substring(address)
        let isWeb: Bool
        if let r = s.range(of: "://") {
            let scheme = s[..<r.lowerBound].lowercased()
            isWeb = scheme == "http" || scheme == "https"
            s = isWeb ? s[r.upperBound...] : s
        } else {
            isWeb = false
        }
        if let hash = s.firstIndex(of: "#") { s = s[..<hash] }
        guard isWeb else { return String(s) }

        var query: Substring = ""
        if let q = s.firstIndex(of: "?") {
            query = s[s.index(after: q)...]
            s = s[..<q]
        }
        var host = s
        var path: Substring = ""
        if let slash = s.firstIndex(of: "/") {
            host = s[..<slash]
            path = s[slash...]
        }
        if let at = host.lastIndex(of: "@") { host = host[host.index(after: at)...] }
        var hostText = host.lowercased()
        if hostText.hasSuffix(":80") { hostText.removeLast(3) } else if hostText.hasSuffix(":443") { hostText.removeLast(4) }
        if hostText.hasPrefix("www.") { hostText.removeFirst(4) }
        if hostText.hasSuffix(".") { hostText.removeLast() }

        var pathText = String(path)
        for index in ["/index.html", "/index.htm", "/index.php"] where pathText.hasSuffix(index) {
            pathText.removeLast(index.count - 1)
        }
        while pathText.hasSuffix("/") { pathText.removeLast() }

        var out = hostText + pathText
        let kept = keptParameters(query)
        if !kept.isEmpty { out += "?" + kept.joined(separator: "&") }
        return out
    }

    /// Query parameters that identify content, sorted.
    static func keptParameters(_ query: Substring) -> [String] {
        guard !query.isEmpty else { return [] }
        var kept: [String] = []
        for part in query.split(separator: "&", omittingEmptySubsequences: true) {
            let name = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first.map { $0.lowercased() } ?? ""
            if isTracking(name) { continue }
            kept.append(String(part))
        }
        return kept.sorted()
    }

    static func isTracking(_ name: String) -> Bool {
        if name.hasPrefix("utm_") || name.hasPrefix("hsa_") || name.hasPrefix("pk_") || name.hasPrefix("mtm_") { return true }
        return trackingNames.contains(name)
    }

    static let trackingNames: Set<String> = [
        "fbclid", "gclid", "gclsrc", "dclid", "gbraid", "wbraid", "msclkid", "yclid", "twclid", "ttclid", "li_fat_id",
        "mc_cid", "mc_eid", "igshid", "igsh", "_ga", "_gl", "_hsenc", "_hsmi", "mkt_tok", "vero_id", "ref_src", "ref_url",
        "s_cid", "cmpid", "ncid", "spm", "scid", "oly_enc_id", "oly_anon_id", "__s", "rb_clickid",
    ]

    /// The address with tracking parameters removed, otherwise untouched.
    static func stripTracking(_ url: URL) -> URL {
        guard url.query != nil, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = parts.queryItems else { return url }
        let kept = items.filter { !isTracking($0.name.lowercased()) }
        guard kept.count != items.count else { return url }
        parts.queryItems = kept.isEmpty ? nil : kept
        return parts.url ?? url
    }

    /// Lowercase, no diacritics. Same folding as `BrowserStore.fold`, usable off the main actor.
    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// "https://www.example.com/a/b/?q=1" -> "example.com/a/b".
    static func display(_ url: URL) -> String {
        guard var host = url.host, !host.isEmpty else { return url.absoluteString }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        var path = url.path
        while path.hasSuffix("/") { path.removeLast() }
        return host + path
    }

    /// Host without "www.", lowercased. Empty for addresses without a host.
    static func host(_ url: URL) -> String {
        guard var host = url.host(percentEncoded: false)?.lowercased() else { return "" }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    /// True for the front page of a site: no path, no query.
    static func isRoot(_ canonical: String) -> Bool {
        !canonical.contains("/") && !canonical.contains("?")
    }
}
