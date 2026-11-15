import Foundation
import AuthenticationServices

/// Maps Plinth logins to and from the system's Credential Exchange data (iOS 26 / macOS 26), the format the
/// Passwords app and other password managers use to move credentials between apps without a file on disk.
/// Pure mapping: no UI and no entitlement. Sending needs `ASCredentialExportManager` (the system shows the sheet).
public enum CredentialExchange {
    /// Who the data says it came from.
    public static let exporterIdentifier = "dev.getplinth.Plinth"
    public static let exporterName = "Plinth"

    public static func exportedData(from logins: [Login], now: Date = Date()) -> ASExportedCredentialData {
        let items = logins.map { login in
            ASImportableItem(
                id: Data("\(login.origin)\t\(login.username)".utf8),
                created: login.created, lastModified: login.modified,
                title: login.origin.displayHost,
                subtitle: login.username.isEmpty ? nil : login.username,
                scope: ASImportableCredentialScope(urls: [URL(string: login.origin.description)].compactMap { $0 }),
                credentials: [.basicAuthentication(.init(
                    userName: ASImportableEditableField(id: nil, fieldType: .string, value: login.username),
                    password: ASImportableEditableField(id: nil, fieldType: .concealedString, value: login.password)))])
        }
        let account = ASImportableAccount(id: Data("plinth".utf8), userName: "", email: "", collections: [], items: items)
        return ASExportedCredentialData(accounts: [account], formatVersion: .v1, exporterRelyingPartyIdentifier: exporterIdentifier,
                                        exporterDisplayName: exporterName, timestamp: now)
    }

    public struct Imported: Equatable, Sendable {
        public var logins: [Login] = []
        /// Items that are not a web login (passkeys, cards, notes, ...) or lack a site, user name or password.
        public var skipped = 0
    }

    /// The web logins in `data` (user name and password with a site). Everything else is counted as skipped.
    public static func logins(from data: ASExportedCredentialData, now: Date = Date()) -> Imported {
        var out = Imported()
        for item in data.accounts.flatMap(\.items) {
            var found = false
            for case .basicAuthentication(let basic) in item.credentials {
                let user = basic.userName?.value ?? ""
                let secret = basic.password?.value ?? ""
                guard !secret.isEmpty, !user.isEmpty, let url = item.scope?.urls.first, let origin = WebOrigin(url: url) else { continue }
                out.logins.append(Login(origin: origin, username: user, password: secret, created: item.created ?? now, modified: item.lastModified))
                found = true
            }
            if !found { out.skipped += 1 }
        }
        return out
    }
}
