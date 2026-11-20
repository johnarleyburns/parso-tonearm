import GRDB
import Foundation
import Testing
@testable import TonearmCore

/// v22: persisted `asset.remoteNodeID`/`remoteNodePath` — the real
/// provider-native node reference a `.remote` asset needs so a background
/// caller can re-authenticate via `RemoteLibraryProvider.resolve(node:)`
/// instead of trusting a possibly-stale `remoteURL` alone (real bug fix —
/// see docs/plans/remote-sparse-indexing.md, "Phase 0").
@Suite struct MigrationV22Tests {
    @Test func testV22AddsRemoteNodeColumnsWithoutLosingExistingAssetData() throws {
        let queue = try DatabaseQueue()
        try Schema.migrator(upTo: "v21").migrate(queue)

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

        // Migrate to head (v22).
        try Schema.migrator().migrate(queue)

        try queue.read { db in
            // Pre-existing row is untouched, new columns default to NULL.
            let row = try Row.fetchOne(
                db, sql: "SELECT remoteURL, remoteNodeID, remoteNodePath FROM asset WHERE trackId = ?",
                arguments: [trackId])
            #expect(row?["remoteURL"] as String? == "https://example.test/pre-existing.mp3")
            #expect(row?["remoteNodeID"] as String? == nil)
            #expect(row?["remoteNodePath"] as String? == nil)

            let columns = try db.columns(in: "asset").map(\.name)
            #expect(columns.contains("remoteNodeID"))
            #expect(columns.contains("remoteNodePath"))
        }
    }

    @Test func testMigratingTwiceIsIdempotent() throws {
        let queue = try DatabaseQueue()
        try Schema.migrator().migrate(queue)
        try Schema.migrator().migrate(queue)
    }

    /// The new columns round-trip through the `Asset` GRDB record — unlike
    /// `transientRemoteHeaders`/`transientRemoteSupportsByteRanges`, which
    /// are deliberately excluded from `Asset.CodingKeys` and must NOT survive
    /// a save/reload.
    @Test func testAssetRoundTripsRemoteNodeFieldsButKeepsHeadersTransient() throws {
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
            remoteURL: "https://example.test/song.mp3", altRemoteURL: nil, sizeBytes: nil,
            unsupportedReason: nil, remoteNodeID: "song-42", remoteNodePath: "artist/album/song-42")
        asset.transientRemoteHeaders = ["Authorization": "Bearer secret"]
        try queue.write { db in try asset.insert(db) }

        let reloaded = try queue.read { db in try Asset.filter(Column("trackId") == trackId).fetchOne(db) }
        #expect(reloaded?.remoteNodeID == "song-42")
        #expect(reloaded?.remoteNodePath == "artist/album/song-42")
        #expect(reloaded?.transientRemoteHeaders.isEmpty == true,
                      "transient headers must never survive a DB round trip")
    }
}
