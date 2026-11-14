import AppKit
import WebKit
import PlinthModel
import PlinthRules
import PlinthSettings
import PlinthWeb
import PlinthBarUI
import PlinthLoyalty

/// Test-launch hook: `PLINTH_STEPS="wait 3; peek http://…; wait 4; promote; …"` drives features
/// through the same entry points the UI uses, logging to stdout. Inactive unless the variable is set.
@MainActor
enum DebugScript {
    static func runIfRequested(_ app: AppController) {
        guard let script = ProcessInfo.processInfo.environment["PLINTH_STEPS"] else { return }
        let steps = script.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        Task { @MainActor in
            for step in steps {
                let parts = step.split(separator: " ", maxSplits: 1).map(String.init)
                let arg = parts.count > 1 ? parts[1] : ""
                log("step: \(step)")
                await run(parts[0], arg, app)
            }
            log("done")
        }
    }

    static func log(_ text: String) { print("[steps] \(text)"); fflush(stdout) }

    private static func js(_ app: AppController, _ source: String) async {
        guard let id = app.keyWindowID, let page = app.store.window(id)?.selectedPageID,
              let view = app.pool.existingWebView(for: page) else { return }
        _ = try? await view.evaluateJavaScript(source)
    }

    private static func menuItemInfo(_ title: String) -> String {
        guard let main = NSApp.mainMenu else { return "no main menu" }
        for top in main.items {
            guard let sub = top.submenu else { continue }
            sub.update()
            if let item = sub.items.first(where: { $0.title == title }) {
                let key = item.keyEquivalent == "\r" ? "return" : item.keyEquivalent
                return "menuitem '\(title)': enabled=\(item.isEnabled) key='\(key)' mask=\(item.keyEquivalentModifierMask.rawValue) keyWindow='\(NSApp.keyWindow?.title ?? "nil")'"
            }
        }
        return "menuitem '\(title)': not found"
    }

    private static func sendKey(_ spec: String) {
        var flags: NSEvent.ModifierFlags = []
        var key = ""
        for part in spec.split(separator: "+").map(String.init) {
            switch part {
            case "cmd": flags.insert(.command)
            case "shift": flags.insert(.shift)
            case "opt", "alt": flags.insert(.option)
            case "ctrl": flags.insert(.control)
            default: key = part
            }
        }
        let codes: [String: UInt16] = ["return": 36, "j": 38, "k": 40, "l": 37, "t": 17, "w": 13, "f": 3, "e": 14, "p": 35, "d": 2, "b": 11, "y": 16]
        let chars = key == "return" ? "\r" : key
        // A scripted run may not be frontmost, so there may be no key window.
        guard let window = NSApp.keyWindow ?? AppController.shared?.keyController?.window else { log("key: no key window"); return }
        let typed = flags.contains(.shift) && key != "return" ? chars.uppercased() : chars
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, characters: typed,
                                           charactersIgnoringModifiers: chars, isARepeat: false, keyCode: codes[key] ?? 0) else { return }
        let handled = NSApp.mainMenu?.performKeyEquivalent(with: event) ?? false
        log("key \(spec): mainMenu.performKeyEquivalent=\(handled) keyWindow='\(window.title)'")
    }

    /// contextmenu <element id> [<menu item title to invoke>]: a real right-click on the element in
    /// the selected page; logs the web view's actual menu and invokes the named item.
    private static func contextMenu(_ arg: String, _ app: AppController) async {
        let parts = arg.split(separator: " ", maxSplits: 1).map(String.init)
        guard let wid = app.keyWindowID, let page = app.store.window(wid)?.selectedPageID, let view = app.pool.existingWebView(for: page),
              let window = view.window, let id = parts.first,
              let rect = try? await view.evaluateJavaScript("(()=>{const e=document.getElementById('\(id)');e.scrollIntoView({block:'center'});const r=e.getBoundingClientRect();return [r.left+r.width/2, r.top+r.height/2]})()") as? [Double]
        else { log("contextmenu: no element"); return }
        let want = parts.count > 1 ? parts[1] : nil
        PlinthWebView.menuObserver = { menu in
            log("context menu: " + menu.items.map { $0.isSeparatorItem ? "--" : $0.title }.joined(separator: " | "))
            nonisolated(unsafe) let menu = menu
            let timer = Timer(timeInterval: 0.7, repeats: false) { _ in
                MainActor.assumeIsolated {
                    if let want, let index = menu.items.firstIndex(where: { $0.title == want }) {
                        log("invoking '\(want)' enabled=\(menu.items[index].isEnabled)")
                        menu.performActionForItem(at: index)
                    }
                    menu.cancelTracking()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
        }
        let point = view.convert(NSPoint(x: rect[0] * view.pageZoom, y: rect[1] * view.pageZoom + view.obscuredContentInsets.top), to: nil)
        if let event = NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
            window.sendEvent(event) // WebKit builds and pops up the menu asynchronously
        }
        try? await Task.sleep(for: .seconds(3)) // the observer above acts when the menu appears
    }

    private static func run(_ verb: String, _ arg: String, _ app: AppController) async {
        let controller = app.keyController
        let wid = app.keyWindowID
        switch verb {
        case "wait": try? await Task.sleep(for: .seconds(Double(arg) ?? 1))
        case "open": if let wid, let url = URL(string: arg) { app.store.openPage(url: url, in: wid) }
        case "select":
            if let wid, let n = Int(arg) { app.store.selectByShortcut(n, in: wid) }
        case "peek": if let url = URL(string: arg) { controller?.showPeek(url) }
        case "promote": controller?.promotePeek()
        case "closepeek": controller?.closePeek()
        case "ask":
            controller?.openAsk()
            if !arg.isEmpty { controller?.ask(arg) }
        case "askscope": controller?.chrome.askScope = AskScope(rawValue: arg) ?? .page
        case "dismiss": controller?.dismissPanel()
        case "shelve": app.menuPutAway(nil)
        case "restore":
            if let entry = app.store.shelf.first, let page = entry.pages.first {
                controller?.submit(.result(SearchResult(id: "x", target: .shelf(entry: entry.id, page: page.id),
                                                        title: page.name, subtitle: "", key: entry.key)))
            }
        case "splitnext": app.menuSplitWithNext(nil)
        case "endsplit": app.menuEndSplit(nil)
        case "fraction": if let wid, let f = Double(arg) { app.store.setSplitFraction(f, in: wid) }
        case "coopen": for _ in 0..<(Int(arg) ?? 25) { app.store.noteCoOpen(seconds: 60) }
        case "acceptgroup":
            if let wid, let s = app.store.groupSuggestion(for: wid) { app.store.showGroup(app.store.acceptSuggestion(s), in: wid) }
        case "unfocus": if let wid { app.store.setFocus(nil, in: wid) }
        case "pin": app.menuPinSite(nil)
        case "selectpin": if let wid, let pin = app.store.pins.first { app.handle(.selectPin(pin.id), in: wid) }
        case "js": await js(app, arg)
        case "uiclick", "uiset":
            // uiclick <id or ?css-selector without spaces> | uiset <same> <text>: scripted pointer events / typing on the element (also inside shadow roots),
            // for pages where a real click cannot reach (an inactive window). Only the password test mode counts these as input.
            let parts = arg.split(separator: " ", maxSplits: 1).map(String.init)
            let find = "const find=(root)=>{const sel='\(parts[0])'.startsWith('?')?'\(parts[0])'.slice(1):'#'+'\(parts[0])';const hit=root.querySelector(sel);if(hit)return hit;for(const h of root.querySelectorAll('*')){if(h.shadowRoot){const x=find(h.shadowRoot);if(x)return x}if(h.tagName==='IFRAME'){try{const d=h.contentDocument;if(d){const x=find(d);if(x)return x}}catch(_){}}}return null};const e=find(document);if(!e)return 'no element';const W=e.ownerDocument.defaultView;"
            let body: String
            if verb == "uiclick" {
                body = "for(const t of ['pointerdown','mousedown']){e.dispatchEvent(new W.MouseEvent(t,{bubbles:true,composed:true,cancelable:true}))};if(e.focus)e.focus();for(const t of ['pointerup','mouseup']){e.dispatchEvent(new W.MouseEvent(t,{bubbles:true,composed:true,cancelable:true}))};e.click();return 'clicked'"
            } else {
                let text = (parts.count > 1 ? parts[1] : "").replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
                body = "e.focus();const set=Object.getOwnPropertyDescriptor(W.HTMLInputElement.prototype,'value').set;set.call(e,'\(text)');e.dispatchEvent(new W.Event('input',{bubbles:true,composed:true}));e.dispatchEvent(new W.Event('change',{bubbles:true}));return 'set'"
            }
            if let id = app.keyWindowID, let page = app.store.window(id)?.selectedPageID, let view = app.pool.existingWebView(for: page) {
                let result = try? await view.evaluateJavaScript("(()=>{\(find)\(body)})()")
                if let r = result as? String, r == "no element" { log("\(verb): no element \(parts[0])") }
            }
        case "fx": await app.passwords?.debugFrame(arg)
        case "activate":
            // Makes the app and its window key, so the real clicks that follow reach the page.
            NSApp.activate(ignoringOtherApps: true)
            controller?.window.makeKeyAndOrderFront(nil)
        case "jslog":
            // jslog <expression>: logs the expression's value in the selected page (print lengths, never secrets).
            if let id = app.keyWindowID, let page = app.store.window(id)?.selectedPageID, let view = app.pool.existingWebView(for: page) {
                let value = try? await view.evaluateJavaScript(arg)
                log("jslog: \(value.map { String(describing: $0) } ?? "nil")")
            }
        case "shiftclick":
            await js(app, "document.getElementById('\(arg)').dispatchEvent(new MouseEvent('click', {bubbles:true, cancelable:true, shiftKey:true}))")
        case "meaning":
            let raw = await app.ai.semanticSearch(arg, limit: 8)
            log("raw '\(arg)': " + raw.map { "\($0.title)=\(String(format: "%.2f", $0.score))" }.joined(separator: ", "))
            let results = await app.semanticResults(for: arg)
            log("meaning '\(arg)': " + results.map { "\($0.title) [\($0.byMeaning)]" }.joined(separator: " | "))
            log("indexed so far: \(app.indexedHistory.count)")
        case "dwell":
            // Pretend the visible pages have been read for a while, then index them.
            if let wid, let w = app.store.window(wid) {
                for page in w.visiblePageIDs { app.store.recordDwell(page, seconds: Double(arg) ?? 40); app.indexForMeaningIfNeeded(page) }
            }
        case "state":
            if let wid, let w = app.store.window(wid) {
                let sites = app.store.visibleSites(in: wid).map { "\($0.name)(\($0.pages.map(\.name).joined(separator: ",")))" }
                log("visible: \(sites) split: \(w.split != nil) focus: \(w.focusedGroup != nil) pins: \(app.store.pins.map { "\($0.name)@\($0.page.url.path)" }) shelf: \(app.store.shelf.map(\.name)) groups: \(app.store.groups.map(\.name)) downloads: \(app.pool.downloads.items.map { "\($0.filename) \($0.state)" }) ai: \(app.ai.availability) minis: \(app.miniWindows.count)")
                if let c = controller { log("resume card: \(String(describing: c.chrome.resumeCard?.summary)) ask: \(c.chrome.askAnswer.prefix(300)) msg: \(c.chrome.askMessage ?? "-")") }
            }
        case "nsclick":
            // nsclick <element id> [shift]: a real mouse click on the element, through AppKit.
            let parts = arg.split(separator: " ").map(String.init)
            guard let wid, let page = app.store.window(wid)?.selectedPageID, let view = app.pool.existingWebView(for: page),
                  let window = view.window,
                  let rect = try? await view.evaluateJavaScript("(()=>{const find=(root)=>{const hit=root.getElementById?root.getElementById('\(parts[0])'):root.querySelector('#\(parts[0])');if(hit)return hit;for(const h of root.querySelectorAll('*')){if(h.shadowRoot){const x=find(h.shadowRoot);if(x)return x}}return null};const e=find(document);e.scrollIntoView({block:'center'});const r=e.getBoundingClientRect();return [r.left+r.width/2, r.top+r.height/2]})()") as? [Double]
            else { log("nsclick: no element"); return }
            let zoom = view.pageZoom
            let inView = NSPoint(x: rect[0] * zoom, y: rect[1] * zoom + view.obscuredContentInsets.top)
            let point = view.convert(inView, to: nil)
            let flags: NSEvent.ModifierFlags = parts.contains("shift") ? [.shift] : []
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                    window.sendEvent(event)
                }
                try? await Task.sleep(for: .milliseconds(60))
            }
        case "mouse":
            // mouse <down|drag|up|double> <x> <y-from-top> in window points.
            let p = arg.split(separator: " ").map(String.init)
            guard let window = controller?.window, p.count == 3, let x = Double(p[1]), let y = Double(p[2]) else { return }
            let point = NSPoint(x: x, y: window.contentView!.bounds.height - y)
            let kinds: [(NSEvent.EventType, Int)] = switch p[0] {
                case "down": [(.leftMouseDown, 1)]
                case "drag": [(.leftMouseDragged, 1)]
                case "up": [(.leftMouseUp, 1)]
                default: [(.leftMouseDown, 1), (.leftMouseUp, 1), (.leftMouseDown, 2), (.leftMouseUp, 2)]
            }
            for (type, count) in kinds {
                if let e = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: count, pressure: 1) {
                    window.sendEvent(e)
                }
            }
        case "key":
            // key <cmd+shift+return|cmd+j|…>: a real key-down through the main menu's key-equivalent path.
            sendKey(arg)
        case "type":
            // type <text>: inserts the text into the key window's first responder, one character at a
            // time (the command bar / shelf search field), so text-change handling really runs.
            guard let window = NSApp.keyWindow ?? app.keyController?.window else { log("type: no window"); return }
            guard let client = window.firstResponder as? NSTextInputClient else { log("type: no text field focused"); return }
            for ch in arg {
                client.insertText(String(ch), replacementRange: NSRange(location: NSNotFound, length: 0))
                try? await Task.sleep(for: .milliseconds(30))
            }
        case "menuitem":
            // menuitem <title>: logs whether the main-menu item exists, is enabled, its key equivalent.
            log(menuItemInfo(arg))
        case "contextmenu":
            await contextMenu(arg, app)
        case "frame":
            if let w = controller?.window { log("frame: \(w.frame) split fraction: \(String(describing: wid.flatMap { app.store.window($0)?.split?.fraction })) bar hidden: \(controller?.barHost.isHidden ?? false)") }
        case "newprivate": app.newPrivateWindow(); app.lastMainWindowID = app.store.windows.last?.id
        case "newwindow": app.newWindow(); app.lastMainWindowID = app.store.windows.last?.id
        // focus <index in store.windows>: later steps act on that window (a test launch may have no key window).
        case "focus": if let n = Int(arg), app.store.windows.indices.contains(n) { app.lastMainWindowID = app.store.windows[n].id }
        case "closewin": app.keyController?.window.performClose(nil)
        case "windows":
            log("windows: \(app.store.windows.map { "\($0.isPrivate ? "private" : "normal"):\($0.sites.map(\.key.host).joined(separator: ","))" }) history: \(app.store.history.map { $0.url.host ?? "-" }) shelf: \(app.store.shelf.map(\.name)) downloads: \(app.pool.downloads.items.map(\.filename))")
        case "cookies":
            // The cookie names the key window's current page's data store holds, for any host.
            if let wid, let page = app.store.window(wid)?.selectedPageID, let view = app.pool.existingWebView(for: page) {
                let all = await view.configuration.websiteDataStore.httpCookieStore.allCookies()
                // Only the test sites' cookies are listed: the default store is the real profile's.
                let mine = all.filter { $0.domain.contains("example.") || $0.domain.contains("iana.org") }
                log("cookies (\(view.configuration.websiteDataStore.isPersistent ? "persistent" : "private")): \(mine.map { "\($0.domain) \($0.name)" })")
            }
        case "promotemini": if let mini = app.miniWindows.last { app.promote(mini) }
        case "toggleai": app.menuToggleAI(nil)
        case "shelf": controller?.toggleShelf()
        case "history": controller?.toggleHistory()
        case "bookmarks": controller?.toggleBookmarks()
        case "bmfolder": app.bookmarks.addFolder(named: arg)
        case "bmmove":
            // bmmove <folder name>: the first top-level bookmark goes into that folder.
            if let folder = app.bookmarks.folders.first(where: { $0.name == arg }), let mark = app.bookmarks.bookmarks(in: nil).first {
                app.bookmarks.move(mark.id, to: folder.id)
            }
        case "bmrename": if let mark = app.bookmarks.bookmarks.first { app.bookmarks.rename(mark.id, to: arg) }
        case "bmstate": log("bookmarks: \(app.bookmarks.bookmarks.map { "\($0.title)@\(app.bookmarks.path(of: $0.folder))" }) folders: \(app.bookmarks.folders.map(\.name))")
        case "downloads": controller?.toggleDownloads()
        case "clearshelf": app.clearShelf()
        case "undoshelf": app.undoClearShelf()
        case "benchlayout":
            // benchlayout <sites> <pagesPerSite>: times the bar layout engine with the real text measurer.
            let p = arg.split(separator: " ").compactMap { Int($0) }
            let n = p.first ?? 60, per = p.count > 1 ? p[1] : 3
            let t0 = Date()
            let sites = (0..<n).map { i in
                Site(key: SiteKey("site\(i).example.com"), name: "Site number \(i)",
                     pages: (0..<per).map { j in
                         Page(url: URL(string: "https://site\(i).example.com/page\(j)")!, name: "Some page title \(i)-\(j)",
                              usage: Usage(at: t0.addingTimeInterval(Double(i * 10 + j))))
                     })
            }
            let input = BarInput(pins: [], sites: sites, selected: sites.first?.pages.first?.id, split: nil)
            var widths: [CGFloat] = []
            for w in stride(from: 900.0, through: 1500.0, by: 5.0) { widths.append(w) }
            let clock = ContinuousClock()
            var samples: [Double] = []
            for _ in 0..<5 {
                let d = clock.measure { for w in widths { _ = app.layoutEngine.layout(input, barWidth: w, metrics: .standard, measure: BarTextMeasurer.width) } }
                samples.append(Double(d.components.attoseconds) / 1e15 + Double(d.components.seconds) * 1000)
            }
            let per1 = samples.min()! / Double(widths.count)
            log("benchlayout \(n) sites x \(per) pages: \(String(format: "%.3f", per1)) ms per layout (best of 5 sweeps of \(widths.count) widths)")
        case "refreshstats":
            if let c = controller { log("refreshContent calls: \(c.refreshStats.count) total \(String(format: "%.1f", c.refreshStats.seconds * 1000)) ms") }
        case "benchdrag":
            // benchdrag: with a split on screen, drags the divider across the page in 150 events.
            guard let c = controller, let wid, let fraction = app.store.window(wid)?.split?.fraction else { log("benchdrag: no split"); return }
            let height = c.window.contentView!.bounds.height, width = c.window.contentView!.bounds.width
            let startX = width * fraction
            func send(_ type: NSEvent.EventType, _ x: Double) {
                if let e = NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: height / 2), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: c.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { c.window.sendEvent(e) }
            }
            log("benchdrag: startX \(startX) hit: \(String(describing: c.window.contentView?.hitTest(NSPoint(x: startX, y: height / 2)))) key: \(c.window.isKeyWindow)")
            c.window.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .milliseconds(300))
            c.refreshStats = (0, 0)
            let clock = ContinuousClock()
            let began = clock.now
            send(.leftMouseDown, startX)
            for i in 1...150 {
                send(.leftMouseDragged, startX + 120 * sin(Double(i) / 150 * .pi * 2) + 150 * Double(i) / 150)
                try? await Task.sleep(for: .milliseconds(8))   // ~120 Hz mouse
            }
            send(.leftMouseUp, startX)
            let t = clock.now - began
            try? await Task.sleep(for: .milliseconds(500))
            log("benchdrag: 150 drag events sent in \(t); refreshContent calls: \(c.refreshStats.count) total \(String(format: "%.1f", c.refreshStats.seconds * 1000)) ms; fraction now \(app.store.window(wid)?.split?.fraction ?? -1)")
        case "benchsnap":
            // benchsnap: cost of the shelf's per-group "does any page have a thumbnail" check, old way vs new.
            let dir = app.storageDirectory.appendingPathComponent("snapshots")
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            let clock = ContinuousClock()
            func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }
            let old = clock.measure { for f in files { if let i = NSImage(contentsOf: f), i.isValid { _ = i.size } } }
            let new = clock.measure { for f in files { _ = FileManager.default.fileExists(atPath: f.path) } }
            log("benchsnap: \(files.count) snapshots: load \(String(format: "%.2f", ms(old))) ms vs exists-check \(String(format: "%.3f", ms(new))) ms")
        case "cleardownloads": app.pool.clearFinishedDownloads()
        case "mini": if let url = URL(string: arg) { app.openFromOtherApp(url) }
        case "command":
            controller?.chrome.panel = .command(text: arg, newPage: true)
            controller?.syncPanel()
        case "size":
            let p = arg.split(separator: " ").compactMap { Double($0) }
            if let window = controller?.window, p.count == 2 {
                window.setFrame(NSRect(x: 120, y: 80, width: p[0], height: p[1]), display: true)
            }
        case "minisize":
            let p = arg.split(separator: " ").compactMap { Double($0) }
            if let window = app.miniWindows.last?.window, p.count == 2 {
                window.setFrame(NSRect(x: 200, y: 120, width: p[0], height: p[1]), display: true)
            }
        case "scroll": await js(app, "window.scrollTo(0, \(Double(arg) ?? 0))")
        case "clickcurrent": if let wid, let page = app.store.window(wid)?.selectedPageID { app.handle(.selectPage(page), in: wid) }
        case "closepage": if let wid, let page = app.store.window(wid)?.selectedPageID { app.store.closePage(page) }
        case "reopen": app.menuReopen(nil)
        case "welcome":
            // welcome [card index]: replays the welcome guide, from the intro or at that card.
            app.showWelcomeGuide(startingAtCard: Int(arg))
        case "pw": app.passwords.debug(arg)
        case "sharecard":
            // sharecard <path>: writes the share card PNG for the current level.
            let t = app.loyalty.totals
            let way = LoyaltyColourway.named(app.settings.value.appIcon) ?? .sunrise
            let data = ShareCard.pngData(ShareCardContent(level: t.level, points: t.points, streak: t.streak, colourway: way))
            try? data?.write(to: URL(fileURLWithPath: arg))
            log("sharecard \(data?.count ?? 0) bytes")
        case "loyaltypoints":
            // loyaltypoints <n>: adds n points from a made-up second device (past days), to see levels and level-ups.
            let days = max(Int(arg) ?? 0, 0) / 10
            var awards: [String: Int] = [:]
            for i in 0..<days { awards[String(format: "day:2025-%02d-%02d", i / 28 + 1, i % 28 + 1)] = 10 }
            log("active=\(NSApp.isActive) welcome=\(app.welcome?.window?.isVisible == true)")
            app.loyalty.ingest([PlinthLoyalty.LoyaltyLedger(deviceID: "debug", platform: .mac, awards: awards).encoded()])
        case "settings":
            // settings <section id>: opens the Settings window on that section.
            app.menuSettings(nil)
            app.settingsWindow?.select(section: arg)
        case "set":
            // set <field> <value>: changes a setting through the store, like the Settings window does.
            let p = arg.split(separator: " ", maxSplits: 1).map(String.init)
            let v = p.count > 1 ? p[1] : ""
            app.settings.update { s in
                switch p.first ?? "" {
                case "engine": s.searchEngine.kind = SearchEngine.Kind(rawValue: v) ?? .duckDuckGo
                case "appearance": s.appearance = AppearanceChoice(rawValue: v) ?? .system
                case "accent": s.accent = AccentChoice(rawValue: v) ?? .blue
                case "fade": s.fadeBehavior = FadeBehavior(rawValue: v) ?? .standard
                case "zoom": s.defaultZoom = Double(v) ?? 1
                case "blocker": s.contentBlockerEnabled = v == "on"
                case "https": s.httpsOnly = v == "on"
                case "gpc": s.globalPrivacyControl = v == "on"
                default: log("unknown setting \(p.first ?? "")")
                }
            }
            log("search url for 'plinth test': \(app.resolver.searchURL(for: "plinth test"))")
        case "settingsshot":
            guard let window = app.settingsWindow?.window, let dir = ProcessInfo.processInfo.environment["PLINTH_SHOTS"] else { return }
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            task.arguments = ["-l", "\(window.windowNumber)", "-o", "\(dir)/\(arg).png"]
            try? task.run()
            task.waitUntilExit()
        case "shot":
            // shot <name> [mini|welcome|settings]: captures the key main window (or the newest mini, welcome or settings window).
            let parts = arg.split(separator: " ")
            let window: NSWindow? = switch parts.count > 1 ? parts[1] : "" {
            case "mini": app.miniWindows.last?.window
            case "welcome": app.welcome?.window
            case "settings": app.settingsWindow?.window
            default: controller?.window
            }
            guard let window, let dir = ProcessInfo.processInfo.environment["PLINTH_SHOTS"] else { return }
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            task.arguments = ["-l", "\(window.windowNumber)", "-o", "\(dir)/\(parts.first ?? "shot").png"]
            try? task.run()
            task.waitUntilExit()
        case "folder":
            // folder <n,n,...> [name]: puts the pins at these 1-based positions into one new folder.
            let parts = arg.split(separator: " ", maxSplits: 1).map(String.init)
            let ids = (parts.first ?? "").split(separator: ",").compactMap { Int($0) }.compactMap { n in
                app.store.pins.indices.contains(n - 1) ? app.store.pins[n - 1].id : nil
            }
            guard let first = ids.first, let folder = app.store.createPinFolder(with: first, name: parts.count > 1 ? parts[1] : nil) else { return }
            for id in ids.dropFirst() { app.store.movePin(id, toFolder: folder.id) }
        case "fullshot":
            // fullshot <name>: the whole screen, so popovers show.
            guard let dir = ProcessInfo.processInfo.environment["PLINTH_SHOTS"] else { return }
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            task.arguments = ["-x", "\(dir)/\(arg).png"]
            try? task.run()
            task.waitUntilExit()
        default: log("unknown step \(verb)")
        }
    }
}
