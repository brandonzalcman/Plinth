import Foundation

/// What a page says about itself: the site name (`og:site_name` / `application-name`) and its
/// icon links. Both apps inject `collectorFunction` into their page scripts and read the message it
/// builds with the functions here.
public enum PageMeta {
    /// A JavaScript function declaration, `plinthCollectMeta()`, returning
    /// `{ url, siteName, icons: [{ href, rel, sizes, type }] }` for the current document (at most
    /// 24 http(s) icon links, in document order).
    public static let collectorFunction = """
    function plinthCollectMeta() {
      function metaContent(selector) {
        var el = document.querySelector(selector);
        var value = el && el.getAttribute('content');
        return value ? value.trim() : null;
      }
      var icons = [];
      var links = document.querySelectorAll('link[rel][href]');
      for (var i = 0; i < links.length && icons.length < 24; i++) {
        var rel = (links[i].getAttribute('rel') || '').toLowerCase();
        var tokens = rel.split(/\\s+/);
        if (tokens.indexOf('icon') < 0 && rel.indexOf('apple-touch-icon') < 0) { continue; }
        if (!links[i].href || links[i].href.indexOf('http') !== 0) { continue; }
        icons.push({ href: links[i].href, rel: rel,
                     sizes: links[i].getAttribute('sizes') || '', type: links[i].getAttribute('type') || '' });
      }
      return { url: location.href,
               siteName: metaContent('meta[property="og:site_name"]') || metaContent('meta[name="application-name"]'),
               icons: icons };
    }
    """

    /// False for a message from a document that has since been navigated away from (another host).
    public static func isCurrent(_ body: [String: Any], pageURL: URL) -> Bool {
        guard let sender = (body["url"] as? String).flatMap({ URL(string: $0) }) else { return false }
        return sender.host == pageURL.host
    }

    /// The trimmed site name, or nil when missing, empty or longer than 80 characters.
    public static func siteName(_ body: [String: Any]) -> String? {
        let hint = (body["siteName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return hint.flatMap { $0.isEmpty || $0.count > 80 ? nil : $0 }
    }

    /// The message's icon links, best first (`rankedIcons`).
    public static func iconCandidates(_ body: [String: Any]) -> [URL] {
        rankedIcons((body["icons"] as? [[String: Any]]) ?? [])
    }

    /// Orders icon links best first: the smallest one that is still at least 64 px, else the largest.
    public static func rankedIcons(_ icons: [[String: Any]]) -> [URL] {
        var scored: [(url: URL, size: Int)] = []
        for icon in icons {
            guard let href = icon["href"] as? String, let url = URL(string: href) else { continue }
            let rel = (icon["rel"] as? String ?? "").lowercased()
            let sizes = (icon["sizes"] as? String ?? "").lowercased()
            let type = (icon["type"] as? String ?? "").lowercased()
            var size = 0
            for token in sizes.split(separator: " ") {
                if token == "any" { size = max(size, 128); continue }
                let parts = token.split(separator: "x")
                if parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]) { size = max(size, min(w, h)) }
            }
            if size == 0 {
                if rel.contains("apple-touch-icon") { size = 180 }
                else if type.contains("svg") || url.pathExtension.lowercased() == "svg" { size = 128 }
                else if url.pathExtension.lowercased() == "ico" { size = 16 }
                else { size = 32 }
            }
            scored.append((url, size))
        }
        scored.sort { a, b in
            let aBig = a.size >= 64, bBig = b.size >= 64
            if aBig != bBig { return aBig }
            return aBig ? a.size < b.size : a.size > b.size
        }
        var seen = Set<URL>()
        return scored.compactMap { seen.insert($0.url).inserted ? $0.url : nil }
    }

    /// `/favicon.ico` at the page's origin (scheme, host and port), for http(s) pages.
    public static func originFavicon(for pageURL: URL) -> URL? {
        guard let scheme = pageURL.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = pageURL.host else { return nil }
        var origin = URLComponents()
        origin.scheme = scheme
        origin.host = host
        origin.port = pageURL.port
        origin.path = "/favicon.ico"
        return origin.url
    }

    /// The candidates to try in order: the http(s) icon links, then the origin's `/favicon.ico`.
    public static func fetchOrder(candidates: [URL], pageURL: URL) -> [URL] {
        var urls = candidates.filter { ["http", "https"].contains($0.scheme?.lowercased() ?? "") }
        if let fallback = originFavicon(for: pageURL), !urls.contains(fallback) { urls.append(fallback) }
        return urls
    }
}
