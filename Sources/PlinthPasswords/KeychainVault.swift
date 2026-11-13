import Foundation
import Security

/// Logins as macOS Keychain generic-password items, one per login: the Keychain encrypts the password and
/// guards it, and Plinth reads the rest (site, user name, dates) without ever touching the secret.
///
/// Layout: service = `service`, account = "<origin>\t<username>", label = "Plinth: <origin>".
public final class KeychainVault: PasswordVault, @unchecked Sendable {
    public let service: String

    public init(service: String = "app.plinth.passwords") { self.service = service }

    private func account(_ key: LoginKey) -> String { "\(key.origin)\t\(key.username)" }

    private func base(_ key: LoginKey? = nil) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        if let key { q[kSecAttrAccount as String] = account(key) }
        return q
    }

    public func list() throws -> [LoginSummary] {
        var q = base()
        q[kSecMatchLimit as String] = kSecMatchLimitAll
        q[kSecReturnAttributes as String] = true
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let rows = out as? [[String: Any]] else { throw VaultError.keychain(status: status) }
        var result: [LoginSummary] = []
        for row in rows {
            guard let account = row[kSecAttrAccount as String] as? String, let tab = account.firstIndex(of: "\t"),
                  let origin = WebOrigin(string: String(account[..<tab])) else { continue }
            let created = row[kSecAttrCreationDate as String] as? Date ?? Date()
            let modified = row[kSecAttrModificationDate as String] as? Date ?? created
            result.append(LoginSummary(origin: origin, username: String(account[account.index(after: tab)...]), created: created, modified: modified))
        }
        return result.sortedForDisplay()
    }

    public func password(for key: LoginKey) throws -> String? {
        var q = base(key)
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        q[kSecReturnData as String] = true
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else { throw VaultError.keychain(status: status) }
        return String(data: data, encoding: .utf8)
    }

    public func save(_ login: Login) throws {
        let data = Data(login.password.utf8)
        let update = SecItemUpdate(base(login.key) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw VaultError.keychain(status: update) }
        var q = base(login.key)
        q[kSecValueData as String] = data
        q[kSecAttrLabel as String] = "Plinth: \(login.origin)"
        let add = SecItemAdd(q as CFDictionary, nil)
        guard add == errSecSuccess else { throw VaultError.keychain(status: add) }
    }

    public func delete(_ key: LoginKey) throws {
        let status = SecItemDelete(base(key) as CFDictionary)
        if status == errSecItemNotFound { throw VaultError.notFound }
        guard status == errSecSuccess else { throw VaultError.keychain(status: status) }
    }
}
