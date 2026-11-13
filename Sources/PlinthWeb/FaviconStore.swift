import AppKit
import Observation
import PlinthModel
import os

/// Site icons, one per `SiteKey`, cached in memory and under `<storageDirectory>/favicons`.
@MainActor
@Observable
public final class FaviconStore {
    /// Icons fetched during this run. Observed: setting one redraws any view that asked for it.
    private var fetched: [SiteKey: NSImage] = [:]

    @ObservationIgnored private var loadedFromDisk: [SiteKey: NSImage] = [:]
    @ObservationIgnored private var knownMissing: Set<SiteKey> = []
    @ObservationIgnored private var inFlight: Set<SiteKey> = []
    @ObservationIgnored private var checked: [SiteKey: Date] = [:]
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let log = Logger(subsystem: "Plinth", category: "favicons")

    /// A stored icon is refreshed when a page of its site is seen and the file is older than this.
    private static let maxAge: TimeInterval = 7 * 24 * 3600
    private static let maxBytes = 2 * 1024 * 1024
    private static let maxPixels = 128

    public init(storageDirectory: URL) {
        directory = storageDirectory.appendingPathComponent("favicons", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.httpMaximumConnectionsPerHost = 2
        session = URLSession(configuration: configuration)
    }

    public func image(for key: SiteKey) -> NSImage? {
        if let image = fetched[key] { return image }      // also registers the observation
        if let image = loadedFromDisk[key] { return image }
        if knownMissing.contains(key) { return nil }
        if let image = NSImage(contentsOf: fileURL(for: key)), image.isValid {
            loadedFromDisk[key] = image
            return image
        }
        knownMissing.insert(key)
        return nil
    }

    /// Fetches the first candidate that yields an image (candidates are in order of preference),
    /// falling back to `/favicon.ico` at the page's origin, and stores it for `key`.
    public func noteIcon(candidates: [URL], pageURL: URL, key: SiteKey) {
        guard !inFlight.contains(key) else { return }
        let now = Date()
        if let last = checked[key], now.timeIntervalSince(last) < 3600 { return }
        let file = fileURL(for: key)
        if let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
           now.timeIntervalSince(modified) < Self.maxAge {
            checked[key] = now
            return
        }

        var urls = candidates.filter { ["http", "https"].contains($0.scheme?.lowercased() ?? "") }
        if let scheme = pageURL.scheme?.lowercased(), ["http", "https"].contains(scheme), let host = pageURL.host {
            var origin = URLComponents()
            origin.scheme = scheme
            origin.host = host
            origin.port = pageURL.port
            origin.path = "/favicon.ico"
            if let fallback = origin.url, !urls.contains(fallback) { urls.append(fallback) }
        }
        guard !urls.isEmpty else { return }

        inFlight.insert(key)
        checked[key] = now
        Task {
            defer { inFlight.remove(key) }
            for url in urls {
                guard let data = await download(url), let png = Self.normalizedPNG(from: data),
                      let image = NSImage(data: png) else { continue }
                do {
                    try png.write(to: file, options: .atomic)
                } catch {
                    log.error("Could not store icon for \(key.host, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
                knownMissing.remove(key)
                loadedFromDisk[key] = nil
                fetched[key] = image
                return
            }
        }
    }

    private func download(_ url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.setValue("image/*,*/*;q=0.5", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request) else { return nil }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return nil }
        guard !data.isEmpty, data.count <= Self.maxBytes else { return nil }
        return data
    }

    /// Re-encodes whatever the site served (ICO, PNG, SVG, …) as one square PNG of at most 128 px.
    private static func normalizedPNG(from data: Data) -> Data? {
        guard let image = NSImage(data: data), image.isValid, !image.representations.isEmpty else { return nil }
        var largest = 0
        var hasVector = false
        for rep in image.representations {
            if rep.pixelsWide <= 0 { hasVector = true } else { largest = max(largest, rep.pixelsWide, rep.pixelsHigh) }
        }
        let side = hasVector ? maxPixels : min(max(largest, 16), maxPixels)
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        bitmap.size = NSSize(width: side, height: side)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])
    }

    private func fileURL(for key: SiteKey) -> URL {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: ".-")
        let name = key.host.addingPercentEncoding(withAllowedCharacters: allowed) ?? "unknown"
        return directory.appendingPathComponent((name.isEmpty ? "unknown" : name) + ".png")
    }
}
