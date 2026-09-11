import GRDB
import XCTest
@testable import TonearmCore

final class MigrationV21Tests: XCTestCase {
    func testV21AddsAlbumAndSourceCustomArtworkTablesWithoutLosingExistingData() throws {
        let queue = try DatabaseQueue()
        try Schema.migrator(upTo: "v20").migrate(queue)

        var sourceId: Int64 = 0
        var trackId: Int64 = 0
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO source (kind, title, addedAt, followUpdates, memberCapHit,
                                    localIsFolder, syncID)
                VALUES ('local', 'Music', ?, 0, 0, 0, ?)
                """, arguments: [Date(), UUID().uuidString])
            sourceId = db.lastInsertedRowID
            try db.execute(sql: """
                INSERT INTO track (sourceId, title, sortKey, syncID)
                VALUES (?, 'Track', 'a', ?)
                """, arguments: [sourceId, UUID().uuidString])
            trackId = db.lastInsertedRowID
            try db.execute(sql: "INSERT INTO custom_artwork (trackId, artworkId) VALUES (?, ?)",
                           arguments: [trackId, "existing-artwork"])
        }

        // Migrate to head (v21).
        try Schema.migrator().migrate(queue)

        try queue.read { db in
            // Existing v5 track-level table/data is untouched.
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT artworkId FROM custom_artwork WHERE trackId = ?",
                                               arguments: [trackId]), "existing-artwork")

            // New tables exist with the expected columns.
            let albumColumns = try db.columns(in: "custom_artwork_album").map(\.name)
            XCTAssertTrue(albumColumns.contains("albumId"))
            XCTAssertTrue(albumColumns.contains("artworkId"))
            XCTAssertTrue(albumColumns.contains("syncID"))

            let sourceColumns = try db.columns(in: "custom_artwork_source").map(\.name)
            XCTAssertTrue(sourceColumns.contains("sourceId"))
            XCTAssertTrue(sourceColumns.contains("artworkId"))
            XCTAssertTrue(sourceColumns.contains("syncID"))
        }
    }

    func testMigratingTwiceIsIdempotent() throws {
        let queue = try DatabaseQueue()
        try Schema.migrator().migrate(queue)
        // Migrating again against an already-current database must not throw.
        try Schema.migrator().migrate(queue)
    }
}
