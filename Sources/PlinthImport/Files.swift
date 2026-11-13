import Foundation
import SQLite3

/// One bookmark read from another browser.
struct ImportedBookmark: Sendable, Equatable {
    var title: String
    var url: URL
}

/// One visit read from another browser.
struct ImportedVisit: Sendable, Equatable {
    var title: String
    var url: URL
    var date: Date
}

enum FileState { case exists, missing, denied }

/// File-system helpers that tell "not there" from "not allowed" (macOS privacy returns EPERM for
/// Safari's folder without Full Disk Access, and `FileManager.fileExists` hides that).
enum Probe {
    static func state(_ url: URL) -> FileState {
        var st = stat()
        if stat(url.path, &st) == 0 { return .exists }
        switch errno {
        case EACCES, EPERM: return .denied
        case ENOENT, ENOTDIR: return .missing
        default: return .exists
        }
    }

    /// True for the "Operation not permitted" / "Permission denied" family of errors.
    static func isPermission(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileReadNoPermissionError || ns.code == NSFileWriteNoPermissionError { return true }
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(EPERM) || ns.code == Int(EACCES) { return true }
        if let under = ns.userInfo[NSUnderlyingErrorKey] as? Error, isPermission(under) { return true }
        return false
    }

    static func isMissing(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileReadNoSuchFileError || ns.code == NSFileNoSuchFileError { return true }
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(ENOENT) { return true }
        return false
    }
}

enum Failures {
    static func notFound(_ source: ImportSource, _ what: String) -> ImportFailure {
        ImportFailure(kind: .notFound, message: "\(source.displayName)'s data wasn't found on this Mac (no \(what)). Open \(source.displayName) once, or choose another source.")
    }
    static func denied(_ source: ImportSource) -> ImportFailure {
        switch source {
        case .safari:
            return ImportFailure(kind: .permissionDenied, message: "macOS keeps Safari's data private. To import it, allow Plinth in System Settings > Privacy & Security > Full Disk Access, then try again.")
        case .chrome:
            return ImportFailure(kind: .permissionDenied, message: "macOS wouldn't let Plinth read Chrome's data. Allow Plinth in System Settings > Privacy & Security > Full Disk Access, then try again.")
        }
    }
    static func unreadable(_ source: ImportSource, _ what: String) -> ImportFailure {
        ImportFailure(kind: .unreadable, message: "Plinth couldn't read \(source.displayName)'s \(what). The file may be damaged or in a format Plinth doesn't know.")
    }
}

/// Reads a file's bytes, with failures turned into `ImportFailure`.
func readFile(_ url: URL, source: ImportSource, what: String) throws(ImportFailure) -> Data {
    switch Probe.state(url) {
    case .missing: throw Failures.notFound(source, what)
    case .denied: throw Failures.denied(source)
    case .exists: break
    }
    do { return try Data(contentsOf: url) }
    catch {
        if Probe.isPermission(error) { throw Failures.denied(source) }
        if Probe.isMissing(error) { throw Failures.notFound(source, what) }
        throw Failures.unreadable(source, what)
    }
}

func httpURL(_ s: String) -> URL? {
    let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
          url.host?.isEmpty == false else { return nil }
    return url
}

// MARK: - SQLite

/// Where temporary database copies go. Tests bind this (per task) to a folder they own.
enum ImportTemp {
    @TaskLocal static var directory: URL?
}

/// Copies a SQLite database (and its -wal / -shm) to a temporary folder, opens the copy read-only,
/// runs `body`, and removes the copy. The original is only ever read.
func withDatabaseCopy<T>(_ original: URL, source: ImportSource, what: String,
                         _ body: (OpaquePointer) throws(ImportFailure) -> T) throws(ImportFailure) -> T {
    switch Probe.state(original) {
    case .missing: throw Failures.notFound(source, what)
    case .denied: throw Failures.denied(source)
    case .exists: break
    }
    let fm = FileManager.default
    let dir = (ImportTemp.directory ?? fm.temporaryDirectory).appendingPathComponent("plinth-import-\(UUID().uuidString)", isDirectory: true)
    defer { try? fm.removeItem(at: dir) }
    let copy = dir.appendingPathComponent(original.lastPathComponent)
    do {
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try fm.copyItem(at: original, to: copy)
        for suffix in ["-wal", "-shm"] {
            let side = URL(fileURLWithPath: original.path + suffix)
            if Probe.state(side) == .exists { try? fm.copyItem(at: side, to: URL(fileURLWithPath: copy.path + suffix)) }
        }
    } catch {
        if Probe.isPermission(error) { throw Failures.denied(source) }
        if Probe.isMissing(error) { throw Failures.notFound(source, what) }
        throw Failures.unreadable(source, what)
    }
    var db: OpaquePointer?
    guard sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
        sqlite3_close(db)
        throw Failures.unreadable(source, what)
    }
    defer { sqlite3_close(db) }
    return try body(db)
}

/// Runs a query and hands each row to `row`; any SQL error means the file isn't what we expect.
func query(_ db: OpaquePointer, _ sql: String, source: ImportSource, what: String,
           row: (OpaquePointer) -> Void) throws(ImportFailure) {
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
        sqlite3_finalize(stmt)
        throw Failures.unreadable(source, what)
    }
    defer { sqlite3_finalize(stmt) }
    while true {
        let rc = sqlite3_step(stmt)
        if rc == SQLITE_ROW { row(stmt) } else if rc == SQLITE_DONE { break } else { throw Failures.unreadable(source, what) }
    }
}

func text(_ stmt: OpaquePointer, _ column: Int32) -> String {
    guard let c = sqlite3_column_text(stmt, column) else { return "" }
    return String(cString: c)
}
