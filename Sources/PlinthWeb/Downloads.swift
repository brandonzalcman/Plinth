import AppKit
import Observation
import WebKit
import PlinthModel

/// Every download this session, newest first. Owned by the pool (`pool.downloads`); the shell
/// reads `items` for the downloads indicator.
@MainActor
@Observable
public final class DownloadsModel {
    public internal(set) var items: [DownloadItem] = []

    public init() {}

    public var hasRunning: Bool { items.contains { $0.state == .running } }

    func update(_ id: UUID, _ body: (inout DownloadItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var item = items[index]
        body(&item)
        if item != items[index] { items[index] = item }
    }
}

final class DownloadRecord {
    let id: UUID
    let download: WKDownload
    var observation: NSKeyValueObservation?
    var rate = DownloadRate()
    /// When the model last got a live update (throttles the UI to a few per second).
    var lastPublished: TimeInterval = 0

    init(id: UUID, download: WKDownload) {
        self.id = id
        self.download = download
    }
}

extension WebViewPool: WKDownloadDelegate {
    /// Starts tracking a download from any view (pooled or auxiliary).
    func track(_ download: WKDownload) {
        let key = ObjectIdentifier(download)
        guard activeDownloads[key] == nil else { return }
        download.delegate = self
        let record = DownloadRecord(id: UUID(), download: download)
        activeDownloads[key] = record

        let guess = download.originalRequest?.url?.lastPathComponent ?? ""
        let filename = guess.isEmpty || guess == "/" ? "Download" : guess
        downloads.items.insert(DownloadItem(id: record.id, filename: filename, progress: nil, state: .running,
                                            fileURL: nil, startedAt: Date(), sourceURL: download.originalRequest?.url), at: 0)

        let id = record.id
        record.observation = download.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            let total: Int64? = progress.totalUnitCount > 0 ? progress.totalUnitCount : nil
            let fraction: Double? = total != nil ? min(max(progress.fractionCompleted, 0), 1) : nil
            let received = progress.completedUnitCount
            Task { @MainActor in self?.downloadProgressed(id, fraction, received: received, total: total) }
        }
    }

    /// Live progress: at most about four model updates a second per download.
    private func downloadProgressed(_ id: UUID, _ fraction: Double?, received: Int64, total: Int64?) {
        guard let record = activeDownloads.values.first(where: { $0.id == id }) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - record.lastPublished >= 0.25 else { return }
        record.lastPublished = now
        let speed = record.rate.sample(bytes: received, at: now)
        downloads.update(id) { item in
            guard item.state == .running else { return }
            item.progress = fraction
            item.receivedBytes = received
            item.totalBytes = total
            item.bytesPerSecond = speed
        }
    }

    private func finishRecord(_ download: WKDownload) -> DownloadRecord? {
        guard let record = activeDownloads.removeValue(forKey: ObjectIdentifier(download)) else { return nil }
        record.observation?.invalidate()
        record.observation = nil
        return record
    }

    /// The folder downloads go to: the chosen one when it exists, else the system Downloads folder.
    func downloadFolderURL() -> URL {
        if let path = settings.downloadFolder, !path.isEmpty {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
            log.info("Download folder missing, using the system Downloads folder")
        }
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    public func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        let folder = downloadFolderURL()
        var destination = Self.uniqueDestination(in: folder, suggested: suggestedFilename)
        if settings.askWhereToSave {
            let panel = NSSavePanel()
            panel.directoryURL = folder
            panel.nameFieldStringValue = destination.lastPathComponent
            panel.canCreateDirectories = true
            let result: NSApplication.ModalResponse
            if let window = download.webView?.window {
                result = await panel.beginSheetModal(for: window)
            } else {
                result = panel.runModal()
            }
            guard result == .OK, let chosen = panel.url else {
                if let record = finishRecord(download) {
                    downloads.update(record.id) { $0.state = .cancelled }
                }
                return nil
            }
            // The panel already confirmed replacing an existing file; WebKit needs the path free.
            try? FileManager.default.removeItem(at: chosen)
            destination = chosen
        }
        if let record = activeDownloads[ObjectIdentifier(download)] {
            downloads.update(record.id) { item in
                item.filename = destination.lastPathComponent
                item.fileURL = destination
                if response.expectedContentLength <= 0 { item.progress = nil }
            }
        }
        return destination
    }

    public func downloadDidFinish(_ download: WKDownload) {
        var fileURL = download.progress.fileURL
        if let record = finishRecord(download) {
            downloads.update(record.id) { item in
                item.state = .finished
                item.progress = 1
                item.bytesPerSecond = nil
                if let size = fileURL.flatMap({ try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }) {
                    item.receivedBytes = Int64(size); item.totalBytes = Int64(size)
                } else if let total = item.totalBytes { item.receivedBytes = total }
                if let fileURL { item.fileURL = fileURL } else { fileURL = item.fileURL }
            }
        }
        if let path = fileURL?.path {
            // Bounces the Downloads stack in the Dock, as Safari does.
            DistributedNotificationCenter.default().post(name: Notification.Name("com.apple.DownloadFileFinished"), object: path)
        }
        if settings.openSafeFilesAfterDownload, let fileURL, DownloadSafety.isSafeToOpen(filename: fileURL.lastPathComponent) {
            NSWorkspace.shared.open(fileURL)
        }
    }

    public func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let failure = error as NSError
        guard let record = finishRecord(download) else { return }
        let cancelled = failure.domain == NSURLErrorDomain && failure.code == NSURLErrorCancelled
        downloads.update(record.id) { item in
            item.state = cancelled ? .cancelled : .failed(failure.localizedDescription)
            item.bytesPerSecond = nil
        }
        if !cancelled { log.error("Download failed: \(failure.localizedDescription, privacy: .public)") }
    }

    // MARK: Indicator commands

    /// Removes every download that is no longer running from the list.
    public func clearFinishedDownloads() {
        downloads.items.removeAll { $0.state != .running }
    }

    public func cancelDownload(id: UUID) {
        guard let (key, record) = activeDownloads.first(where: { $0.value.id == id }) else { return }
        activeDownloads[key] = nil
        record.observation?.invalidate()
        record.observation = nil
        record.download.cancel(nil)
        downloads.update(id) { $0.state = .cancelled; $0.bytesPerSecond = nil }
    }

    /// Opens the finished file in its default app. Nothing happens when it has gone.
    public func openDownload(id: UUID) {
        guard let item = downloads.items.first(where: { $0.id == id }), item.state == .finished,
              let url = item.fileURL, FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Takes one finished, failed or cancelled download off the list. The file stays on disk.
    public func removeDownload(id: UUID) {
        downloads.items.removeAll { $0.id == id && $0.state != .running }
    }

    /// Whether the downloaded file is still where it was saved.
    public func downloadFileExists(id: UUID) -> Bool {
        guard let url = downloads.items.first(where: { $0.id == id })?.fileURL else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Shows the file in Finder (its folder when the file has gone).
    public func revealDownload(id: UUID) {
        guard let url = downloads.items.first(where: { $0.id == id })?.fileURL else { return }
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }

    /// "report.pdf", then "report 2.pdf", "report 3.pdf", … Path separators and a leading dot are removed.
    static func uniqueDestination(in folder: URL, suggested: String) -> URL {
        var name = suggested.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        if name.isEmpty { name = "download" }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)")
            counter += 1
        }
        return candidate
    }
}
