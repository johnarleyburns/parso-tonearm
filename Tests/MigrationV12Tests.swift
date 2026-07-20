import XCTest
import GRDB
@testable import TonearmCore

final class MigrationV12Tests: XCTestCase {
    func testMigrationV12CreatesWatchTransferTable() throws {
        let dbQueue = try DatabaseQueue()
        try Schema.migrator(upTo: "v11").migrate(dbQueue)
        try Schema.migrator().migrate(dbQueue)

        let columns = try dbQueue.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(watchTransfer)")
                .compactMap { row -> String? in row["name"] }
        }

        XCTAssertTrue(columns.contains("id"))
        XCTAssertTrue(columns.contains("trackId"))
        XCTAssertTrue(columns.contains("state"))
        XCTAssertTrue(columns.contains("originKind"))
        XCTAssertTrue(columns.contains("originId"))
        XCTAssertTrue(columns.contains("bytes"))
        XCTAssertTrue(columns.contains("errorText"))
        XCTAssertTrue(columns.contains("queuedAt"))
        XCTAssertTrue(columns.contains("updatedAt"))
    }

    func testMigrationV12CreatesWatchManifestTable() throws {
        let dbQueue = try DatabaseQueue()
        try Schema.migrator(upTo: "v11").migrate(dbQueue)
        try Schema.migrator().migrate(dbQueue)

        let columns = try dbQueue.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(watchManifest)")
                .compactMap { row -> String? in row["name"] }
        }

        XCTAssertTrue(columns.contains("trackKey"))
        XCTAssertTrue(columns.contains("bytes"))
        XCTAssertTrue(columns.contains("pinned"))
        XCTAssertTrue(columns.contains("reportedAt"))
    }

    func testWatchManifestCRUD() throws {
        let dbQueue = try DatabaseQueue()
        try Schema.migrator().migrate(dbQueue)

        var record = WatchManifestRecord(trackKey: "t1", bytes: 1024, pinned: true)
        try dbQueue.write { db in try record.insert(db) }

        let fetched = try dbQueue.read { db in
            try WatchManifestRecord.fetchOne(db, key: "t1")
        }
        XCTAssertEqual(fetched?.bytes, 1024)
        XCTAssertEqual(fetched?.pinned, true)

        try dbQueue.write { db in
            try WatchManifestRecord.deleteOne(db, key: "t1")
        }
        let afterDelete = try dbQueue.read { db in
            try WatchManifestRecord.fetchOne(db, key: "t1")
        }
        XCTAssertNil(afterDelete)
    }

    func testWatchTransferInsertAndRead() throws {
        let dbQueue = try DatabaseQueue()
        try Schema.migrator().migrate(dbQueue)

        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO source (kind, title, addedAt, lastResolvedAt)
                VALUES ('local', 'test', datetime('now'), datetime('now'))
                """)
            let sourceID = db.lastInsertedRowID
            try db.execute(sql: """
                INSERT INTO album (sourceId, title)
                VALUES (\(sourceID), 'test album')
                """)
            let albumID = db.lastInsertedRowID
            try db.execute(sql: """
                INSERT INTO track (albumId, sourceId, title, sortKey, durationSec)
                VALUES (\(albumID), \(sourceID), 'test track', 'test track', 180)
                """)
            let trackID = db.lastInsertedRowID

            var record = WatchTransferRecord(
                trackId: trackID, state: "queued",
                originKind: "single",
                bytes: 512, queuedAt: Date(), updatedAt: Date())
            try record.insert(db)
            XCTAssertNotNil(record.id)
        }

        let count = try dbQueue.read { db in
            try WatchTransferRecord.fetchCount(db)
        }
        XCTAssertEqual(count, 1)
    }
}
