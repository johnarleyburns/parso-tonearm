import Foundation
import GRDB

public struct SyncPendingRecord: Codable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "sync_pending_record"
    public var recordName: String
    public var recordType: String
    public var payload: Data
    public var trackKeys: String
    public var receivedAt: Date
    public var attempts: Int

    public init(recordName: String, recordType: String, payload: Data,
                trackKeys: String = "[]", receivedAt: Date = Date(), attempts: Int = 0) {
        self.recordName = recordName; self.recordType = recordType; self.payload = payload
        self.trackKeys = trackKeys; self.receivedAt = receivedAt; self.attempts = attempts
    }
}

extension LibraryStore {
    public func upsertPendingSyncRecord(recordName: String, recordType: String,
                                        payload: Data, trackKeys: [TrackIdentityKey],
                                        receivedAt: Date = Date()) throws {
        let encodedKeys = String(data: try JSONEncoder().encode(trackKeys.map(\.cloudValue)), encoding: .utf8) ?? "[]"
        try dbQueue.write { db in
            var row = SyncPendingRecord(recordName: recordName, recordType: recordType,
                                        payload: payload, trackKeys: encodedKeys,
                                        receivedAt: receivedAt)
            try row.save(db)
        }
    }

    public func pendingSyncRecords() throws -> [SyncPendingRecord] {
        try dbQueue.read { db in
            try SyncPendingRecord.order(Column("receivedAt")).fetchAll(db)
        }
    }

    public func pendingSyncRecordCount() throws -> Int {
        try dbQueue.read { db in try SyncPendingRecord.fetchCount(db) }
    }

    public func pendingSyncOldestDate() throws -> Date? {
        try dbQueue.read { db in try Date.fetchOne(db, sql: "SELECT MIN(receivedAt) FROM sync_pending_record") }
    }

    public func deletePendingSyncRecord(recordName: String) throws {
        try dbQueue.write { db in _ = try SyncPendingRecord.deleteOne(db, key: recordName) }
    }

    public func discardPendingSyncRecords() throws {
        try dbQueue.write { db in _ = try SyncPendingRecord.deleteAll(db) }
    }

    @discardableResult
    public func prunePendingSyncRecords(olderThan date: Date = Date().addingTimeInterval(-90 * 86_400)) throws -> Int {
        try dbQueue.write { db in
            try SyncPendingRecord.filter(Column("receivedAt") < date).deleteAll(db)
        }
    }
}
