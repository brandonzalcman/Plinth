import Testing
import Foundation
import AuthenticationServices
@testable import PlinthPasswords

struct ApplePasswordsTests {
    private func login(_ site: String, _ user: String, _ password: String, modified: Date = Date(timeIntervalSince1970: 100)) -> Login {
        Login(origin: WebOrigin(string: site)!, username: user, password: password, created: modified)
    }

    @Test func csvRoundTripsThroughTheImporter() throws {
        let logins = [login("https://example.com", "ann@x.com", "pa,ss\"word"), login("http://localhost:3000", "bob", "line1\nline2")]
        let csv = ApplePasswordsCSV.export(logins)
        #expect(csv.hasPrefix("Title,URL,Username,Password,Notes,OTPAuth\r\n"))
        let parsed = try CSVImport.parse(csv)
        #expect(parsed.skipped == 0)
        #expect(parsed.logins.map(\.key) == logins.map(\.key))
        #expect(parsed.logins.map(\.password) == logins.map(\.password))
    }

    @Test func ledgerOffersNewAndEditedLoginsOnly() {
        let a = LoginSummary(origin: WebOrigin(string: "https://a.com")!, username: "u", created: Date(timeIntervalSince1970: 10), modified: Date(timeIntervalSince1970: 10))
        var b = LoginSummary(origin: WebOrigin(string: "https://b.com")!, username: "u", created: Date(timeIntervalSince1970: 10), modified: Date(timeIntervalSince1970: 10))
        var ledger = ApplePasswordsLedger()
        #expect(ledger.waiting(in: [a, b]).count == 2)
        ledger.markInStep([a, b], at: Date(timeIntervalSince1970: 50))
        #expect(ledger.waiting(in: [a, b]).isEmpty)
        b.modified = Date(timeIntervalSince1970: 60)
        #expect(ledger.waiting(in: [a, b]).map(\.id) == [b.id])
        let data = try! JSONEncoder().encode(ledger)
        #expect(try! JSONDecoder().decode(ApplePasswordsLedger.self, from: data) == ledger)
    }

    @Test func exchangeDataRoundTripsWebLogins() {
        let logins = [login("https://example.com", "ann", "s3cret"), login("https://shop.example.org:8443", "bob", "hunter2")]
        let data = CredentialExchange.exportedData(from: logins)
        #expect(data.accounts.flatMap(\.items).count == 2)
        let back = CredentialExchange.logins(from: data)
        #expect(back.skipped == 0)
        #expect(back.logins.map(\.key) == logins.map(\.key))
        #expect(back.logins.map(\.password) == logins.map(\.password))
    }

    @Test func exchangeSkipsItemsThatAreNotWebLogins() {
        let note = ASImportableItem(id: Data([1]), created: Date(), lastModified: Date(), title: "Note", credentials: [.note(.init(content: ASImportableEditableField(id: nil, fieldType: .string, value: "hi")))])
        let noUser = ASImportableItem(id: Data([2]), created: Date(), lastModified: Date(), title: "x", scope: ASImportableCredentialScope(urls: [URL(string: "https://x.com")!]),
                                      credentials: [.basicAuthentication(.init(userName: nil, password: ASImportableEditableField(id: nil, fieldType: .concealedString, value: "pw")))])
        let account = ASImportableAccount(id: Data([0]), userName: "", email: "", collections: [], items: [note, noUser])
        let data = ASExportedCredentialData(accounts: [account], formatVersion: .v1, exporterRelyingPartyIdentifier: "x", exporterDisplayName: "X", timestamp: Date())
        let result = CredentialExchange.logins(from: data)
        #expect(result.logins.isEmpty)
        #expect(result.skipped == 2)
    }

    @MainActor @Test func preferencesRememberWhatWasSent() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let a = LoginSummary(origin: WebOrigin(string: "https://a.com")!, username: "u", created: Date(timeIntervalSince1970: 10), modified: Date(timeIntervalSince1970: 10))
        let prefs = PasswordPreferences(storageDirectory: dir)
        prefs.markInApplePasswords([a])
        #expect(PasswordPreferences(storageDirectory: dir).applePasswords.waiting(in: [a]).isEmpty)
    }

    @Test func importKeepsDifferingPasswordsWaiting() throws {
        let same = Login(origin: WebOrigin(string: "https://same.com")!, username: "u", password: "pw")
        let differs = Login(origin: WebOrigin(string: "https://differs.com")!, username: "u", password: "plinth")
        let vault = InMemoryVault([same, differs])
        let fromApple = [same,
                         Login(origin: differs.origin, username: "u", password: "apple"),
                         Login(origin: WebOrigin(string: "https://new.com")!, username: "u", password: "n")]
        let (merged, inStep) = vault.mergeFromApple(fromApple)
        #expect(merged.added == 1)
        #expect(merged.duplicates == 2)
        let hosts = Set(inStep.map { $0.origin.description })
        #expect(hosts == ["https://same.com", "https://new.com"])
        #expect(try vault.password(for: differs.key) == "plinth")
    }
}
