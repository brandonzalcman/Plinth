import Foundation

/// Where a download is saved: a clean filename, unique in its folder.
public enum DownloadNaming {
    /// The name shown before WebKit suggests one: the request's last path component, else "Download".
    public static func provisionalName(for url: URL?) -> String {
        let guess = url?.lastPathComponent ?? ""
        return guess.isEmpty || guess == "/" ? "Download" : guess
    }

    /// Path separators become "-", surrounding whitespace and leading dots are removed; "download"
    /// when nothing is left.
    public static func sanitized(_ suggested: String) -> String {
        var name = suggested.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        return name.isEmpty ? "download" : name
    }

    /// "report.pdf", then "report 2.pdf", "report 3.pdf", … in `folder`, after `sanitized`.
    /// `exists` is the file check (the file system by default).
    public static func uniqueDestination(in folder: URL, suggested: String,
                                         exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        let name = sanitized(suggested)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name)
        var counter = 2
        while exists(candidate) {
            candidate = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)")
            counter += 1
        }
        return candidate
    }
}

/// Which responses become downloads instead of pages.
public enum DownloadPolicy {
    /// True for `Content-Disposition: attachment…`, and for anything WebKit cannot show.
    public static func shouldDownload(_ response: URLResponse, canShowMIMEType: Bool) -> Bool {
        if let http = response as? HTTPURLResponse,
           let disposition = http.value(forHTTPHeaderField: "Content-Disposition"),
           disposition.lowercased().hasPrefix("attachment") {
            return true
        }
        return !canShowMIMEType
    }
}
