import Foundation

/// Reads the CSV that Chrome, Edge, Safari / the Passwords app, 1Password and Bitwarden export:
/// a header row naming (some of) url, username and password columns, in any order.
public enum CSVImport {
    public struct Result: Equatable, Sendable {
        public var logins: [Login] = []
        /// Rows without a usable site, user name or password.
        public var skipped = 0
    }

    public enum Failure: Error, Equatable, Sendable {
        /// No header row with a URL and a password column.
        case unrecognised
    }

    private static let urlNames: Set<String> = ["url", "login_uri", "website", "web site", "origin", "hostname", "site"]
    private static let userNames: Set<String> = ["username", "login_username", "user name", "user", "login", "email"]
    private static let passwordNames: Set<String> = ["password", "login_password"]

    public static func parse(_ text: String, now: Date = Date()) throws -> Result {
        let rows = records(text)
        guard let header = rows.first else { throw Failure.unrecognised }
        let names = header.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        func column(_ options: Set<String>) -> Int? { names.firstIndex { options.contains($0) } }
        guard let urlColumn = column(urlNames), let passwordColumn = column(passwordNames) else { throw Failure.unrecognised }
        let userColumn = column(userNames)
        var result = Result()
        for row in rows.dropFirst() where !(row.count == 1 && row[0].isEmpty) {
            func cell(_ i: Int?) -> String { i.flatMap { $0 < row.count ? row[$0] : nil } ?? "" }
            guard let origin = WebOrigin(string: cell(urlColumn)), !cell(passwordColumn).isEmpty, !cell(userColumn).isEmpty else {
                result.skipped += 1
                continue
            }
            result.logins.append(Login(origin: origin, username: cell(userColumn), password: cell(passwordColumn), created: now))
        }
        return result
    }

    /// RFC 4180: quoted fields, doubled quotes, newlines inside quotes, CRLF or LF.
    static func records(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var chars = Array(text.unicodeScalars)
        if chars.first == "\u{FEFF}" { chars.removeFirst() }
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if quoted {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" { field.unicodeScalars.append("\""); i += 1 } else { quoted = false }
                } else { field.unicodeScalars.append(c) }
            } else {
                switch c {
                case "\"": quoted = true
                case ",": row.append(field); field = ""
                case "\n":
                    row.append(field); rows.append(row); row = []; field = ""
                case "\r":
                    if i + 1 < chars.count, chars[i + 1] == "\n" { i += 1 }
                    row.append(field); rows.append(row); row = []; field = ""
                default: field.unicodeScalars.append(c)
                }
            }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }
}
