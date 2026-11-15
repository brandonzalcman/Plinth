import Foundation

/// Everything Plinth can do with Apple Passwords that needs no entitlement and works on Mac and iOS.
///
/// Apple gives other browsers no way to read or write Apple Passwords (iCloud Keychain) on arbitrary sites, so
/// Plinth keeps its own logins and moves them to and from Apple Passwords on request:
///  - into Plinth: the CSV from the Passwords app (File > Export All Passwords), parsed by `CSVImport`;
///  - out of Plinth: `ApplePasswordsCSV` (the Passwords app's File > Import Passwords from File) or
///    `CredentialExchange` (the system's Credential Exchange sheet).
/// `ApplePasswordsLedger` remembers what already went across so only new and changed logins are offered again.
public enum ApplePasswordsCSV {
    /// The columns the Passwords app writes and reads.
    public static let header = ["Title", "URL", "Username", "Password", "Notes", "OTPAuth"]

    /// A CSV the Passwords app can import: one row per login, RFC 4180 quoting.
    public static func export(_ logins: [Login]) -> String {
        var lines = [header.joined(separator: ",")]
        for login in logins {
            let fields = [login.origin.displayHost, login.origin.description, login.username, login.password, "", ""]
            lines.append(fields.map(quote).joined(separator: ","))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    private static func quote(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

/// Which logins are already in Apple Passwords, as far as Plinth knows: the ones imported from it and the ones
/// Plinth sent. A login changed in Plinth afterwards counts as waiting again. Holds no secrets.
public struct ApplePasswordsLedger: Codable, Equatable, Sendable {
    /// Login id (`LoginSummary.id`) to when it was last in step with Apple Passwords.
    public private(set) var inStep: [String: Date] = [:]

    public init() {}

    public mutating func markInStep(_ logins: [LoginSummary], at date: Date = Date()) {
        for login in logins { inStep[login.id] = date }
    }

    public mutating func forget(_ login: LoginSummary) { inStep[login.id] = nil }

    /// Logins never sent, or edited since.
    public func waiting(in logins: [LoginSummary]) -> [LoginSummary] {
        logins.filter { login in
            guard let date = inStep[login.id] else { return true }
            return login.modified > date
        }
    }
}
