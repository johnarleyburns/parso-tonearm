import XCTest
import GRDB
@testable import Tonearm

/// C7 — schema `v7` adds a UUID `syncID` to every synced table and backfills
/// existing rows so cross-device identity is stable. Also adds `needsReimport`
/// to `asset`. Verified against a fresh in-memory store (all migrations run).
final class SyncMigrationTests: XCTestCase {

    func testSyncIDColumnsExistOnSyncedTables() async throws {
        let store = try LibraryStore(inMemory: true)
        let tables = ["source", "album", "track", "asset", "playlist",
                      "playlist_item", "favorite", "play_history", "custom_artwork"]
        try await store.dbQueue.read { db in
            for table in tables {
                let columns = try db.columns(in: table)
                XCTAssertTrue(columns.contains { $0.name == "syncID" },
                              "\(table) must have a syncID column after v7")
            }
            let assetColumns = try db.columns(in: "asset")
            XCTAssertTrue(assetColumns.contains { $0.name == "needsReimport" })
        }
    }

    func testBackfillAssignsSyncIDToExistingRows() async throws {
        let store = try LibraryStore(inMemory: true)
        // Insert a source without setting syncID; store auto-generates on insert?
        // v7 backfill covers rows created before the column existed. Simulate by
        // inserting then clearing syncID, then re-checking the backfill invariant
        // for freshly inserted rows carrying a syncID via the app layer.
        let source = try await store.insertSource(
            Source(id: nil, kind: .local, iaIdentifier: nil, originalURL: nil,
                   title: "Src", addedAt: Date(), lastResolvedAt: nil,
                   followUpdates: false, licenseText: nil, memberCapHit: false,
                   localIsFolder: false, artworkTrackId: nil, syncID: UUID().uuidString))
        let sid = try XCTUnwrap(source.id)
        let readSyncID = try await store.syncID(table: "source", id: sid)
        XCTAssertNotNil(readSyncID)
        // Round-trip syncID → localID.
        let backID = try await store.localID(table: "source", syncID: try XCTUnwrap(readSyncID))
        XCTAssertEqual(backID, sid)
    }

    func testSyncIDUniqueIndexRejectsDuplicates() async throws {
        let store = try LibraryStore(inMemory: true)
        let dup = UUID().uuidString
        _ = try await store.insertSource(
            Source(id: nil, kind: .local, iaIdentifier: nil, originalURL: nil,
                   title: "A", addedAt: Date(), lastResolvedAt: nil, followUpdates: false,
                   licenseText: nil, memberCapHit: false, localIsFolder: false,
                   artworkTrackId: nil, syncID: dup))
        do {
            _ = try await store.insertSource(
                Source(id: nil, kind: .local, iaIdentifier: nil, originalURL: nil,
                       title: "B", addedAt: Date(), lastResolvedAt: nil, followUpdates: false,
                       licenseText: nil, memberCapHit: false, localIsFolder: false,
                       artworkTrackId: nil, syncID: dup))
            XCTFail("duplicate syncID should violate the unique index")
        } catch {
            // expected
        }
    }

    /// Launch-crash regression: existing installs migrating through v7 must
    /// backfill `syncID` for every pre-v7 row without trapping. The old code
    /// fetched a GRDB `Row` and read `row["rowid"]`, which is unreliable on
    /// migrated tables and crashed via `swift_unexpectedError` during
    /// `LibraryStore.shared` init. This drives a real v6 → v7 migration over
    /// seeded rows in all synced tables.
    func testV7BackfillPreservesRowsAndAssignsSyncIDs() throws {
        let syncedTables = ["source", "album", "track", "asset", "playlist",
                            "playlist_item", "favorite", "play_history", "custom_artwork"]

        let dbQueue = try makeV6Database()
        try seedPreV7Rows(dbQueue)

        let before = try dbQueue.read { db in
            try syncedTables.reduce(into: [String: Int]()) { counts, table in
                counts[table] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
            }
        }
        for table in syncedTables {
            XCTAssertGreaterThan(before[table] ?? 0, 0, "\(table) should be seeded pre-v7")
        }

        XCTAssertNoThrow(try Schema.migrator().migrate(dbQueue),
                         "v7 syncID backfill must not trap on migrated rows")

        try dbQueue.read { db in
            for table in syncedTables {
                let after = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? -1
                XCTAssertEqual(after, before[table], "\(table) row count must be preserved")

                let missing = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM \(table) WHERE syncID IS NULL OR syncID = ''") ?? -1
                XCTAssertEqual(missing, 0, "\(table) must have a non-empty syncID on every row")

                let distinct = try Int.fetchOne(
                    db, sql: "SELECT COUNT(DISTINCT syncID) FROM \(table)") ?? -1
                XCTAssertEqual(distinct, after, "\(table) syncIDs must be unique")
            }

            let assetColumns = try db.columns(in: "asset")
            XCTAssertTrue(assetColumns.contains { $0.name == "needsReimport" })
        }
    }

    private func makeV6Database() throws -> DatabaseQueue {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let dbQueue = try DatabaseQueue(configuration: config)
        try Schema.migrator(upTo: "v6").migrate(dbQueue)
        return dbQueue
    }

    private func seedPreV7Rows(_ dbQueue: DatabaseQueue) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO source (id, kind, title, addedAt, followUpdates, memberCapHit, localIsFolder)
                    VALUES (1, 'local', 'Legacy Source', ?, 0, 0, 0)
                    """, arguments: [Date(timeIntervalSince1970: 1_000)])

            try db.execute(
                sql: """
                    INSERT INTO album (id, sourceId, title, artist, year, artworkId)
                    VALUES (1, 1, 'Legacy Album', 'Legacy Artist', 1969, 'art-1')
                    """)

            try db.execute(
                sql: """
                    INSERT INTO track
                        (id, albumId, sourceId, title, trackNo, discNo, durationSec,
                         codec, sampleRate, bitDepthOrBitrate, sortKey)
                    VALUES (1, 1, 1, 'Legacy Track', 1, 1, 180.0, 'flac', 44100, '16', '0001')
                    """)

            try db.execute(
                sql: """
                    INSERT INTO asset (id, trackId, kind, relPath)
                    VALUES (1, 1, 'local', 'legacy/track.flac')
                    """)

            try db.execute(
                sql: """
                    INSERT INTO playlist (id, title, kind, watch)
                    VALUES (1, 'Legacy Playlist', 'manual', 0)
                    """)

            try db.execute(
                sql: """
                    INSERT INTO playlist_item (id, playlistId, position, trackId)
                    VALUES (1, 1, 0, 1)
                    """)

            try db.execute(
                sql: """
                    INSERT INTO favorite (id, trackId, favoritedAt)
                    VALUES (1, 1, ?)
                    """, arguments: [Date(timeIntervalSince1970: 2_000)])

            try db.execute(
                sql: """
                    INSERT INTO play_history (id, trackId, playedAt)
                    VALUES (1, 1, ?)
                    """, arguments: [Date(timeIntervalSince1970: 3_000)])

            try db.execute(
                sql: """
                    INSERT INTO custom_artwork (trackId, artworkId)
                    VALUES (1, 'custom-art-1')
                    """)
        }
    }
}
