import Foundation
import Testing
@testable import PlinthImport

// Every secret here is made up. Nothing reads a real profile or the real Keychain: the fake home is a
// temp folder and the Safe Storage password comes from `FakeKeys`.

private func hex(_ s: String) -> Data {
    var data = Data()
    var i = s.startIndex
    while i < s.endIndex { let j = s.index(i, offsetBy: 2); data.append(UInt8(s[i..<j], radix: 16)!); i = j }
    return data
}

private func hexLiteral(_ d: Data) -> String { "X'" + d.map { String(format: "%02x", $0) }.joined() + "'" }

// MARK: - DER writer (the tests build blobs the way NSS does)

private func der(_ tag: UInt8, _ content: Data) -> Data {
    var out = Data([tag])
    if content.count < 128 { out.append(UInt8(content.count)) }
    else if content.count < 256 { out += [0x81, UInt8(content.count)] }
    else { out += [0x82, UInt8(content.count >> 8), UInt8(content.count & 0xFF)] }
    return out + content
}
private func seq(_ parts: Data...) -> Data { der(0x30, parts.reduce(Data(), +)) }
private func oct(_ d: Data) -> Data { der(0x04, d) }
private func int(_ n: Int) -> Data { der(0x02, n < 128 ? Data([UInt8(n)]) : Data([UInt8(n >> 8), UInt8(n & 0xFF)])) }
private func oid(_ d: Data) -> Data { der(0x06, d) }
private let null = Data([0x05, 0x00])
private let hmacSHA256 = Data([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x02, 0x09])

private struct FakeKeys: SafeStorageKeyProviding {
    var password: Data?
    var failure: ImportFailure?
    func safeStoragePassword(service: String, account: String) throws(ImportFailure) -> Data {
        if let failure { throw failure }
        return password ?? Data()
    }
}

// MARK: - Chrome and Arc

private let chromeSecret = Data("FakeSafeStoragePassword==".utf8)

private func chromeBlob(_ password: String, secret: Data = chromeSecret) -> Data {
    let key = ChromiumPasswords.key(fromSafeStorage: secret)!
    return Data("v10".utf8) + PasswordCrypto.encrypt(.aes, key: key, iv: Data(repeating: 0x20, count: 16), Data(password.utf8))!
}

private func writeLoginData(_ dir: URL, rows: [(url: String, user: String, blob: Data, blocked: Int)], name: String = "Login Data") {
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var sql = ["CREATE TABLE logins (origin_url TEXT, action_url TEXT, username_value TEXT, password_value BLOB, date_created INTEGER, blacklisted_by_user INTEGER)"]
    for r in rows {
        sql.append("INSERT INTO logins VALUES ('\(r.url)', '', '\(r.user)', \(hexLiteral(r.blob)), 13300000000000000, \(r.blocked))")
    }
    makeSQLite(dir.appendingPathComponent(name), sql)
}

@Suite struct ChromiumPasswordTests {
    @Test func knownAnswerFromAnIndependentImplementation() {
        // Key and blob made with Python's pbkdf2_hmac and `openssl enc -aes-128-cbc`, not with this code.
        let key = ChromiumPasswords.key(fromSafeStorage: chromeSecret)!
        #expect(key == hex("1ffa073df486cae0e5720af62fe87f2b"))
        let blob = hex("763130821f77ba5bfaa2e60cb7e9241caf1f8cb97a54116987cb95f368df779695cd03")
        #expect(ChromiumPasswords.decrypt(blob, key: key) == "hunter2-chromium")
    }

    @Test func rejectsWrongKeysUnknownPrefixesAndShortBlobs() {
        let key = ChromiumPasswords.key(fromSafeStorage: chromeSecret)!
        let other = ChromiumPasswords.key(fromSafeStorage: Data("another".utf8))!
        let blob = chromeBlob("pw")
        #expect(ChromiumPasswords.decrypt(blob, key: other) != "pw")
        #expect(ChromiumPasswords.decrypt(Data("v20".utf8) + blob.dropFirst(3), key: key) == nil)
        #expect(ChromiumPasswords.decrypt(Data("v10".utf8), key: key) == nil)
        #expect(ChromiumPasswords.decrypt(Data(), key: key) == nil)
        #expect(ChromiumPasswords.decrypt(Data("v10".utf8) + Data(repeating: 1, count: 7), key: key) == nil)
    }

    @Test func importsLoginsFromEveryProfileSkippingNeverSavedSites() throws {
        let home = FakeHome()
        let root = ChromeReader.folder(home.url)
        writeLoginData(root.appendingPathComponent("Default"), rows: [
            ("https://example.com/login", "amy", chromeBlob("pw-one"), 0),
            ("https://blocked.test/", "", Data(), 1),
            ("chrome://settings", "x", chromeBlob("nope"), 0),
        ])
        writeLoginData(root.appendingPathComponent("Profile 2"), rows: [("https://other.test/", "bob", chromeBlob("pw-two"), 0)])
        let logins = try ImportService.passwords(from: .chrome, home: home.url, keys: FakeKeys(password: chromeSecret))
        #expect(logins.map(\.username) == ["amy", "bob"])
        #expect(logins.map(\.password) == ["pw-one", "pw-two"])
        #expect(logins[0].url.host == "example.com")
        #expect(logins[0].created != nil)
    }

    @Test func arcUsesItsOwnFolderAndKeychainItem() throws {
        let home = FakeHome()
        let secret = Data("ArcSecret".utf8)
        writeLoginData(ChromeReader.folder(home.url, source: .arc).appendingPathComponent("Default"), rows: [("https://a.test/", "cy", chromeBlob("arc-pw", secret: secret), 0)])
        let logins = try ImportService.passwords(from: .arc, home: home.url, keys: FakeKeys(password: secret))
        #expect(logins.map(\.password) == ["arc-pw"])
        #expect(ChromiumPasswords.keychainItem(.arc) == ("Arc Safe Storage", "Arc"))
        #expect(ChromiumPasswords.keychainItem(.chrome) == ("Chrome Safe Storage", "Chrome"))
    }

    @Test func aWrongKeyReportsUndecryptablePasswordsInsteadOfGarbage() {
        let home = FakeHome()
        writeLoginData(ChromeReader.folder(home.url).appendingPathComponent("Default"), rows: [("https://a.test/", "cy", chromeBlob("pw"), 0)])
        #expect(throws: ImportFailure.self) {
            _ = try ImportService.passwords(from: .chrome, home: home.url, keys: FakeKeys(password: Data("wrong key".utf8)))
        }
    }

    @Test func keychainDenialAndMissingFilesAreReported() {
        let home = FakeHome()
        #expect(throws: ImportFailure.self) { _ = try ImportService.passwords(from: .chrome, home: home.url, keys: FakeKeys(password: chromeSecret)) }
        writeLoginData(ChromeReader.folder(home.url).appendingPathComponent("Default"), rows: [("https://a.test/", "cy", chromeBlob("pw"), 0)])
        let denied = ImportFailure(kind: .permissionDenied, message: "no")
        do throws(ImportFailure) {
            _ = try ImportService.passwords(from: .chrome, home: home.url, keys: FakeKeys(failure: denied))
            Issue.record("should have thrown")
        } catch { #expect(error == denied) }
    }

    @Test func theOriginalDatabaseIsNeverModified() throws {
        let home = FakeHome()
        let dir = ChromeReader.folder(home.url).appendingPathComponent("Default")
        writeLoginData(dir, rows: [("https://a.test/", "cy", chromeBlob("pw"), 0)])
        let before = try Data(contentsOf: dir.appendingPathComponent("Login Data"))
        _ = try ImportService.passwords(from: .chrome, home: home.url, keys: FakeKeys(password: chromeSecret))
        #expect(try Data(contentsOf: dir.appendingPathComponent("Login Data")) == before)
    }

    @Test func safariPointsToTheCSVExport() {
        #expect(throws: ImportFailure.self) { _ = try ImportService.passwords(from: .safari) }
    }
}

// MARK: - Zen (Firefox NSS)

private let globalSalt = hex("000102030405060708090a0b0c0d0e0f10111213")

/// Legacy NSS PBE (SHA-1 key schedule + 3DES), built independently of the decryptor for the round-trip tests.
private func legacyPBE(_ plain: Data, entrySalt: Data, globalSalt: Data, password: Data = Data()) -> Data {
    let hp = PasswordCrypto.sha1(globalSalt + password)
    let pes = entrySalt + Data(repeating: 0, count: 20 - entrySalt.count)
    let chp = PasswordCrypto.sha1(hp + entrySalt)
    let k1 = PasswordCrypto.hmacSHA1(key: chp, pes + entrySalt)
    let tk = PasswordCrypto.hmacSHA1(key: chp, pes)
    let k2 = PasswordCrypto.hmacSHA1(key: chp, tk + entrySalt)
    let k = k1 + k2
    let ct = PasswordCrypto.encrypt(.tripleDES, key: k.prefix(24), iv: k.suffix(8), plain)!
    return seq(seq(oid(OID.pbeSHA1TripleDES), seq(oct(entrySalt), int(1))), oct(ct))
}

private func pbes2(_ plain: Data, salt: Data, iv14: Data, iterations: Int = 10, globalSalt: Data, password: Data = Data()) -> Data {
    let seed = PasswordCrypto.sha1(globalSalt + password)
    let key = PasswordCrypto.pbkdf2(.sha256, password: seed, salt: salt, iterations: iterations, keyLength: 32)!
    let ct = PasswordCrypto.encrypt(.aes, key: key, iv: Data([0x04, 0x0E]) + iv14, plain)!
    let kdf = seq(oid(OID.pbkdf2), seq(oct(salt), int(iterations), int(32), seq(oid(hmacSHA256), null)))
    let enc = seq(oid(OID.aes256CBC), oct(iv14))
    return seq(seq(oid(OID.pbes2), seq(kdf, enc)), oct(ct))
}

private func field(_ plain: String, key: Data, keyID: Data, aes: Bool, iv: Data) -> String {
    let ct = PasswordCrypto.encrypt(aes ? .aes : .tripleDES, key: key, iv: iv, Data(plain.utf8))!
    let alg = seq(oid(aes ? OID.aes256CBC : OID.tripleDESCBC), oct(iv))
    return seq(oct(keyID), alg, oct(ct)).base64EncodedString()
}

enum PWScheme { case legacy, modern }

struct ZenFixture {
    var scheme: PWScheme
    var passwordProtected = false
    var logins: [(host: String, user: String, password: String)]
}

private let keyID = hex("f8000000000000000000000000000001")

private func writeZenPasswords(_ home: FakeHome, _ f: ZenFixture) {
    let root = home.url.appendingPathComponent("Library/Application Support/zen")
    let profile = root.appendingPathComponent("Profiles/abc.Default (release)")
    home.dir(profile)
    try! "[Profile0]\nName=x\nIsRelative=1\nPath=Profiles/abc.Default (release)\nDefault=1\n".write(to: root.appendingPathComponent("profiles.ini"), atomically: true, encoding: .utf8)
    makeSQLite(profile.appendingPathComponent("places.sqlite"), ["CREATE TABLE moz_places (id INTEGER PRIMARY KEY, url TEXT, title TEXT)"])

    let key3DES = Data((1...24).map { UInt8($0) })
    let keyAES = Data((1...32).map { UInt8(0x40 + $0) })
    let loginKey = f.scheme == .legacy ? key3DES : keyAES
    let userPassword = f.passwordProtected ? Data("primary".utf8) : Data()
    let entrySalt = hex("6465666768696a6b6c6d6e6f7071727374757677")
    let check: Data, a11: Data
    switch f.scheme {
    case .legacy:
        check = legacyPBE(Data("password-check".utf8), entrySalt: entrySalt, globalSalt: globalSalt, password: userPassword)
        a11 = legacyPBE(loginKey, entrySalt: entrySalt, globalSalt: globalSalt, password: userPassword)
    case .modern:
        check = pbes2(Data("password-check".utf8), salt: Data((32..<64).map { UInt8($0) }), iv14: Data((1...14).map { UInt8($0) }), globalSalt: globalSalt, password: userPassword)
        a11 = pbes2(loginKey, salt: Data((64..<96).map { UInt8($0) }), iv14: Data((20...33).map { UInt8($0) }), globalSalt: globalSalt, password: userPassword)
    }
    makeSQLite(profile.appendingPathComponent("key4.db"), [
        "CREATE TABLE metaData (id TEXT PRIMARY KEY, item1, item2)",
        "INSERT INTO metaData VALUES ('password', \(hexLiteral(globalSalt)), \(hexLiteral(check)))",
        "CREATE TABLE nssPrivate (id INTEGER PRIMARY KEY, a11, a102)",
        "INSERT INTO nssPrivate VALUES (1, \(hexLiteral(a11)), \(hexLiteral(keyID)))",
    ])

    let aes = f.scheme == .modern
    var entries: [[String: Any]] = []
    for (i, l) in f.logins.enumerated() {
        let iv = aes ? Data((0..<16).map { UInt8($0 + i) }) : Data((0..<8).map { UInt8(200 + $0 + i) })
        entries.append(["hostname": l.host, "encryptedUsername": field(l.user, key: loginKey, keyID: keyID, aes: aes, iv: iv),
                        "encryptedPassword": field(l.password, key: loginKey, keyID: keyID, aes: aes, iv: iv),
                        "timeCreated": 1_700_000_000_000])
    }
    let doc: [String: Any] = ["nextId": 9, "logins": entries]
    try! JSONSerialization.data(withJSONObject: doc).write(to: profile.appendingPathComponent("logins.json"))
}

@Suite struct FirefoxPasswordTests {
    @Test func legacyPBEMatchesAnIndependentImplementation() {
        // Made with Python hashlib/hmac and `openssl enc -des-ede3-cbc`.
        let blob = seq(seq(oid(OID.pbeSHA1TripleDES), seq(oct(hex("6465666768696a6b6c6d6e6f7071727374757677")), int(1))),
                       oct(hex("d7833eb73a9a703abf9a8ac5573a1c73")))
        #expect(FirefoxPasswords.decryptPBE(blob, globalSalt: globalSalt) == Data("password-check".utf8))
    }

    @Test func pbes2MatchesAnIndependentImplementation() {
        // Made with Python hashlib.pbkdf2_hmac and `openssl enc -aes-256-cbc`.
        let salt = hex("202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f")
        let kdf = seq(oid(OID.pbkdf2), seq(oct(salt), int(10), int(32), seq(oid(hmacSHA256), null)))
        let blob = seq(seq(oid(OID.pbes2), seq(kdf, seq(oid(OID.aes256CBC), oct(hex("0102030405060708090a0b0c0d0e"))))),
                       oct(hex("1c6ceb02aaee2828c0068de784c9a161")))
        #expect(FirefoxPasswords.decryptPBE(blob, globalSalt: globalSalt) == Data("password-check".utf8))
    }

    @Test(arguments: [PWScheme.legacy, PWScheme.modern])
    func importsFromAFirefoxProfile(_ scheme: PWScheme) throws {
        let home = FakeHome()
        writeZenPasswords(home, ZenFixture(scheme: scheme, logins: [
            ("https://example.com", "amy@example.com", "correct horse"),
            ("http://intranet.local:8080", "bob", "päss wörd ✓"),
            ("chrome://FirefoxAccounts", "ignored", "x"),
        ]))
        let logins = try ImportService.passwords(from: .zen, home: home.url)
        #expect(logins.map(\.username) == ["amy@example.com", "bob"])
        #expect(logins.map(\.password) == ["correct horse", "päss wörd ✓"])
        #expect(logins[1].url.absoluteString.hasPrefix("http://intranet.local:8080"))
        #expect(logins[0].created == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test(arguments: [PWScheme.legacy, PWScheme.modern])
    func aPrimaryPasswordIsReportedClearly(_ scheme: PWScheme) {
        let home = FakeHome()
        writeZenPasswords(home, ZenFixture(scheme: scheme, passwordProtected: true, logins: [("https://example.com", "amy", "pw")]))
        do throws(ImportFailure) {
            _ = try ImportService.passwords(from: .zen, home: home.url)
            Issue.record("should have thrown")
        } catch {
            #expect(error.message == FirefoxPasswords.masterPasswordMessage)
            #expect(error.message.contains("primary password"))
        }
    }

    @Test func missingProfileOrFilesAreReported() {
        let home = FakeHome()
        #expect(throws: ImportFailure.self) { _ = try ImportService.passwords(from: .zen, home: home.url) }
        writeZenPasswords(home, ZenFixture(scheme: .legacy, logins: []))
        let profile = home.url.appendingPathComponent("Library/Application Support/zen/Profiles/abc.Default (release)")
        try? FileManager.default.removeItem(at: profile.appendingPathComponent("logins.json"))
        #expect(throws: ImportFailure.self) { _ = try ImportService.passwords(from: .zen, home: home.url) }
    }

    @Test func damagedBlobsAreSkippedNotFatal() throws {
        let home = FakeHome()
        writeZenPasswords(home, ZenFixture(scheme: .legacy, logins: [("https://a.test", "amy", "pw")]))
        let file = home.url.appendingPathComponent("Library/Application Support/zen/Profiles/abc.Default (release)/logins.json")
        var doc = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        var logins = doc["logins"] as! [[String: Any]]
        logins.append(["hostname": "https://b.test", "encryptedUsername": "AAAA", "encryptedPassword": "AAAA"])
        doc["logins"] = logins
        try JSONSerialization.data(withJSONObject: doc).write(to: file)
        #expect(try ImportService.passwords(from: .zen, home: home.url).map(\.password) == ["pw"])
    }

    @Test func derParserHandlesLongFormLengthsAndRejectsTruncation() {
        let big = Data(repeating: 7, count: 300)
        let node = DERNode.parse(oct(big))
        #expect(node?.content == big)
        #expect(DERNode.parse(oct(big).dropLast()) == nil)
        #expect(DERNode.parse(Data([0x30])) == nil)
    }
}
