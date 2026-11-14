import Foundation

// A record model that does not depend on CloudKit, so the merge logic can be tested with an
// in-memory server and the CloudKit transport stays a thin mapping layer.

/// A field value. Kept to the types CloudKit stores natively.
public enum SyncValue: Codable, Sendable, Equatable {
    case string(String)
    case strings([String])
    case int(Int)
    case double(Double)
    case date(Date)
    case bool(Bool)
    case data(Data)

    public var stringValue: String? { if case .string(let v) = self { return v }; return nil }
    public var stringsValue: [String]? { if case .strings(let v) = self { return v }; return nil }
    public var dataValue: Data? { if case .data(let v) = self { return v }; return nil }
    public var dateValue: Date? { if case .date(let v) = self { return v }; return nil }

    /// CloudKit hands numbers back as NSNumber, so int, double and bool are read tolerantly.
    public var intValue: Int? {
        switch self {
        case .int(let v): return v
        case .double(let v): return v.isFinite ? Int(v) : nil
        case .bool(let v): return v ? 1 : 0
        default: return nil
        }
    }
    public var doubleValue: Double? {
        switch self {
        case .double(let v): return v
        case .int(let v): return Double(v)
        default: return nil
        }
    }
    public var boolValue: Bool? {
        switch self {
        case .bool(let v): return v
        case .int(let v): return v != 0
        default: return nil
        }
    }

    /// Equality that survives a round trip through the server: dates are compared to the
    /// millisecond (CloudKit's precision) and numbers across int/double/bool.
    public func contentEquals(_ other: SyncValue) -> Bool {
        switch (self, other) {
        case (.date(let a), .date(let b)): return abs(a.timeIntervalSince(b)) < 0.001
        case (.double, _), (_, .double): return doubleValue == other.doubleValue
        case (.int, _), (_, .int), (.bool, _), (_, .bool): return intValue == other.intValue && intValue != nil
        default: return self == other
        }
    }
}

public struct SyncRecordID: Hashable, Codable, Sendable {
    public var recordType: String
    public var recordName: String
    public init(recordType: String, recordName: String) {
        self.recordType = recordType; self.recordName = recordName
    }
}

public struct SyncRecord: Codable, Sendable, Equatable {
    public var recordType: String
    /// Unique across all record types (each type uses its own prefix).
    public var recordName: String
    public var fields: [String: SyncValue]
    /// When the change was made, by the clock of the Mac that made it. Used for last-writer-wins.
    public var modifiedAt: Date
    /// The device ID of the Mac that made the change. Breaks modifiedAt ties.
    public var modifiedBy: String
    /// A deletion that must outlive the thing it deletes so other Macs learn about it.
    public var isTombstone: Bool
    /// Opaque server version (CloudKit: archived system fields). nil for a record the server
    /// has not seen yet. Saving with a stale tag is reported back as a conflict.
    public var serverTag: Data?
    /// Fields the transport sets to nil on this save, besides those its type defines and the record
    /// leaves out: leftovers an earlier build wrote to the server copy.
    public var clearKeys: [String]?

    public init(recordType: String, recordName: String, fields: [String: SyncValue] = [:],
                modifiedAt: Date = .distantPast, modifiedBy: String = "", isTombstone: Bool = false,
                serverTag: Data? = nil) {
        self.recordType = recordType; self.recordName = recordName; self.fields = fields
        self.modifiedAt = modifiedAt; self.modifiedBy = modifiedBy; self.isTombstone = isTombstone
        self.serverTag = serverTag
    }

    public var id: SyncRecordID { SyncRecordID(recordType: recordType, recordName: recordName) }

    public subscript(_ key: String) -> SyncValue? { fields[key] }

    /// Same type, name, liveness and fields; ignores modifiedAt/modifiedBy/serverTag.
    public func sameContent(as other: SyncRecord) -> Bool {
        guard recordType == other.recordType, recordName == other.recordName,
              isTombstone == other.isTombstone else { return false }
        if isTombstone { return true }
        guard fields.count == other.fields.count else { return false }
        for (k, v) in fields {
            guard let o = other.fields[k], v.contentEquals(o) else { return false }
        }
        return true
    }

    /// A tombstone for this record, stamped with the given time and device.
    public func tombstone(at date: Date, by device: String) -> SyncRecord {
        SyncRecord(recordType: recordType, recordName: recordName, fields: [:], modifiedAt: date,
                   modifiedBy: device, isTombstone: true, serverTag: serverTag)
    }
}
