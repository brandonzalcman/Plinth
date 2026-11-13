import Foundation
import Testing
@testable import PlinthPasswords

func origin(_ s: String) -> WebOrigin { WebOrigin(string: s)! }

@Suite struct WebOriginTests {
    @Test func normalisesSchemeHostAndDefaultPorts() {
        #expect(origin("HTTPS://Example.COM:443/login?x=1").description == "https://example.com")
        #expect(origin("http://example.com:80").description == "http://example.com")
        #expect(origin("http://localhost:3000/a").description == "http://localhost:3000")
        #expect(origin("example.com").description == "https://example.com")
        #expect(WebOrigin(string: "ftp://example.com") == nil)
        #expect(WebOrigin(string: "") == nil)
    }

    @Test func fillMatchesTheExactOriginOnly() {
        let saved = origin("https://example.com")
        #expect(WebOrigin.mayFill(saved: saved, into: origin("https://example.com/other/path")))
        #expect(!WebOrigin.mayFill(saved: saved, into: origin("https://www.example.com")))
        #expect(!WebOrigin.mayFill(saved: saved, into: origin("https://login.example.com")))
        #expect(!WebOrigin.mayFill(saved: saved, into: origin("https://example.com:8443")))
        #expect(!WebOrigin.mayFill(saved: saved, into: origin("https://example.com.evil.test")))
    }

    @Test func neverFillsAcrossAnHTTPSToHTTPDowngrade() {
        #expect(!WebOrigin.mayFill(saved: origin("https://example.com"), into: origin("http://example.com")))
    }

    @Test func formActionMustStayOnTheOrigin() {
        let page = origin("https://example.com")
        #expect(WebOrigin.formActionAllowed(page: page, action: nil))
        #expect(WebOrigin.formActionAllowed(page: page, action: ""))
        #expect(WebOrigin.formActionAllowed(page: page, action: "/session"))
        #expect(WebOrigin.formActionAllowed(page: page, action: "https://example.com/session"))
        #expect(!WebOrigin.formActionAllowed(page: page, action: "https://evil.test/collect"))
        #expect(!WebOrigin.formActionAllowed(page: page, action: "http://example.com/session"))
        #expect(!WebOrigin.formActionAllowed(page: page, action: "data:text/html,x"))
        // http page posting to https on the same host is an upgrade, which is fine.
        #expect(WebOrigin.formActionAllowed(page: origin("http://example.com"), action: "https://example.com/s"))
    }

    @Test func displayHostDropsWWW() {
        #expect(origin("https://www.example.com").displayHost == "example.com")
        #expect(origin("http://localhost:3000").displayHost == "localhost:3000")
    }
}

@Suite struct VaultTests {
    private func login(_ site: String, _ user: String, _ pw: String = "pw") -> Login {
        Login(origin: origin(site), username: user, password: pw, created: Date(timeIntervalSince1970: 1000))
    }

    @Test func saveListAndRead() throws {
        let vault = InMemoryVault()
        try vault.save(login("https://b.com", "bob", "secret"))
        try vault.save(login("https://a.com", "amy"))
        #expect(try vault.list().map(\.username) == ["amy", "bob"])
        #expect(try vault.password(for: LoginKey(origin: origin("https://b.com"), username: "bob")) == "secret")
        #expect(try vault.password(for: LoginKey(origin: origin("https://b.com"), username: "nobody")) == nil)
    }

    @Test func saveReplacesSameSiteAndUserKeepingCreated() throws {
        let vault = InMemoryVault()
        try vault.save(login("https://a.com", "amy", "one"))
        try vault.save(Login(origin: origin("https://a.com"), username: "amy", password: "two", created: Date(timeIntervalSince1970: 5000)))
        let all = try vault.list()
        #expect(all.count == 1)
        #expect(all[0].created == Date(timeIntervalSince1970: 1000))
        #expect(try vault.password(for: all[0].key) == "two")
    }

    @Test func lookupIsByExactOrigin() throws {
        let vault = InMemoryVault([login("https://a.com", "amy"), login("http://a.com", "insecure"), login("https://www.a.com", "www")])
        #expect(try vault.logins(for: origin("https://a.com")).map(\.username) == ["amy"])
        #expect(try vault.logins(for: origin("http://a.com")).map(\.username) == ["insecure"])
    }

    @Test func deleteAndMissingDelete() throws {
        let vault = InMemoryVault([login("https://a.com", "amy")])
        let key = LoginKey(origin: origin("https://a.com"), username: "amy")
        try vault.delete(key)
        #expect(try vault.list().isEmpty)
        #expect(throws: VaultError.notFound) { try vault.delete(key) }
    }

    @Test func replaceCanRenameTheUserAndSite() throws {
        let vault = InMemoryVault([login("https://a.com", "amy", "one")])
        let old = LoginKey(origin: origin("https://a.com"), username: "amy")
        try vault.replace(old, with: login("https://b.com", "amelia", "two"))
        let all = try vault.list()
        #expect(all.map(\.username) == ["amelia"])
        #expect(try vault.password(for: all[0].key) == "two")
    }

    @Test func mergeSkipsExistingAndCountsFailures() throws {
        let vault = InMemoryVault([login("https://a.com", "amy", "keep")])
        let result = vault.merge([login("https://a.com", "amy", "overwrite?"), login("https://a.com", "bob"), login("https://c.com", "cy")])
        #expect(result == MergeResult(added: 2, duplicates: 1, failed: 0))
        #expect(try vault.password(for: LoginKey(origin: origin("https://a.com"), username: "amy")) == "keep")
    }

    @Test func failuresPropagate() {
        let vault = InMemoryVault()
        vault.failure = .keychain(status: -25293)
        #expect(throws: VaultError.keychain(status: -25293)) { try vault.list() }
    }
}

@Suite struct CSVTests {
    @Test func parsesChromeExport() throws {
        let csv = "name,url,username,password,note\nexample,https://example.com/login,amy,p@ss,\nbad,not a url,x,y,\n"
        let result = try CSVImport.parse(csv)
        #expect(result.logins.count == 1)
        #expect(result.logins[0].origin == origin("https://example.com"))
        #expect(result.logins[0].username == "amy")
        #expect(result.logins[0].password == "p@ss")
        #expect(result.skipped == 1)
    }

    @Test func parsesSafariExportWithQuotesAndCRLF() throws {
        let csv = "Title,URL,Username,Password,Notes,OTPAuth\r\nSite,https://a.com,\"bob, jr\",\"pa\"\"ss\",\"line1\nline2\",\r\n"
        let result = try CSVImport.parse(csv)
        #expect(result.logins.count == 1)
        #expect(result.logins[0].username == "bob, jr")
        #expect(result.logins[0].password == "pa\"ss")
    }

    @Test func rejectsFilesWithoutTheRightColumns() {
        #expect(throws: CSVImport.Failure.unrecognised) { try CSVImport.parse("a,b\n1,2\n") }
        #expect(throws: CSVImport.Failure.unrecognised) { try CSVImport.parse("") }
    }
}

@MainActor
@Suite struct PreferencesTests {
    @Test func persistsNeverListAndSwitch() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("plinth-pw-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let prefs = PasswordPreferences(storageDirectory: dir)
        #expect(prefs.offerToSave)
        prefs.addNever(origin("https://a.com"))
        prefs.addNever(origin("https://a.com"))
        prefs.setOfferToSave(false)
        let again = PasswordPreferences(storageDirectory: dir)
        #expect(again.neverSave == [origin("https://a.com")])
        #expect(!again.offerToSave)
        again.removeNever(origin("https://a.com"))
        #expect(again.neverSave.isEmpty)
    }
}
