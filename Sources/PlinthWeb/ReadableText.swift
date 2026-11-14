import Foundation
import WebKit
import PlinthModel
import PlinthReader

extension WebViewPool {
    /// Pages cannot see or interfere with this world's globals.
    private static let readerWorld = WKContentWorld.world(name: "PlinthReader")
    static let focusExcerptLength = ReaderScript.focusExcerptLength

    /// The page's readable text (article/main content, chrome dropped, whitespace collapsed,
    /// at most `limit` characters), the text around the current viewport and how far down the
    /// reader is. nil when the page has no live view, is not an http/https/file page, or the
    /// script fails.
    public func readableText(for id: PageID, limit: Int = 20_000) async -> PageText? {
        guard let webView = entries[id]?.webView else { return nil }
        return await readableText(of: webView, limit: limit)
    }

    /// The same for any view, auxiliary ones included.
    public func readableText(of webView: WKWebView, limit: Int = 20_000) async -> PageText? {
        guard let pageURL = webView.url, WebViewPool.reportedSchemes.contains(pageURL.scheme?.lowercased() ?? "") else { return nil }
        let raw: Any?
        do {
            raw = try await webView.callAsyncJavaScript(ReaderScript.source, arguments: ReaderScript.arguments(limit: limit),
                                                        in: nil, contentWorld: Self.readerWorld)
        } catch {
            log.info("Readable text failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        // The page moved on while the script ran.
        guard let current = webView.url, current == pageURL else { return nil }
        return ReaderScript.pageText(from: raw, pageURL: pageURL, fallbackTitle: webView.title, limit: limit)
    }
}
