import CloudKit
import Foundation

/// `SyncTransport` over the user's private CloudKit database, in a custom zone "Plinth".
///
/// Nothing touches CloudKit until the first fetch or save: the container is created lazily, so
/// constructing this type in an unsigned build is harmless (but syncing will fail; check
/// `SyncSettings.isCloudKitConfigured` first). The zone is created on first use.
public actor CloudKitTransport: SyncTransport {
    public static let zoneName = "Plinth"
    /// CloudKit accepts at most 400 items per modify request.
    static let batchSize = 350

    public let containerIdentifier: String
    private var database: CKDatabase?
    private var zoneReady = false
    private let zoneID = CKRecordZone.ID(zoneName: CloudKitTransport.zoneName, ownerName: CKCurrentUserDefaultName)

    // Field names for the record metadata (CloudKit reserves modificationDate etc.).
    static let editedAtKey = "editedAt"
    static let editedByKey = "editedBy"
    static let tombstoneKey = "tombstone"

    public init(containerIdentifier: String) {
        self.containerIdentifier = containerIdentifier
    }

    // MARK: SyncTransport

    public func fetchChanges(since token: Data?) async throws -> SyncChangeSet {
        let db = try await prepared()
        let ckToken = token.flatMap { try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: $0) }
        do {
            let result = try await db.recordZoneChanges(inZoneWith: zoneID, since: ckToken)
            var changed: [SyncRecord] = []
            for (_, r) in result.modificationResultsByID {
                if case .success(let mod) = r { changed.append(Self.syncRecord(from: mod.record)) }
            }
            let deleted = result.deletions.map {
                SyncRecordID(recordType: $0.recordType, recordName: $0.recordID.recordName)
            }
            let tokenData = try? NSKeyedArchiver.archivedData(withRootObject: result.changeToken, requiringSecureCoding: true)
            return SyncChangeSet(changed: changed, deleted: deleted, token: tokenData, moreComing: result.moreComing)
        } catch let error as CKError {
            throw mapped(error)
        }
    }

    public func modify(saving: [SyncRecord], deleting: [SyncRecordID]) async throws -> SyncModifyResult {
        let db = try await prepared()
        var out = SyncModifyResult()
        var saveQueue = saving[...]
        var deleteQueue = deleting[...]
        while !saveQueue.isEmpty || !deleteQueue.isEmpty {
            let saveBatch = Array(saveQueue.prefix(Self.batchSize))
            saveQueue = saveQueue.dropFirst(saveBatch.count)
            let deleteBatch = Array(deleteQueue.prefix(Self.batchSize - saveBatch.count))
            deleteQueue = deleteQueue.dropFirst(deleteBatch.count)

            let records = saveBatch.map { Self.ckRecord(from: $0, zoneID: zoneID) }
            let ids = deleteBatch.map { CKRecord.ID(recordName: $0.recordName, zoneID: zoneID) }
            let typeByName = Dictionary(deleteBatch.map { ($0.recordName, $0.recordType) }, uniquingKeysWith: { a, _ in a })
            let result: (saveResults: [CKRecord.ID: Result<CKRecord, any Error>], deleteResults: [CKRecord.ID: Result<Void, any Error>])
            do {
                result = try await db.modifyRecords(saving: records, deleting: ids,
                                                    savePolicy: .ifServerRecordUnchanged, atomically: false)
            } catch let error as CKError {
                throw mapped(error)
            }
            for (id, r) in result.saveResults {
                let type = saveBatch.first { $0.recordName == id.recordName }?.recordType ?? ""
                switch r {
                case .success(let rec):
                    out.saved.append(Self.syncRecord(from: rec))
                case .failure(let error):
                    if let ck = error as? CKError, ck.code == .serverRecordChanged, let server = ck.serverRecord {
                        out.conflicts.append(Self.syncRecord(from: server))
                    } else {
                        out.failed[SyncRecordID(recordType: type, recordName: id.recordName)] = error.localizedDescription
                    }
                }
            }
            for (id, r) in result.deleteResults {
                let sid = SyncRecordID(recordType: typeByName[id.recordName] ?? "", recordName: id.recordName)
                switch r {
                case .success: out.deleted.append(sid)
                case .failure(let error):
                    if let ck = error as? CKError, ck.code == .unknownItem { out.deleted.append(sid) }
                    else { out.failed[sid] = error.localizedDescription }
                }
            }
        }
        return out
    }

    // MARK: Setup

    private func prepared() async throws -> CKDatabase {
        let db: CKDatabase
        if let database { db = database } else {
            db = CKContainer(identifier: containerIdentifier).privateCloudDatabase
            database = db
        }
        if !zoneReady {
            do {
                _ = try await db.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: [])
                zoneReady = true
            } catch let error as CKError {
                throw mapped(error)
            }
        }
        return db
    }

    private func mapped(_ error: CKError) -> Error {
        switch error.code {
        case .changeTokenExpired: return SyncError.changeTokenExpired
        case .zoneNotFound, .userDeletedZone:
            zoneReady = false
            return SyncError.serverReset
        case .notAuthenticated, .managedAccountRestricted: return SyncError.notSignedIn
        case .missingEntitlement, .badContainer: return SyncError.notConfigured
        default: return SyncError.transport(error.localizedDescription)
        }
    }

    // MARK: Mapping

    static func ckRecord(from r: SyncRecord, zoneID: CKRecordZone.ID) -> CKRecord {
        let record: CKRecord
        if let tag = r.serverTag, let restored = restore(systemFields: tag) {
            record = restored
        } else {
            record = CKRecord(recordType: r.recordType, recordID: CKRecord.ID(recordName: r.recordName, zoneID: zoneID))
        }
        // A save only sends the keys it sets, so clear every key this version leaves out.
        for key in (RecordMapper.fieldKeys[r.recordType] ?? []) + (r.clearKeys ?? []) where r.fields[key] == nil || r.isTombstone {
            record[key] = nil as (any __CKRecordObjCValue)?
        }
        if !r.isTombstone {
            for (key, value) in r.fields { record[key] = ckValue(value) }
        }
        record[editedAtKey] = r.modifiedAt as NSDate
        record[editedByKey] = r.modifiedBy as NSString
        record[tombstoneKey] = NSNumber(value: r.isTombstone ? 1 : 0)
        return record
    }

    static func syncRecord(from rec: CKRecord) -> SyncRecord {
        var fields: [String: SyncValue] = [:]
        let meta: Set<String> = [editedAtKey, editedByKey, tombstoneKey]
        for key in rec.allKeys() where !meta.contains(key) {
            if let v = syncValue(rec[key]) { fields[key] = v }
        }
        let tombstone = (rec[tombstoneKey] as? NSNumber)?.boolValue ?? false
        return SyncRecord(
            recordType: rec.recordType,
            recordName: rec.recordID.recordName,
            fields: tombstone ? [:] : fields,
            modifiedAt: (rec[editedAtKey] as? Date) ?? rec.modificationDate ?? .distantPast,
            modifiedBy: (rec[editedByKey] as? String) ?? "",
            isTombstone: tombstone,
            serverTag: archive(systemFieldsOf: rec)
        )
    }

    static func ckValue(_ v: SyncValue) -> (any __CKRecordObjCValue)? {
        switch v {
        case .string(let s): return s as NSString
        case .strings(let a): return a as NSArray
        case .int(let i): return NSNumber(value: i)
        case .double(let d): return NSNumber(value: d)
        case .date(let d): return d as NSDate
        case .bool(let b): return NSNumber(value: b ? 1 : 0)
        case .data(let d): return d as NSData
        }
    }

    static func syncValue(_ v: (any __CKRecordObjCValue)?) -> SyncValue? {
        switch v {
        case let s as String: return .string(s)
        case let a as [String]: return .strings(a)
        case let d as Date: return .date(d)
        case let d as Data: return .data(d)
        case let n as NSNumber:
            return CFNumberIsFloatType(n) ? .double(n.doubleValue) : .int(n.intValue)
        default: return nil
        }
    }

    /// CloudKit's server version of a record (its system fields), as opaque bytes.
    static func archive(systemFieldsOf rec: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        rec.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    static func restore(systemFields data: Data) -> CKRecord? {
        guard let coder = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        coder.requiresSecureCoding = true
        defer { coder.finishDecoding() }
        return CKRecord(coder: coder)
    }
}
