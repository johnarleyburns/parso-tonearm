import GRDB
import XCTest
@testable import TonearmCore

/// v42: persisted `asset.remoteContentType` — the provider's own MIME type
/// for a `.remote` asset (from `RemoteNode.contentType`). Real bug fix: a
/// Google Drive track with an extensionless cached file played fine on first
/// stream but failed on the second, cached-file play, because `AVURLAsset`
/// had no extension or MIME hint to infer the format from.
final class MigrationV42Tests: XCTestCase {
    func testV42AddsRemoteContentTypeColumnWithoutLosingExistingAssetData() throws {
        let queue = try DatabaseQueue()
        try Schema.migrator(upTo: "v41").migrate(queue)

        var sourceId: Int64 = 0
        var trackId: Int64 = 0
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO source (kind, title, addedAt, followUpdates, memberCapHit,
                                    localIsFolder, syncID)
                VALUES ('subsonic', 'Server', ?, 0, 0, 0, ?)
                """, arguments: [Date(), UUID().uuidString])
            sourceId = db.lastInsertedRowID
            try db.execute(sql: """
                INSERT INTO track (sourceId, title, sortKey, syncID)
                VALUES (?, 'Track', 'a', ?)
                """, arguments: [sourceId, UUID().uuidString])
            trackId = db.lastInsertedRowID
            try db.execute(sql: """
                INSERT INTO asset (trackId, kind, remoteURL) VALUES (?, 'remote', ?)
                """, arguments: [trackId, "https://example.test/pre-existing.mp3"])
        }

        // Migrate to head (v42).
        try Schema.migrator().migrate(queue)

        try queue.read { db in
            // Pre-existing row is untouched, the new column defaults to NULL.
            let row = try Row.fetchOne(
                db, sql: "SELECT remoteURL, remoteContentType FROM asset WHERE trackId = ?",
                arguments: [trackId])
            XCTAssertEqual(row?["remoteURL"] as String?, "https://example.test/pre-existing.mp3")
            XCTAssertNil(row?["remoteContentType"] as String?)

            let columns = try db.columns(in: "asset").map(\.name)
            XCTAssertTrue(columns.contains("remoteContentType"))
        }
    }

    func testMigratingTwiceIsIdempotent() throws {
        let queue = try DatabaseQueue()
        try Schema.migrator().migrate(queue)
        try Schema.migrator().migrate(queue)
    }

    /// The new column round-trips through the `Asset` GRDB record, same as
    /// `remoteNodeID`/`remoteNodePath` (v22) — unlike the deliberately
    /// transient fields, which must NOT survive a save/reload.
    func testAssetRoundTripsRemoteContentType() throws {
        let queue = try DatabaseQueue()
        try Schema.migrator().migrate(queue)

        var sourceId: Int64 = 0
        var trackId: Int64 = 0
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO source (kind, title, addedAt, followUpdates, memberCapHit,
                                    localIsFolder, syncID)
                VALUES ('subsonic', 'Server', ?, 0, 0, 0, ?)
                """, arguments: [Date(), UUID().uuidString])
            sourceId = db.lastInsertedRowID
            try db.execute(sql: """
                INSERT INTO track (sourceId, title, sortKey, syncID)
                VALUES (?, 'Track', 'a', ?)
                """, arguments: [sourceId, UUID().uuidString])
            trackId = db.lastInsertedRowID
        }

        var asset = Asset(
            id: nil, trackId: trackId, kind: .remote, bookmark: nil, relPath: nil,
            remoteURL: "https://example.test/song", altRemoteURL: nil, sizeBytes: nil,
            unsupportedReason: nil, remoteNodeID: "song-42", remoteNodePath: "artist/album/song-42",
            remoteContentType: "audio/mpeg")
        try queue.write { db in try asset.insert(db) }

        let reloaded = try queue.read { db in try Asset.filter(Column("trackId") == trackId).fetchOne(db) }
        XCTAssertEqual(reloaded?.remoteContentType, "audio/mpeg")
    }
}
