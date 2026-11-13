import Foundation

// Value types for the history view. The logic that produces them lives in PlinthStore
// (`HistoryIndex`); the view in PlinthPanels only displays them.

/// How far back the history view looks.
public enum HistoryRange: String, CaseIterable, Sendable, Equatable {
    case today, yesterday, week, month, all

    public var title: String {
        switch self {
        case .today: return "Today"
        case .yesterday: return "Yesterday"
        case .week: return "7 days"
        case .month: return "30 days"
        case .all: return "All"
        }
    }
}

public struct HistoryFilter: Sendable, Equatable {
    /// Every word must appear in the title, name, host or address.
    public var text: String
    public var range: HistoryRange
    /// A site's host (no "www."), or nil for every site.
    public var site: String?

    public init(text: String = "", range: HistoryRange = .all, site: String? = nil) {
        self.text = text; self.range = range; self.site = site
    }
}

/// One line in the history list: a visit, or a run of back-to-back visits to the same page.
public struct HistoryRow: Identifiable, Sendable, Equatable {
    public var id: UUID
    public var url: URL
    public var title: String
    public var key: SiteKey
    /// The newest visit in the run.
    public var visitedAt: Date
    /// How many consecutive visits this row stands for (1 when it is a single visit).
    public var visits: Int

    public init(id: UUID, url: URL, title: String, key: SiteKey, visitedAt: Date, visits: Int = 1) {
        self.id = id; self.url = url; self.title = title; self.key = key; self.visitedAt = visitedAt; self.visits = visits
    }
}

public struct HistoryDayGroup: Identifiable, Sendable, Equatable {
    /// Midnight at the start of the day.
    public var day: Date
    public var rows: [HistoryRow]
    public var id: Date { day }

    public init(day: Date, rows: [HistoryRow]) { self.day = day; self.rows = rows }
}

public struct HistorySiteCount: Identifiable, Sendable, Equatable {
    public var host: String
    public var count: Int
    public var id: String { host }

    public init(host: String, count: Int) { self.host = host; self.count = count }
}

public struct HistoryPage: Sendable, Equatable {
    /// Newest day first, newest row first.
    public var days: [HistoryDayGroup]
    /// Rows matching the filter after consecutive repeats are merged (can exceed what `days` holds).
    public var totalRows: Int
    /// The busiest sites among the matches of the text and range, ignoring the site filter.
    public var sites: [HistorySiteCount]

    public init(days: [HistoryDayGroup] = [], totalRows: Int = 0, sites: [HistorySiteCount] = []) {
        self.days = days; self.totalRows = totalRows; self.sites = sites
    }

    public var shownRows: Int { days.reduce(0) { $0 + $1.rows.count } }
    public static let empty = HistoryPage()
}
