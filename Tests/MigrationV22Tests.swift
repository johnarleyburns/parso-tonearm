import GRDB
import XCTest
@testable import TonearmCore

/// v22: persisted `asset.remoteNodeID`/`remoteNodePath` — the real
/// provider-native node reference a `.remote` asset needs so a background
/// caller can re-authenticate via `RemoteLibraryProvider.resolve(node:)`
/// instead of trusting a possibly-stale `remoteURL` alone (real bug fix —
/// see docs/plans/remote-sparse-indexing.md, "Phase 0").
final class MigrationV22Tests: XCTestCase {
    func testV22AddsRemoteNodeColumnsWithoutLosingExistingAssetData() throws {
        let queue = try DatabaseQueue()
        try Schema.migrator(upTo: "v21").migrate(queue)

        var sourceId: Int64 = 0
        var trackId: Int64 = 0
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO source (kind, title, addedAt, followUpdates, memberCapHit,
                                    localIsFolder, syncID)
                VALUES ('remote', 'Server', ?, 0, 0, 0, ?)
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

        // Migrate to head (v22).
        try Schema.migrator().migrate(queue)

        try queue.read { db in
            // Pre-existing row is untouched, new columns default to NULL.
            let row = try Row.fetchOne(
                db, sql: "SELECT remoteURL, remoteNodeID, remoteNodePath FROM asset WHERE trackId = ?",
                arguments: [trackId])
            XCTAssertEqual(row?["remoteURL"] as String?, "https://example.test/pre-existing.mp3")
            XCTAssertNil(row?["remoteNodeID"] as String?)
            XCTAssertNil(row?["remoteNodePath"] as String?)

            let columns = try db.columns(in: "asset").map(\.name)
            XCTAssertTrue(columns.contains("remoteNodeID"))
            XCTAssertTrue(columns.contains("remoteNodePath"))
        }
    }

    func testMigratingTwiceIsIdempotent() throws {
        let queue = try DatabaseQueue()
        try Schema.migrator().migrate(queue)
        try Schema.migrator().migrate(queue)
    }

    /// The new columns round-trip through the `Asset` GRDB record — unlike
    /// `transientRemoteHeaders`/`transientRemoteSupportsByteRanges`, which
    /// are deliberately excluded from `Asset.CodingKeys` and must NOT survive
    /// a save/reload.
    func testAssetRoundTripsRemoteNodeFieldsButKeepsHeadersTransient() throws {
        let queue = try DatabaseQueue()
        try Schema.migrator().migrate(queue)

        var sourceId: Int64 = 0
        var trackId: Int64 = 0
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO source (kind, title, addedAt, followUpdates, memberCapHit,
                                    localIsFolder, syncID)
                VALUES ('remote', 'Server', ?, 0, 0, 0, ?)
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
            remoteURL: "https://example.test/song.mp3", altRemoteURL: nil, sizeBytes: nil,
            unsupportedReason: nil, remoteNodeID: "song-42", remoteNodePath: "artist/album/song-42")
        asset.transientRemoteHeaders = ["Authorization": "Bearer secret"]
        try queue.write { db in try asset.insert(db) }

        let reloaded = try queue.read { db in try Asset.filter(Column("trackId") == trackId).fetchOne(db) }
        XCTAssertEqual(reloaded?.remoteNodeID, "song-42")
        XCTAssertEqual(reloaded?.remoteNodePath, "artist/album/song-42")
        XCTAssertTrue(reloaded?.transientRemoteHeaders.isEmpty == true,
                      "transient headers must never survive a DB round trip")
    }
}
