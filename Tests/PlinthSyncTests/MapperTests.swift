import CloudKit
import Foundation
import Testing
import PlinthModel
@testable import PlinthSync

@Suite struct MapperTests {
    let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test func pinRecordsCarryOnlyIdentityAndOrder() {
        var pin = makePin("mail.example.com", name: "Mail")
        pin.page.scrollY = 900; pin.page.dwell = 50; pin.page.url = url("https://mail.example.com/inbox/42")
        let recs = RecordMapper.pinRecords([pin, makePin("b.com")])
        #expect(recs.map(\.recordName) == ["pin-mail.example.com", "pin-b.com"])
        #expect(Set(recs[0].fields.keys) == ["key", "name", "homeURL", "order"])
        #expect(recs[0]["homeURL"]?.stringValue == "https://mail.example.com/")
        #expect(recs[1]["order"]?.intValue == 1)
    }

    @Test func pinsReuseLocalPageOrMakeFreshOne() {
        var local = makePin("a.com", name: "Old")
        local.page.scrollY = 300
        local.page.url = url("https://a.com/deep")
        var recs = RecordMapper.pinRecords([makePin("b.com", name: "B"), makePin("a.com", name: "New")])
        recs[0].fields["homeURL"] = .string("https://b.com/home")
        let pins = RecordMapper.pins(from: recs, local: [local], now: t0)
        #expect(pins.map(\.key.host) == ["b.com", "a.com"])
        #expect(pins[1].id == local.id)
        #expect(pins[1].name == "New")
        #expect(pins[1].page == local.page)
        #expect(pins[0].page.url.absoluteString == "https://b.com/home")
        #expect(pins[0].page.scrollY == 0)
    }

    @Test func idnHostsMakeASCIIRecordNames() {
        #expect(RecordMapper.pinName(SiteKey("bücher.de")).unicodeScalars.allSatisfy { $0.isASCII })
    }

    @Test func shelfRegroupsByKeyNewestFirst() {
        let p1 = makeShelfPage("https://a.com/1", at: t0)
        let p2 = makeShelfPage("https://a.com/2", at: t0 + 5)
        let p3 = makeShelfPage("https://b.com/1", at: t0)
        let shelf = [makeEntry("a.com", [p2, p1], at: t0 + 20), makeEntry("b.com", [p3], at: t0 + 10)]
        let recs = RecordMapper.shelfRecords(shelf)
        #expect(recs.count == 3)
        let back = RecordMapper.shelf(from: recs.reversed(), local: shelf)
        #expect(back.shelf == shelf)
        #expect(back.duplicates.isEmpty)
        // Read on a Mac with an empty shelf: same grouping; pages shelved together sort most
        // recently used first; fresh pages keep their ids.
        let fresh = RecordMapper.shelf(from: recs, local: []).shelf
        #expect(fresh.map(\.key.host) == ["a.com", "b.com"])
        #expect(fresh[0].pages.map(\.id) == [p2.id, p1.id])
    }

    @Test func shelvedPageKeepsItsFirstShelvedAt() {
        let p1 = makeShelfPage("https://a.com/1", at: t0)
        let first = RecordMapper.shelfRecords([makeEntry("a.com", [p1], at: t0)])
        let prev = Dictionary(uniqueKeysWithValues: first.map { ($0.recordName, $0) })
        let p2 = makeShelfPage("https://a.com/2", at: t0)
        let later = RecordMapper.shelfRecords([makeEntry("a.com", [p2, p1], at: t0 + 100)], previous: prev)
        #expect(later.first { $0.recordName == RecordMapper.shelfName(p1.id) }?["shelvedAt"]?.dateValue == t0)
        #expect(later.first { $0.recordName == RecordMapper.shelfName(p2.id) }?["shelvedAt"]?.dateValue == t0 + 100)
    }

    @Test func historyAndDeviceRecordsRoundTrip() {
        let e = makeHistory("https://a.com/x", at: t0, dwell: 42)
        #expect(RecordMapper.historyEntry(from: RecordMapper.historyRecord(e)) == e)
        let pages = [OpenPageSummary(url: url("https://a.com/"), name: "A", title: "A title", key: SiteKey("a.com"))]
        var r = RecordMapper.deviceRecord(deviceID: "X", deviceName: "Studio", pages: pages)
        r.modifiedAt = t0
        #expect(RecordMapper.devicePages(from: r) == DeviceOpenPages(deviceID: "X", deviceName: "Studio", updatedAt: t0, pages: pages))
    }

    @Test func valuesCompareAcrossServerRoundTrip() {
        #expect(SyncValue.date(t0).contentEquals(.date(t0 + 0.0004)))
        #expect(!SyncValue.date(t0).contentEquals(.date(t0 + 0.01)))
        #expect(SyncValue.int(1).contentEquals(.bool(true)))
        #expect(SyncValue.double(2).contentEquals(.int(2)))
        #expect(!SyncValue.string("a").contentEquals(.strings(["a"])))
    }

    @Test func cloudKitRecordMappingRoundTrips() {
        let zone = CKRecordZone.ID(zoneName: "Plinth", ownerName: CKCurrentUserDefaultName)
        var r = RecordMapper.shelfRecords([makeEntry("a.com", [makeShelfPage("https://a.com/1", at: t0)], at: t0)])[0]
        r.fields["customName"] = .string("Mine")
        r.fields["flag"] = .bool(true)
        r.fields["tags"] = .strings(["x", "y"])
        r.fields["blob"] = .data(Data([1, 2, 3]))
        r.fields["score"] = .double(1.5)
        r.modifiedAt = t0; r.modifiedBy = "dev-A"
        let ck = CloudKitTransport.ckRecord(from: r, zoneID: zone)
        #expect(ck.recordID.recordName == r.recordName)
        let back = CloudKitTransport.syncRecord(from: ck)
        #expect(back.sameContent(as: r))
        #expect(back.modifiedBy == "dev-A")
        #expect(abs(back.modifiedAt.timeIntervalSince(t0)) < 0.001)
        #expect(back.serverTag != nil)
        // A version without customName clears it; a tombstone keeps no fields.
        var without = back
        without.fields["customName"] = nil
        let ck2 = CloudKitTransport.ckRecord(from: without, zoneID: zone)
        #expect(ck2["customName"] == nil)
        #expect(ck2.recordID == ck.recordID)
        let tomb = CloudKitTransport.syncRecord(from: CloudKitTransport.ckRecord(from: r.tombstone(at: t0, by: "A"), zoneID: zone))
        #expect(tomb.isTombstone)
        #expect(tomb.fields.isEmpty)
    }
}
