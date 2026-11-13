import Foundation

/// A saved login with its password. Only `PasswordVault.password(for:)` and `save` carry the secret.
public struct Login: Equatable, Sendable {
    public var origin: WebOrigin
    public var username: String
    public var password: String
    public var created: Date
    public var modified: Date

    public init(origin: WebOrigin, username: String, password: String, created: Date = Date(), modified: Date? = nil) {
        self.origin = origin
        self.username = username
        self.password = password
        self.created = created
        self.modified = modified ?? created
    }

    public var key: LoginKey { LoginKey(origin: origin, username: username) }
}

/// What identifies a login: the site and the user name.
public struct LoginKey: Hashable, Sendable {
    public var origin: WebOrigin
    public var username: String
    public init(origin: WebOrigin, username: String) { self.origin = origin; self.username = username }
}

/// A login without its password: safe to keep in lists and views.
public struct LoginSummary: Equatable, Sendable, Identifiable {
    public var origin: WebOrigin
    public var username: String
    public var created: Date
    public var modified: Date
    public init(origin: WebOrigin, username: String, created: Date, modified: Date) {
        self.origin = origin; self.username = username; self.created = created; self.modified = modified
    }
    public var key: LoginKey { LoginKey(origin: origin, username: username) }
    public var id: String { "\(origin)\u{1F}\(username)" }
}

public enum VaultError: Error, Equatable, Sendable {
    case notFound
    /// The Keychain refused (locked, access denied, ...). `status` is the OSStatus.
    case keychain(status: Int32)
}

public struct MergeResult: Equatable, Sendable {
    public var added = 0
    /// Already saved (same site and user name): left alone.
    public var duplicates = 0
    public var failed = 0
    public init(added: Int = 0, duplicates: Int = 0, failed: Int = 0) { self.added = added; self.duplicates = duplicates; self.failed = failed }
}

/// Where logins live. The real implementation is the macOS Keychain; tests use `InMemoryVault`.
public protocol PasswordVault: AnyObject, Sendable {
    /// Every login without its password, sorted by site then user name.
    func list() throws -> [LoginSummary]
    /// The password for one login, nil when there is none.
    func password(for key: LoginKey) throws -> String?
    /// Adds or replaces the login with this site and user name.
    func save(_ login: Login) throws
    func delete(_ key: LoginKey) throws
}

public extension PasswordVault {
    /// Logins saved for exactly this origin.
    func logins(for origin: WebOrigin) throws -> [LoginSummary] {
        try list().filter { WebOrigin.mayFill(saved: $0.origin, into: origin) }
    }

    /// Replaces `old` with `new` (the site or user name may have changed). Nothing is lost if the write fails.
    func replace(_ old: LoginKey, with new: Login) throws {
        try save(new)
        if old != new.key { try delete(old) }
    }

    /// Adds every login that is not already saved. Existing logins are never overwritten.
    func merge(_ logins: [Login]) -> MergeResult {
        var result = MergeResult()
        var known = Set((try? list())?.map(\.key) ?? [])
        for login in logins {
            if known.contains(login.key) { result.duplicates += 1; continue }
            do { try save(login); known.insert(login.key); result.added += 1 } catch { result.failed += 1 }
        }
        return result
    }
}

/// Test double: the same behaviour as the Keychain vault, in memory.
public final class InMemoryVault: PasswordVault, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [LoginKey: Login] = [:]
    /// Make every call throw, to test failure handling.
    public var failure: VaultError?

    public init(_ logins: [Login] = []) { for l in logins { items[l.key] = l } }

    public func list() throws -> [LoginSummary] {
        lock.lock(); defer { lock.unlock() }
        if let failure { throw failure }
        return items.values.map { LoginSummary(origin: $0.origin, username: $0.username, created: $0.created, modified: $0.modified) }.sortedForDisplay()
    }

    public func password(for key: LoginKey) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        if let failure { throw failure }
        return items[key]?.password
    }

    public func save(_ login: Login) throws {
        lock.lock(); defer { lock.unlock() }
        if let failure { throw failure }
        var stored = login
        if let old = items[login.key] { stored.created = old.created }
        items[login.key] = stored
    }

    public func delete(_ key: LoginKey) throws {
        lock.lock(); defer { lock.unlock() }
        if let failure { throw failure }
        guard items.removeValue(forKey: key) != nil else { throw VaultError.notFound }
    }
}

extension Array where Element == LoginSummary {
    func sortedForDisplay() -> [LoginSummary] {
        sorted {
            let a = $0.origin.displayHost, b = $1.origin.displayHost
            if a != b { return a.localizedStandardCompare(b) == .orderedAscending }
            if $0.origin != $1.origin { return $0.origin.description < $1.origin.description }
            return $0.username.localizedStandardCompare($1.username) == .orderedAscending
        }
    }
}
