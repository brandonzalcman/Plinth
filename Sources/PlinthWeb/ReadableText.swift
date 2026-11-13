import Foundation
import WebKit
import PlinthModel

extension WebViewPool {
    /// Pages cannot see or interfere with this world's globals.
    private static let readerWorld = WKContentWorld.world(name: "PlinthReader")
    static let focusExcerptLength = 1_200

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
        let limit = max(0, limit)
        let raw: Any?
        do {
            raw = try await webView.callAsyncJavaScript(ReaderScript.source,
                                                        arguments: ["limit": limit, "focusLength": Self.focusExcerptLength],
                                                        in: nil, contentWorld: Self.readerWorld)
        } catch {
            log.info("Readable text failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        guard let body = raw as? [String: Any] else { return nil }
        // The page moved on while the script ran.
        guard let current = webView.url, current == pageURL else { return nil }

        let text = String(((body["text"] as? String) ?? "").prefix(limit))
        let focus = (body["focus"] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(Self.focusExcerptLength + 200)) }
        let title = ((body["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? webView.title) ?? ""
        let fraction = (body["scrollFraction"] as? NSNumber)?.doubleValue
        return PageText(url: pageURL, title: title, text: text, focusExcerpt: focus,
                        scrollFraction: fraction.map { min(max($0, 0), 1) }, extractedAt: Date())
    }
}

enum ReaderScript {
    /// Body of an async function; `limit` and `focusLength` are its arguments.
    static let source = """
    const DROP = 'nav,header,footer,aside,script,style,noscript,template,svg,canvas,iframe,object,embed,' +
      'select,button,dialog:not([open]),[hidden],[aria-hidden="true"],[role="navigation"],[role="banner"],' +
      '[role="contentinfo"],[role="complementary"],[role="dialog"]';
    const BLOCK = /^(P|DIV|LI|UL|OL|H[1-6]|BLOCKQUOTE|PRE|SECTION|ARTICLE|MAIN|TR|TD|TH|TABLE|DD|DT|DL|FIGURE|FIGCAPTION|ADDRESS|DETAILS|SUMMARY|BODY)$/;
    const MAX_SCAN = Math.max(limit * 4, 400000);

    function size(el) { return (el.textContent || '').length; }
    function pickRoot() {
      let best = null, bestSize = 0;
      for (const a of document.querySelectorAll('article')) {
        const n = size(a);
        if (n > bestSize) { best = a; bestSize = n; }
      }
      if (best && bestSize >= 200) { return best; }
      for (const selector of ['main', '[role="main"]']) {
        const el = document.querySelector(selector);
        if (el && (el.textContent || '').trim().length >= 200) { return el; }
      }
      return document.body || document.documentElement;
    }
    function hidden(el) {
      if (el.checkVisibility) { return !el.checkVisibility({ visibilityProperty: true }); }
      const style = getComputedStyle(el);
      return style.display === 'none' || style.visibility === 'hidden';
    }

    const root = pickRoot();
    if (!root) { return { title: document.title, text: '', focus: null, scrollFraction: null }; }

    const walker = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT, {
      acceptNode(node) {
        if (node.nodeType === Node.ELEMENT_NODE) {
          if (node !== root && (node.matches(DROP) || hidden(node))) { return NodeFilter.FILTER_REJECT; }
          return NodeFilter.FILTER_SKIP;
        }
        return NodeFilter.FILTER_ACCEPT;
      }
    });

    function blockOf(node) {
      let el = node.parentElement;
      while (el && el !== root && !BLOCK.test(el.tagName)) { el = el.parentElement; }
      return el || root;
    }

    const blocks = [];
    let current = null, scanned = 0;
    for (let node = walker.nextNode(); node && scanned < MAX_SCAN; node = walker.nextNode()) {
      const value = node.nodeValue || '';
      if (!value) { continue; }
      const block = blockOf(node);
      if (current && current.el === block) {
        current.parts.push(value);
      } else {
        current = { el: block, parts: [value] };
        blocks.push(current);
      }
      scanned += value.length;
    }

    const items = [];
    for (const block of blocks) {
      const text = block.parts.join('').replace(/\\s+/g, ' ').trim();
      if (text) { items.push({ el: block.el, text }); }
    }

    let text = '';
    for (const item of items) {
      if (text.length >= limit) { break; }
      text += (text ? '\\n' : '') + item.text;
    }
    if (text.length > limit) { text = text.slice(0, limit); }

    // The block nearest the middle of the viewport, then its neighbours, up to focusLength.
    const viewHeight = window.innerHeight || document.documentElement.clientHeight || 0;
    const middle = viewHeight / 2;
    const rects = new Map();
    let nearest = -1, nearestDistance = Infinity;
    for (let i = 0; i < items.length; i++) {
      const el = items[i].el;
      let rect = rects.get(el);
      if (!rect) { rect = el.getBoundingClientRect(); rects.set(el, rect); }
      if (rect.width === 0 && rect.height === 0) { continue; }
      const distance = rect.bottom < middle ? middle - rect.bottom : (rect.top > middle ? rect.top - middle : 0);
      if (distance < nearestDistance) { nearest = i; nearestDistance = distance; }
      if (distance === 0) { break; }
    }
    let focus = null;
    if (nearest >= 0) {
      let low = nearest, high = nearest, length = items[nearest].text.length;
      while (length < focusLength && (low > 0 || high < items.length - 1)) {
        if (high < items.length - 1) { high++; length += items[high].text.length + 1; }
        if (length < focusLength && low > 0) { low--; length += items[low].text.length + 1; }
      }
      focus = items.slice(low, high + 1).map(item => item.text).join('\\n');
      if (focus.length > focusLength) {
        // Keep the part centred on the nearest block.
        const before = items.slice(low, nearest).reduce((sum, item) => sum + item.text.length + 1, 0);
        const start = Math.max(0, Math.min(before - Math.floor((focusLength - items[nearest].text.length) / 2),
                                           focus.length - focusLength));
        focus = focus.slice(start, start + focusLength);
      }
    }

    const scroller = document.scrollingElement || document.documentElement;
    const scrollable = Math.max(0, (scroller ? scroller.scrollHeight : 0) - viewHeight);
    const scrollFraction = scrollable > 0 ? Math.min(1, Math.max(0, window.scrollY / scrollable)) : 0;

    return { title: document.title, text, focus, scrollFraction };
    """
}
