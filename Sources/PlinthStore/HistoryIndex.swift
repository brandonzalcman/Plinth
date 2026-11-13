import Foundation
import Darwin
import PlinthModel

/// A searchable copy of the history for the history view. It is a plain value (`Sendable`), so it
/// can be built and queried off the main thread: build once when the view opens, then run one
/// `page(for:)` per keystroke. Text matching is a byte search over a folded string per visit, so
/// a 50,000-entry history filters in a few milliseconds.
public struct HistoryIndex: Sendable {
    struct Item: Sendable {
        var id: UUID
        var url: URL
        var title: String
        var key: SiteKey
        var host: String
        var visitedAt: Date
        var canon: String
        /// Folded title, name, host and address.
        var hay: String
    }

    private(set) var items: [Item]

    public init(_ history: [HistoryEntry]) {
        var built: [Item] = []
        built.reserveCapacity(history.count)
        for entry in history {
            let canon = URLCanonical.key(entry.url)
            let host = URLCanonical.host(entry.url)
            let title = entry.name.isEmpty ? (entry.title.isEmpty ? URLCanonical.display(entry.url) : entry.title) : entry.name
            let hay = URLCanonical.fold(entry.title + " " + entry.name + " " + canon)
            built.append(Item(id: entry.id, url: entry.url, title: title, key: entry.key,
                              host: host.isEmpty ? entry.key.host : host, visitedAt: entry.visitedAt, canon: canon, hay: hay))
        }
        // Newest first. Imported history can be out of order, and the sort is stable.
        let alreadySorted = zip(built, built.dropFirst()).allSatisfy { $0.visitedAt >= $1.visitedAt }
        items = alreadySorted ? built : built.enumerated().sorted {
            $0.element.visitedAt != $1.element.visitedAt ? $0.element.visitedAt > $1.element.visitedAt : $0.offset < $1.offset
        }.map(\.element)
    }

    public var count: Int { items.count }

    static let maxSites = 8

    /// Filters, merges back-to-back repeats and groups by day. At most `rowLimit` rows are
    /// returned; `totalRows` says how many matched.
    public func page(for filter: HistoryFilter, now: Date = Date(), calendar: Calendar = .current,
                     rowLimit: Int = 300) -> HistoryPage {
        let words = URLCanonical.fold(filter.text).split(whereSeparator: { $0.isWhitespace }).map { Array($0.utf8) }
        let (lower, upper) = Self.bounds(filter.range, now: now, calendar: calendar)
        let site = filter.site?.lowercased()

        var rows: [HistoryRow] = []
        var hostCounts: [String: Int] = [:]
        var total = 0
        var lastCanon: String?

        for item in items {
            if let upper, item.visitedAt >= upper { continue }
            if let lower, item.visitedAt < lower { break } // newest first, so everything after is older
            if !words.isEmpty, !Self.matches(item.hay, words) { continue }
            hostCounts[item.host, default: 0] += 1
            if let site, item.host != site { continue }
            if item.canon == lastCanon {
                if !rows.isEmpty, total <= rowLimit { rows[rows.count - 1].visits += 1 }
                continue
            }
            lastCanon = item.canon
            total += 1
            if rows.count < rowLimit {
                rows.append(HistoryRow(id: item.id, url: item.url, title: item.title, key: item.key, visitedAt: item.visitedAt))
            }
        }

        var days: [HistoryDayGroup] = []
        for row in rows {
            let day = calendar.startOfDay(for: row.visitedAt)
            if days.last?.day == day { days[days.count - 1].rows.append(row) } else { days.append(HistoryDayGroup(day: day, rows: [row])) }
        }
        let sites = hostCounts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(Self.maxSites).map { HistorySiteCount(host: $0.key, count: $0.value) }
        return HistoryPage(days: days, totalRows: total, sites: Array(sites))
    }

    /// Start (inclusive) and end (exclusive) of a range; nil means unbounded.
    static func bounds(_ range: HistoryRange, now: Date, calendar: Calendar) -> (Date?, Date?) {
        let today = calendar.startOfDay(for: now)
        func daysAgo(_ n: Int) -> Date { calendar.date(byAdding: .day, value: -n, to: today) ?? today.addingTimeInterval(-Double(n) * 86_400) }
        switch range {
        case .today: return (today, nil)
        case .yesterday: return (daysAgo(1), today)
        case .week: return (daysAgo(6), nil)
        case .month: return (daysAgo(29), nil)
        case .all: return (nil, nil)
        }
    }

    private static func matches(_ hay: String, _ words: [[UInt8]]) -> Bool {
        var hay = hay
        return hay.withUTF8 { haystack in
            guard let base = haystack.baseAddress else { return false }
            for word in words {
                let found = word.withUnsafeBufferPointer { needle -> Bool in
                    guard let n = needle.baseAddress else { return true }
                    return memmem(base, haystack.count, n, needle.count) != nil
                }
                if !found { return false }
            }
            return true
        }
    }
}
