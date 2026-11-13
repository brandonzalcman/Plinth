import Foundation
import Security
import SQLite3

/// One saved login read from another browser.
public struct ImportedLogin: Sendable, Equatable {
    public var url: URL
    public var username: String
    public var password: String
    public var created: Date?
    public init(url: URL, username: String, password: String, created: Date? = nil) {
        self.url = url; self.username = username; self.password = password; self.created = created
    }
}

/// Gives the importer the password a Chromium browser keeps in the Keychain ("Chrome Safe Storage") to protect
/// its saved logins. The real one asks the Keychain, which shows macOS's own "allow access" prompt; tests pass a fake.
public protocol SafeStorageKeyProviding: Sendable {
    func safeStoragePassword(service: String, account: String) throws(ImportFailure) -> Data
}

public struct KeychainSafeStorage: SafeStorageKeyProviding {
    public init() {}

    public func safeStoragePassword(service: String, account: String) throws(ImportFailure) -> Data {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        switch status {
        case errSecSuccess:
            if let data = out as? Data { return data }
            throw ImportFailure(kind: .unreadable, message: "Plinth couldn't read the key that protects the saved passwords.")
        case errSecItemNotFound:
            throw ImportFailure(kind: .notFound, message: "The key that protects the saved passwords wasn't found in your Keychain. Open the browser once, then try again.")
        default:
            // errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed: the person said no, or the Keychain is locked.
            throw ImportFailure(kind: .permissionDenied, message: "Plinth needs access to \"\(service)\" in your Keychain to read the saved passwords. Try again and choose Allow when macOS asks.")
        }
    }
}

extension ImportService {
    /// Saved logins from `source`. Chrome and Arc: the Login Data database, decrypted with the Safe Storage key.
    /// Zen: the profile's logins.json, decrypted with the key in key4.db (no primary password). Safari's passwords
    /// can't be read by other apps: export them from the Passwords app as CSV instead.
    public static func passwords(from source: ImportSource, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                 keys: SafeStorageKeyProviding = KeychainSafeStorage()) throws(ImportFailure) -> [ImportedLogin] {
        switch source {
        case .chrome, .arc: return try ChromiumPasswords.read(source, home: home, keys: keys)
        case .zen: return try FirefoxPasswords.read(home: home)
        case .safari:
            throw ImportFailure(kind: .unreadable, message: "Safari keeps its passwords where other apps can't read them. In the Passwords app choose File > Export All Passwords, then import that CSV file.")
        }
    }
}

// MARK: - Chrome and Arc

enum ChromiumPasswords {
    /// (Keychain service, account) of the browser's "Safe Storage" item.
    static func keychainItem(_ source: ImportSource) -> (service: String, account: String) {
        source == .arc ? ("Arc Safe Storage", "Arc") : ("Chrome Safe Storage", "Chrome")
    }

    /// The AES-128 key Chromium derives on macOS: PBKDF2-HMAC-SHA1(safe-storage password, "saltysalt", 1003 rounds).
    static func key(fromSafeStorage password: Data) -> Data? {
        PasswordCrypto.pbkdf2(.sha1, password: password, salt: Data("saltysalt".utf8), iterations: 1003, keyLength: 16)
    }

    /// "v10" / "v11" + AES-128-CBC (IV of 16 spaces, PKCS#7). nil for anything else or a wrong key.
    static func decrypt(_ blob: Data, key: Data) -> String? {
        guard blob.count > 3, let prefix = String(data: blob.prefix(3), encoding: .ascii), prefix == "v10" || prefix == "v11" else { return nil }
        let iv = Data(repeating: 0x20, count: 16)
        guard let plain = PasswordCrypto.decrypt(.aes, key: key, iv: iv, blob.dropFirst(3)) else { return nil }
        return String(data: plain, encoding: .utf8)
    }

    /// Every profile's Login Data (and the account-synced copy), not just the first, newest Chromium layout included.
    static func loginFiles(home: URL, source: ImportSource) -> [URL] {
        let root = ChromeReader.folder(home, source: source)
        var profiles = ["Default"]
        profiles += ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
            .filter { $0.hasPrefix("Profile ") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        var files: [URL] = []
        for profile in profiles {
            for name in ["Login Data", "Login Data For Account"] {
                let url = root.appendingPathComponent("\(profile)/\(name)")
                if Probe.state(url) == .exists { files.append(url) }
            }
        }
        return files
    }

    static func read(_ source: ImportSource, home: URL, keys: SafeStorageKeyProviding) throws(ImportFailure) -> [ImportedLogin] {
        let files = loginFiles(home: home, source: source)
        if files.isEmpty {
            if Probe.state(ChromeReader.folder(home, source: source)) == .denied { throw Failures.denied(source) }
            throw Failures.notFound(source, "saved passwords")
        }
        let item = keychainItem(source)
        let secret = try keys.safeStoragePassword(service: item.service, account: item.account)
        guard let key = key(fromSafeStorage: secret) else { throw Failures.unreadable(source, "saved passwords") }

        var out: [ImportedLogin] = []
        var undecryptable = 0
        for file in files {
            try withDatabaseCopy(file, source: source, what: "saved passwords") { db throws(ImportFailure) in
                try query(db, "SELECT origin_url, username_value, password_value, date_created FROM logins WHERE blacklisted_by_user = 0",
                          source: source, what: "saved passwords") { row in
                    guard let url = httpURL(text(row, 0)) else { return }
                    let username = text(row, 1)
                    let length = Int(sqlite3_column_bytes(row, 2))
                    guard length > 0, let bytes = sqlite3_column_blob(row, 2) else { return }
                    let blob = Data(bytes: bytes, count: length)
                    guard let password = decrypt(blob, key: key), !password.isEmpty else { undecryptable += 1; return }
                    let created = sqlite3_column_int64(row, 3)
                    out.append(ImportedLogin(url: url, username: username, password: password,
                                             created: created > 0 ? ChromeReader.date(chromeTime: created) : nil))
                }
            }
        }
        if out.isEmpty, undecryptable > 0 {
            throw ImportFailure(kind: .unreadable, message: "Plinth found \(undecryptable) saved password\(undecryptable == 1 ? "" : "s") in \(source.displayName) but couldn't decrypt them. They may use a newer format Plinth doesn't know yet.")
        }
        return out
    }
}

// MARK: - Zen (Firefox)

enum FirefoxPasswords {
    static let masterPasswordMessage = "Zen's saved passwords are protected by a primary password, which Plinth can't unlock yet. In Zen, remove the primary password under Settings > Privacy & Security, or export the logins to CSV and import that file, then try again."

    static func read(home: URL) throws(ImportFailure) -> [ImportedLogin] {
        guard let places = ZenReader.placesFile(home: home) else {
            if Probe.state(ZenReader.folder(home)) == .denied { throw Failures.denied(.zen) }
            throw Failures.notFound(.zen, "saved passwords")
        }
        let profile = places.deletingLastPathComponent()
        let loginsJSON = try readFile(profile.appendingPathComponent("logins.json"), source: .zen, what: "saved passwords")
        let keyDB = profile.appendingPathComponent("key4.db")
        let material = try withDatabaseCopy(keyDB, source: .zen, what: "password key") { db throws(ImportFailure) in
            try readKeyMaterial(db)
        }
        return try decryptLogins(loginsJSON, material: material)
    }

    struct KeyMaterial {
        var globalSalt: Data
        var passwordCheck: Data
        /// (a102 key id, a11 encrypted key) pairs from nssPrivate.
        var keys: [(id: Data, blob: Data)]
    }

    static func readKeyMaterial(_ db: OpaquePointer) throws(ImportFailure) -> KeyMaterial {
        func blob(_ row: OpaquePointer, _ column: Int32) -> Data {
            let n = Int(sqlite3_column_bytes(row, column))
            guard n > 0, let p = sqlite3_column_blob(row, column) else { return Data() }
            return Data(bytes: p, count: n)
        }
        var salt = Data(), check = Data()
        try query(db, "SELECT item1, item2 FROM metaData WHERE id = 'password'", source: .zen, what: "password key") { row in
            salt = blob(row, 0); check = blob(row, 1)
        }
        var keys: [(Data, Data)] = []
        try query(db, "SELECT a11, a102 FROM nssPrivate", source: .zen, what: "password key") { row in
            let a11 = blob(row, 0)
            if !a11.isEmpty { keys.append((blob(row, 1), a11)) }
        }
        guard !salt.isEmpty, !check.isEmpty, !keys.isEmpty else { throw Failures.unreadable(.zen, "password key") }
        return KeyMaterial(globalSalt: salt, passwordCheck: check, keys: keys.map { (id: $0.0, blob: $0.1) })
    }

    /// Decrypts a PBE-wrapped blob: SEQUENCE { SEQUENCE { algorithm OID, parameters }, OCTET STRING ciphertext }.
    /// Handles NSS's two schemes: the legacy SHA-1 / 3DES one and PBES2 (PBKDF2-SHA256 + AES-256-CBC).
    static func decryptPBE(_ blob: Data, globalSalt: Data, password: Data = Data()) -> Data? {
        guard let root = DERNode.parse(blob), let top = root.children, top.count == 2,
              let algorithm = top[0].children, algorithm.count == 2, algorithm[0].tag == DERNode.oid,
              top[1].tag == DERNode.octetString else { return nil }
        let oid = algorithm[0].content
        let ciphertext = top[1].content
        if oid == OID.pbeSHA1TripleDES {
            guard let params = algorithm[1].children, params.count >= 1, params[0].tag == DERNode.octetString else { return nil }
            let entrySalt = params[0].content
            let hp = PasswordCrypto.sha1(globalSalt + password)
            let pes = entrySalt + Data(repeating: 0, count: max(0, 20 - entrySalt.count))
            let chp = PasswordCrypto.sha1(hp + entrySalt)
            let k1 = PasswordCrypto.hmacSHA1(key: chp, pes + entrySalt)
            let tk = PasswordCrypto.hmacSHA1(key: chp, pes)
            let k2 = PasswordCrypto.hmacSHA1(key: chp, tk + entrySalt)
            let k = k1 + k2
            return PasswordCrypto.decrypt(.tripleDES, key: k.prefix(24), iv: k.suffix(8), ciphertext)
        }
        if oid == OID.pbes2 {
            guard let params = algorithm[1].children, params.count == 2,
                  let kdf = params[0].children, kdf.count == 2, kdf[0].content == OID.pbkdf2,
                  let kdfParams = kdf[1].children, kdfParams.count >= 2, kdfParams[0].tag == DERNode.octetString,
                  let iterations = kdfParams[1].intValue,
                  let enc = params[1].children, enc.count == 2, enc[0].content == OID.aes256CBC,
                  enc[1].tag == DERNode.octetString else { return nil }
            var keyLength = 32
            if kdfParams.count >= 3, let n = kdfParams[2].intValue { keyLength = n }
            guard keyLength == 32, iterations > 0, iterations <= 10_000_000 else { return nil }
            // NSS stores a 14-byte IV and prepends 04 0E (an OCTET STRING header) to make the 16 AES needs.
            var iv = enc[1].content
            if iv.count == 14 { iv = Data([0x04, 0x0E]) + iv }
            let seed = PasswordCrypto.sha1(globalSalt + password)
            guard let key = PasswordCrypto.pbkdf2(.sha256, password: seed, salt: kdfParams[0].content, iterations: iterations, keyLength: 32) else { return nil }
            return PasswordCrypto.decrypt(.aes, key: key, iv: iv, ciphertext)
        }
        return nil
    }

    /// The key that encrypts logins.json values, or a clear failure when a primary password is set.
    static func loginKey(_ material: KeyMaterial, preferring keyID: Data?) throws(ImportFailure) -> Data {
        // With no primary password the check value decrypts under the empty password to "password-check".
        guard let check = decryptPBE(material.passwordCheck, globalSalt: material.globalSalt),
              check.starts(with: Data("password-check".utf8)) else {
            throw ImportFailure(kind: .unreadable, message: masterPasswordMessage)
        }
        let candidates = material.keys.filter { keyID == nil || $0.id == keyID } + material.keys
        for candidate in candidates {
            guard let key = decryptPBE(candidate.blob, globalSalt: material.globalSalt) else { continue }
            // 3DES keys are 24 bytes, AES keys 32; some stores pad the value.
            if key.count >= 32 { return key.prefix(32) }
            if key.count >= 24 { return key.prefix(24) }
        }
        throw Failures.unreadable(.zen, "password key")
    }

    /// One logins.json value: SEQUENCE { OCTET STRING keyId, SEQUENCE { cipher OID, OCTET STRING iv }, OCTET STRING ciphertext }.
    static func decryptField(_ base64: String, key: Data) -> String? {
        guard let blob = Data(base64Encoded: base64), let root = DERNode.parse(blob), let parts = root.children, parts.count == 3,
              let alg = parts[1].children, alg.count == 2, alg[1].tag == DERNode.octetString,
              parts[2].tag == DERNode.octetString else { return nil }
        let cipher: PasswordCrypto.Cipher
        if alg[0].content == OID.tripleDESCBC { cipher = .tripleDES }
        else if alg[0].content == OID.aes256CBC { cipher = .aes }
        else { return nil }
        let usable = cipher == .aes ? key.prefix(32) : key.prefix(24)
        guard usable.count == (cipher == .aes ? 32 : 24),
              let plain = PasswordCrypto.decrypt(cipher, key: Data(usable), iv: alg[1].content, parts[2].content) else { return nil }
        return String(data: plain, encoding: .utf8)
    }

    static func keyID(of base64: String) -> Data? {
        guard let blob = Data(base64Encoded: base64), let root = DERNode.parse(blob), let parts = root.children,
              let first = parts.first, first.tag == DERNode.octetString else { return nil }
        return first.content
    }

    static func decryptLogins(_ json: Data, material: KeyMaterial) throws(ImportFailure) -> [ImportedLogin] {
        guard let doc = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any],
              let logins = doc["logins"] as? [[String: Any]] else { throw Failures.unreadable(.zen, "saved passwords") }
        let firstID = logins.compactMap { ($0["encryptedPassword"] as? String).flatMap(keyID(of:)) }.first
        if logins.isEmpty { return [] }
        let key = try loginKey(material, preferring: firstID)
        var out: [ImportedLogin] = []
        for login in logins {
            guard let host = login["hostname"] as? String, let url = httpURL(host),
                  let encPassword = login["encryptedPassword"] as? String, let password = decryptField(encPassword, key: key),
                  !password.isEmpty else { continue }
            let username = (login["encryptedUsername"] as? String).flatMap { decryptField($0, key: key) } ?? ""
            let created = (login["timeCreated"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
            out.append(ImportedLogin(url: url, username: username, password: password, created: created))
        }
        return out
    }
}
