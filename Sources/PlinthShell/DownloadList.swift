import Foundation
import PlinthModel

/// What Chromium reports about one download, in plain values (so the list logic can be tested).
public struct DownloadUpdate: Equatable {
    public var id: UInt32
    public var url: String
    public var filename: String
    public var path: String
    public var receivedBytes: Int64
    public var totalBytes: Int64?
    public var bytesPerSecond: Int64
    public var isInProgress: Bool
    public var isComplete: Bool
    public var isCanceled: Bool
    public var isInterrupted: Bool

    public init(id: UInt32, url: String = "", filename: String, path: String = "", receivedBytes: Int64 = 0, totalBytes: Int64? = nil,
         bytesPerSecond: Int64 = 0, isInProgress: Bool = true, isComplete: Bool = false, isCanceled: Bool = false,
         isInterrupted: Bool = false) {
        self.id = id; self.url = url; self.filename = filename; self.path = path; self.receivedBytes = receivedBytes
        self.totalBytes = totalBytes; self.bytesPerSecond = bytesPerSecond; self.isInProgress = isInProgress
        self.isComplete = isComplete; self.isCanceled = isCanceled; self.isInterrupted = isInterrupted
    }

}

/// The downloads of this session, newest first, in the shared `DownloadItem` form the tray and bar draw.
public struct DownloadList: Equatable {
    public init() {}
    public private(set) var items: [DownloadItem] = []
    /// Chromium's id for each item.
    public private(set) var chromiumIDs: [UUID: UInt32] = [:]

    public mutating func apply(_ u: DownloadUpdate, now: Date = Date()) {
        let state: DownloadItem.State = u.isComplete ? .finished
            : u.isCanceled ? .cancelled
            : u.isInterrupted ? .failed("The download was interrupted.")
            : .running
        let progress: Double? = u.isComplete ? 1 : u.totalBytes.map { $0 > 0 ? min(Double(u.receivedBytes) / Double($0), 1) : 0 }
        if let i = items.firstIndex(where: { chromiumIDs[$0.id] == u.id }) {
            var item = items[i]
            item.state = state
            item.progress = progress
            item.receivedBytes = u.receivedBytes
            item.totalBytes = u.totalBytes
            item.bytesPerSecond = state == .running && u.bytesPerSecond > 0 ? Double(u.bytesPerSecond) : nil
            if !u.path.isEmpty { item.fileURL = URL(fileURLWithPath: u.path); item.filename = item.fileURL!.lastPathComponent }
            items[i] = item
        } else {
            let item = DownloadItem(filename: u.filename, progress: progress, state: state,
                                    fileURL: u.path.isEmpty ? nil : URL(fileURLWithPath: u.path), startedAt: now,
                                    receivedBytes: u.receivedBytes, totalBytes: u.totalBytes, sourceURL: URL(string: u.url))
            chromiumIDs[item.id] = u.id
            items.insert(item, at: 0)
        }
    }

    public mutating func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        chromiumIDs[id] = nil
    }

    /// Drops everything that has stopped; running downloads stay.
    public mutating func clearFinished() {
        for item in items where item.state != .running { chromiumIDs[item.id] = nil }
        items.removeAll { $0.state != .running }
    }

    public var running: [DownloadItem] { items.filter { $0.state == .running } }

    /// What the downloads button shows: how many are running and their average progress.
    public var barState: DownloadsSummary? {
        guard !items.isEmpty else { return nil }
        let known = running.compactMap(\.progress)
        return DownloadsSummary(runningCount: running.count,
                                progress: known.isEmpty ? nil : min(max(known.reduce(0, +) / Double(known.count), 0), 1))
    }
}

/// The downloads button's state, in plain values (the Mac bar turns it into its own BarDownloadsState).
public struct DownloadsSummary: Equatable, Sendable {
    public var runningCount: Int
    /// Average progress of the running downloads that know their size, 0...1; nil when none do.
    public var progress: Double?
    public init(runningCount: Int, progress: Double?) { self.runningCount = runningCount; self.progress = progress }
}
