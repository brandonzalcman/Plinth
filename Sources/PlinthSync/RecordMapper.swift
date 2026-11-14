import Foundation
import PlinthModel

/// Converts between the synced part of the store (`SyncPayload`, open pages) and records.
///
/// Record layout (one record type each; names are unique across types):
/// - `Pin` "pin-<host>": key, name, homeURL, order. One pin per site key. A pin page's live state
///   (current URL, scroll, usage, dwell) is never synced.
/// - `PinFolder` "folder-<uuid>": folderID, name, nameEditedAt, members (the pin site keys, sorted).
///   Folder membership lives only here, so a pin's `order` changing never touches it, and the pins'
///   own order decides how members sit on the bar. 0.2.0 clients do not know the type and leave it
///   alone.
/// - `ShelfPage` "shelf-<page uuid>": pageID, key, siteName, url, rawTitle, name, customName?,
///   shelvedAt, lastUsed. Regrouped into one `ShelfEntry` per key when read back.
/// - `HistoryEntry` "history-<uuid>": entryID, url, title, name, key, visitedAt, dwell.
/// - `HistoryClear` "history-clear": clearedAt. Every history entry visited at or before it is gone.
/// - `Device` "device-<device id>": deviceID, deviceName, pages (JSON `[OpenPageSummary]`).
public enum RecordMapper {
    public static let pinType = "Pin"
    public static let folderType = "PinFolder"
    public static let shelfType = "ShelfPage"
    public static let historyType = "HistoryEntry"
    public static let clearType = "HistoryClear"
    public static let deviceType = "Device"

    public static let clearName = "history-clear"

    /// Every field each record type can carry. The CloudKit transport clears fields that a new
    /// version leaves out (CloudKit otherwise keeps a key the save does not mention).
    public static let fieldKeys: [String: [String]] = [
        pinType: ["key", "name", "homeURL", "order"],
        folderType: ["folderID", "name", "nameEditedAt", "members"],
        shelfType: ["pageID", "key", "siteName", "url", "rawTitle", "name", "customName", "shelvedAt", "lastUsed"],
        historyType: ["entryID", "url", "title", "name", "key", "visitedAt", "dwell"],
        clearType: ["clearedAt"],
        deviceType: ["deviceID", "deviceName", "pages"],
    ]

    /// Record types the engine merges with last-writer-wins and tracks as local state.
    static func isMergedType(_ type: String) -> Bool { type == pinType || type == shelfType || type == folderType }

    /// Fields an earlier build wrote that no version defines now. They are ignored on read and the
    /// transport clears them, but only on a record that was fetched carrying them (`SyncRecord.clearKeys`).
    public static let legacyKeys: [String: [String]] = [pinType: ["folderID", "folderName"]]

    /// The record carries a field only an earlier build wrote (see `legacyKeys`).
    static func legacyKeysPresent(in r: SyncRecord) -> [String] {
        guard !r.isTombstone else { return [] }
        return (legacyKeys[r.recordType] ?? []).filter { r.fields[$0] != nil }
    }

    /// The record without fields its type does not define: leftovers from other versions are not
    /// part of the content, so they never make a record look edited.
    static func known(_ r: SyncRecord) -> SyncRecord {
        guard let keys = fieldKeys[r.recordType], !r.isTombstone else { return r }
        var r = r
        r.fields = r.fields.filter { keys.contains($0.key) }
        return r
    }

    /// Three-way merge of a folder record edited on two Macs: members merge per member (a member
    /// added or removed on one side survives the other side's edits to other members), the name
    /// takes whichever side changed it (the later edit if both did). A tombstone counts as removing
    /// every member the base had. `nil` when nothing is left, i.e. the folder is gone.
    static func mergeFolder(base: SyncRecord?, local: SyncRecord, server: SyncRecord) -> SyncRecord? {
        func members(_ r: SyncRecord?) -> [String] { r.flatMap { $0.isTombstone ? nil : $0["members"]?.stringsValue } ?? [] }
        func name(_ r: SyncRecord?) -> String? { r.flatMap { $0.isTombstone ? nil : $0["name"]?.stringValue } }
        func nameTime(_ r: SyncRecord) -> Date { r["nameEditedAt"]?.dateValue ?? r.modifiedAt }
        let b = members(base), l = members(local), s = members(server)
        let removedLocal = Set(b).subtracting(l)
        let addedLocal = l.filter { !b.contains($0) }
        var merged = s.filter { !removedLocal.contains($0) }
        for m in addedLocal where !merged.contains(m) { merged.append(m) }
        guard !merged.isEmpty else { return nil }
        let nb = name(base), nl = name(local), ns = name(server)
        // The name goes to the side that changed it; when both did, to the later rename.
        let fromLocal: Bool
        if nl == nil { fromLocal = false }
        else if ns == nil { fromLocal = true }
        else if nl == nb { fromLocal = false }
        else if ns == nb { fromLocal = true }
        else { fromLocal = nameTime(local) >= nameTime(server) }
        let source = fromLocal ? local : server
        let template = local.isTombstone ? server : local
        var out = template
        out.fields = ["folderID": template["folderID"] ?? server["folderID"] ?? local["folderID"] ?? .string(""),
                      "name": .string(name(source) ?? PinFolder.defaultName),
                      "nameEditedAt": .date(nameTime(source)),
                      "members": .strings(merged.sorted())]
        out.isTombstone = false
        out.modifiedAt = max(local.modifiedAt, server.modifiedAt)
        out.modifiedBy = local.modifiedBy
        out.serverTag = server.serverTag
        return out
    }

    // MARK: Names

    /// CloudKit record names must be ASCII; hosts can be IDN.
    static func safe(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: ".-_")
        let ascii = s.unicodeScalars.allSatisfy(\.isASCII)
        return (ascii ? s : s.addingPercentEncoding(withAllowedCharacters: allowed)) ?? s
    }

    public static func pinName(_ key: SiteKey) -> String { "pin-" + safe(key.host) }
    public static func folderName(_ id: UUID) -> String { "folder-" + id.uuidString }
    public static func shelfName(_ id: PageID) -> String { "shelf-" + id.raw.uuidString }
    public static func historyName(_ id: UUID) -> String { "history-" + id.uuidString }
    public static func deviceName(_ deviceID: String) -> String { "device-" + safe(deviceID) }

    // MARK: Payload -> records

    /// Pin and shelf records for a payload, keyed by record name. `previous` supplies records
    /// already known for the same names: a shelved page keeps the `shelvedAt` it was first synced
    /// with even though its entry's `shelvedAt` moves when later pages join.
    public static func records(for payload: SyncPayload, previous: [String: SyncRecord] = [:]) -> [String: SyncRecord] {
        var out: [String: SyncRecord] = [:]
        for r in pinRecords(payload.pins) { out[r.recordName] = r }
        for r in folderRecords(payload.pins) { out[r.recordName] = r }
        for r in shelfRecords(payload.shelf, previous: previous) { out[r.recordName] = r }
        return out
    }

    public static func pinRecords(_ pins: [PinnedSite]) -> [SyncRecord] {
        var seen = Set<SiteKey>()
        var out: [SyncRecord] = []
        for pin in pins where seen.insert(pin.key).inserted {
            out.append(SyncRecord(recordType: pinType, recordName: pinName(pin.key), fields: [
                "key": .string(pin.key.host),
                "name": .string(pin.name),
                "homeURL": .string(pin.homeURL.absoluteString),
                "order": .int(out.count),
            ]))
        }
        return out
    }

    /// One record per folder: its name and member site keys in bar order.
    public static func folderRecords(_ pins: [PinnedSite]) -> [SyncRecord] {
        var seen = Set<SiteKey>()
        var order: [UUID] = []
        var names: [UUID: String] = [:]
        var members: [UUID: [String]] = [:]
        for pin in BarOrder.arranged(pins) where seen.insert(pin.key).inserted {
            guard let f = pin.folder else { continue }
            if names[f.id] == nil { names[f.id] = f.name; order.append(f.id) }
            members[f.id, default: []].append(pin.key.host)
        }
        return order.map { id in
            SyncRecord(recordType: folderType, recordName: folderName(id), fields: [
                "folderID": .string(id.uuidString),
                "name": .string(names[id] ?? PinFolder.defaultName),
                "members": .strings((members[id] ?? []).sorted()),
            ])
        }
    }

    public static func shelfRecords(_ shelf: [ShelfEntry], previous: [String: SyncRecord] = [:]) -> [SyncRecord] {
        var out: [SyncRecord] = []
        var seen = Set<PageID>()
        for entry in shelf {
            for page in entry.pages where seen.insert(page.id).inserted {
                let name = shelfName(page.id)
                var shelvedAt = entry.shelvedAt
                if let prev = previous[name], !prev.isTombstone, let d = prev["shelvedAt"]?.dateValue,
                   prev["key"]?.stringValue == entry.key.host {
                    shelvedAt = d
                }
                var fields: [String: SyncValue] = [
                    "pageID": .string(page.id.raw.uuidString),
                    "key": .string(entry.key.host),
                    "siteName": .string(entry.name),
                    "url": .string(page.url.absoluteString),
                    "rawTitle": .string(page.rawTitle),
                    "name": .string(page.name),
                    "shelvedAt": .date(shelvedAt),
                    "lastUsed": .date(page.usage.lastUsed),
                ]
                if let c = page.customName { fields["customName"] = .string(c) }
                out.append(SyncRecord(recordType: shelfType, recordName: name, fields: fields))
            }
        }
        return out
    }

    public static func historyRecord(_ e: HistoryEntry) -> SyncRecord {
        SyncRecord(recordType: historyType, recordName: historyName(e.id), fields: [
            "entryID": .string(e.id.uuidString),
            "url": .string(e.url.absoluteString),
            "title": .string(e.title),
            "name": .string(e.name),
            "key": .string(e.key.host),
            "visitedAt": .date(e.visitedAt),
            "dwell": .double(e.dwell),
        ])
    }

    public static func clearRecord(clearedAt: Date) -> SyncRecord {
        SyncRecord(recordType: clearType, recordName: clearName, fields: ["clearedAt": .date(clearedAt)])
    }

    public static func deviceRecord(deviceID: String, deviceName: String, pages: [OpenPageSummary]) -> SyncRecord {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let data = (try? enc.encode(pages)) ?? Data("[]".utf8)
        return SyncRecord(recordType: deviceType, recordName: self.deviceName(deviceID), fields: [
            "deviceID": .string(deviceID),
            "deviceName": .string(deviceName),
            "pages": .data(data),
        ])
    }

    // MARK: Records -> payload

    /// Pins from live pin records, in `order` (ties by key). A pin whose key exists locally keeps
    /// the local pin's id and page untouched; a new pin gets a fresh page at its home URL.
    public static func pins(from records: [SyncRecord], local: [PinnedSite], now: Date) -> [PinnedSite] {
        let localByKey = Dictionary(local.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        let live = records.filter { $0.recordType == pinType && !$0.isTombstone }
            .compactMap { r -> (order: Int, key: SiteKey, name: String, home: URL)? in
                guard let host = r["key"]?.stringValue, let name = r["name"]?.stringValue,
                      let s = r["homeURL"]?.stringValue, let home = URL(string: s) else { return nil }
                return (r["order"]?.intValue ?? Int.max, SiteKey(host), name, home)
            }
            .sorted { ($0.order, $0.key.host) < ($1.order, $1.key.host) }
        let folders = folderMembership(from: records)
        let pins: [PinnedSite] = live.map { item in
            let folder = folders[item.key]?.folder
            if var pin = localByKey[item.key] {
                pin.name = item.name
                pin.homeURL = item.home
                pin.folder = folder
                return pin
            }
            let page = Page(url: item.home, name: item.name, usage: Usage(at: now))
            return PinnedSite(key: item.key, name: item.name, homeURL: item.home, page: page, folder: folder)
        }
        // A folder sits where its first member is; members keep the pins' order.
        return BarOrder.arranged(pins)
    }

    /// Which folder each site key belongs to. When two live folder records list one key (moved
    /// into different folders on two Macs), the later edit wins.
    static func folderMembership(from records: [SyncRecord]) -> [SiteKey: (folder: PinFolder, index: Int)] {
        var out: [SiteKey: (folder: PinFolder, index: Int)] = [:]
        let live = records.filter { $0.recordType == folderType && !$0.isTombstone }
            .sorted { ($0.modifiedAt, $0.recordName) < ($1.modifiedAt, $1.recordName) }
        for r in live {
            guard let id = r["folderID"]?.stringValue.flatMap(UUID.init(uuidString:)) else { continue }
            let name = r["name"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? PinFolder.defaultName
            for (i, host) in (r["members"]?.stringsValue ?? []).enumerated() {
                out[SiteKey(host)] = (PinFolder(id: id, name: name), i)
            }
        }
        return out
    }

    /// Shelf entries from live shelf-page records: one entry per key (so the same site shelved on
    /// two Macs becomes one entry). Pages sort newest-shelved first, then in local order, then
    /// most recently used first; entries newest-shelved first.
    /// Two pages of one entry with the same URL are shown once (the most recently used);
    /// `duplicates` returns the record names of the hidden ones.
    public static func shelf(from records: [SyncRecord], local: [ShelfEntry]) -> (shelf: [ShelfEntry], duplicates: [String]) {
        struct Item { var page: Page; var key: SiteKey; var siteName: String; var shelvedAt: Date; var localRank: Int; var name: String }
        var localPages: [PageID: (Page, Int)] = [:]
        var localEntries: [SiteKey: (ShelfEntry, Int)] = [:]
        var rank = 0
        for (ei, e) in local.enumerated() {
            if localEntries[e.key] == nil { localEntries[e.key] = (e, ei) }
            for p in e.pages { localPages[p.id] = (p, rank); rank += 1 }
        }
        var byKey: [SiteKey: [Item]] = [:]
        for r in records where r.recordType == shelfType && !r.isTombstone {
            guard let idStr = r["pageID"]?.stringValue, let uuid = UUID(uuidString: idStr),
                  let host = r["key"]?.stringValue, let urlStr = r["url"]?.stringValue,
                  let url = URL(string: urlStr), let shelvedAt = r["shelvedAt"]?.dateValue,
                  let lastUsed = r["lastUsed"]?.dateValue else { continue }
            let id = PageID(uuid)
            var page: Page
            var lr = Int.max
            if let (p, i) = localPages[id] {
                page = p
                lr = i
                page.url = url
                if abs(page.usage.lastUsed.timeIntervalSince(lastUsed)) >= 0.001 {
                    page.usage.lastUsed = lastUsed
                    page.usage.firstUsed = min(page.usage.firstUsed, lastUsed)
                }
            } else {
                page = Page(id: id, url: url, name: "", usage: Usage(at: lastUsed))
            }
            page.rawTitle = r["rawTitle"]?.stringValue ?? ""
            page.name = r["name"]?.stringValue ?? ""
            page.customName = r["customName"]?.stringValue
            byKey[SiteKey(host), default: []].append(Item(page: page, key: SiteKey(host),
                siteName: r["siteName"]?.stringValue ?? host, shelvedAt: shelvedAt, localRank: lr, name: r.recordName))
        }
        var duplicates: [String] = []
        var entries: [(ShelfEntry, Int)] = []
        for (key, items) in byKey {
            var items = items
            // Duplicate URLs: keep the most recently used, ties by record name (same on every Mac).
            var bestByURL: [URL: Int] = [:]
            for (i, it) in items.enumerated() {
                if let j = bestByURL[it.page.url] {
                    let a = items[j], b = it
                    let bWins = (b.page.usage.lastUsed, b.name) > (a.page.usage.lastUsed, a.name)
                    duplicates.append(bWins ? a.name : b.name)
                    if bWins { bestByURL[it.page.url] = i }
                } else {
                    bestByURL[it.page.url] = i
                }
            }
            let keep = Set(bestByURL.values)
            items = items.enumerated().filter { keep.contains($0.offset) }.map(\.element)
            items.sort {
                if abs($0.shelvedAt.timeIntervalSince($1.shelvedAt)) >= 0.001 { return $0.shelvedAt > $1.shelvedAt }
                if $0.localRank != $1.localRank { return $0.localRank < $1.localRank }
                if $0.page.usage.lastUsed != $1.page.usage.lastUsed { return $0.page.usage.lastUsed > $1.page.usage.lastUsed }
                return $0.name < $1.name
            }
            let newest = items.map(\.shelvedAt).max() ?? .distantPast
            if let (le, li) = localEntries[key] {
                var e = le
                e.pages = items.map(\.page)
                if newest.timeIntervalSince(e.shelvedAt) >= 0.001 { e.shelvedAt = newest }
                entries.append((e, li))
            } else {
                let name = items.max { $0.shelvedAt < $1.shelvedAt }?.siteName ?? key.host
                entries.append((ShelfEntry(key: key, name: name, pages: items.map(\.page), shelvedAt: newest), Int.max))
            }
        }
        entries.sort {
            if abs($0.0.shelvedAt.timeIntervalSince($1.0.shelvedAt)) >= 0.001 { return $0.0.shelvedAt > $1.0.shelvedAt }
            if $0.1 != $1.1 { return $0.1 < $1.1 }
            return $0.0.key.host < $1.0.key.host
        }
        return (entries.map(\.0), duplicates.sorted())
    }

    public static func historyEntry(from r: SyncRecord) -> HistoryEntry? {
        guard r.recordType == historyType, !r.isTombstone,
              let idStr = r["entryID"]?.stringValue, let id = UUID(uuidString: idStr),
              let urlStr = r["url"]?.stringValue, let url = URL(string: urlStr),
              let host = r["key"]?.stringValue, let visitedAt = r["visitedAt"]?.dateValue else { return nil }
        return HistoryEntry(id: id, url: url, title: r["title"]?.stringValue ?? "", name: r["name"]?.stringValue ?? "",
                            key: SiteKey(host), visitedAt: visitedAt, dwell: r["dwell"]?.doubleValue ?? 0)
    }

    public static func devicePages(from r: SyncRecord) -> DeviceOpenPages? {
        guard r.recordType == deviceType, !r.isTombstone, let id = r["deviceID"]?.stringValue else { return nil }
        let pages = r["pages"]?.dataValue.flatMap { try? JSONDecoder().decode([OpenPageSummary].self, from: $0) } ?? []
        return DeviceOpenPages(deviceID: id, deviceName: r["deviceName"]?.stringValue ?? id,
                               updatedAt: r.modifiedAt, pages: pages)
    }

    /// A stable fingerprint of the parts of a history entry that can change after it is created
    /// (title, name, dwell in 30 s steps). FNV-1a, so it is the same in every process.
    public static func fingerprint(_ e: HistoryEntry) -> UInt64 {
        let dwellStep = e.dwell.isFinite ? Int(e.dwell / 30) : 0
        let s = "\(e.url.absoluteString)\u{1f}\(e.title)\u{1f}\(e.name)\u{1f}\(e.key.host)\u{1f}\(dwellStep)"
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 { h ^= UInt64(b); h = h &* 0x0000_0100_0000_01b3 }
        return h
    }
}
