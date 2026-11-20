import GRDB
import Foundation
import Testing
@testable import TonearmCore

/// v53: content fingerprint column, duplicate-source consolidation and the
/// one-time local/remote track cleanup. Reattaching Google Drive (or any
/// account/endpoint provider) used to create a second Source; remote identity is
/// namespaced by source id, so every file re-ingested as a new track.
@Suite struct MigrationV53Tests {
    private func makeQueue() throws -> DatabaseQueue {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: config)
        try Schema.migrator(upTo: "v52").migrate(queue)
        return queue
    }

    @Test func testV53AddsContentFingerprintAndAuditTable() throws {
        let queue = try makeQueue()
        try queue.read { db in
            #expect(!(try db.columns(in: "asset").map(\.name)).contains("contentSampleHash"))
        }
        try Schema.migrator().migrate(queue)
        try queue.read { db in
            #expect((try db.columns(in: "asset").map(\.name)).contains("contentSampleHash"))
            #expect(try db.tableExists("merged_source"))
        }
    }

    @Test func testReattachedGoogleDriveSourceMergesTracksAndUserData() throws {
        let queue = try makeQueue()
        try queue.write { db in
            for sourceID in 1...2 {
                try db.execute(sql: """
                    INSERT INTO source (kind, iaIdentifier, title, addedAt,
                                        followUpdates, memberCapHit, localIsFolder)
                    VALUES ('googleDrive', 'user@example.com', 'Drive', ?, 0, 0, 0)
                    """, arguments: [Date(timeIntervalSince1970: Double(sourceID))])
            }
            try db.execute(sql: "INSERT INTO album (sourceId, title) VALUES (1, 'Album')")
            try db.execute(sql: "INSERT INTO album (sourceId, title) VALUES (2, 'Album')")
            for (trackID, sourceID, albumID) in [(1, 1, 1), (2, 2, 2)] {
                try db.execute(sql: """
                    INSERT INTO track (sourceId, albumId, title, sortKey, durationSec)
                    VALUES (?, ?, 'Same File', '0001', 100)
                    """, arguments: [sourceID, albumID])
                try db.execute(sql: """
                    INSERT INTO asset (trackId, kind, remoteURL, remoteNodeID, sizeBytes)
                    VALUES (?, 'remote', 'https://drive.example/file', 'drive-file-1', 4096)
                    """, arguments: [trackID])
            }
            try db.execute(sql: "INSERT INTO favorite (trackId, favoritedAt) VALUES (1, ?)", arguments: [Date()])
            try db.execute(sql: "INSERT INTO play_history (trackId, playedAt) VALUES (2, ?)", arguments: [Date()])
            try db.execute(sql: "INSERT INTO playlist (title, kind, watch) VALUES ('P', 'manual', 0)")
            try db.execute(sql: "INSERT INTO playlist_item (playlistId, position, trackId) VALUES (1, 0, 2)")
        }

        try Schema.migrator().migrate(queue)

        try queue.read { db throws in
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM source") == 1,
                    "the reattached account must collapse to one source")
            let canonicalID = try #require(try Int64.fetchOne(db, sql: "SELECT id FROM source"))
            #expect(canonicalID == 2, "the newest source survives so its current credential is kept")
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track") == 1)
            let survivor = try #require(try Int64.fetchOne(db, sql: "SELECT id FROM track"))
            #expect(survivor == 1, "the track with the favorite is the survivor")
            #expect(try Int64.fetchOne(db, sql: "SELECT sourceId FROM track WHERE id = ?",
                                       arguments: [survivor]) == canonicalID)
            #expect(try Int64.fetchOne(db, sql: "SELECT COUNT(*) FROM favorite WHERE trackId = ?",
                                       arguments: [survivor]) == 1)
            #expect(try Int64.fetchOne(db, sql: "SELECT COUNT(*) FROM play_history WHERE trackId = ?",
                                       arguments: [survivor]) == 1,
                    "the loser's play history must move to the survivor")
            #expect(try Int64.fetchOne(db, sql: "SELECT COUNT(*) FROM playlist_item WHERE trackId = ?",
                                       arguments: [survivor]) == 1)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM album") == 1,
                    "same-titled albums from the merged sources collapse to one")
            #expect(try Int64.fetchOne(db, sql: "SELECT albumId FROM track WHERE id = ?",
                                       arguments: [survivor]) != nil)
            #expect(try Int64.fetchOne(db, sql: """
                SELECT trackId FROM remote_track_identity
                WHERE sourceId = ? AND identity = 'v1:id:drive-file-1'
                """, arguments: [canonicalID]) == survivor)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM merged_source WHERE oldSourceId = 1 AND canonicalSourceId = 2 AND kind = 'googleDrive'") == 1)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track_fts WHERE rowid = ?",
                                    arguments: [survivor]) == 1)
            #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
        }
    }

    @Test func testSameEndpointWithDifferentUsernameIsNotMerged() throws {
        let queue = try makeQueue()
        try queue.write { db in
            for (id, account) in [(1, "alice"), (2, "bob")] {
                try db.execute(sql: """
                    INSERT INTO source (kind, iaIdentifier, originalURL, title, addedAt,
                                        followUpdates, memberCapHit, localIsFolder)
                    VALUES ('webDAV', ?, 'https://music.example.com/dav', 'Music', ?, 0, 0, 0)
                    """, arguments: [account, Date(timeIntervalSince1970: Double(id))])
            }
        }
        try Schema.migrator().migrate(queue)
        try queue.read { db in
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM source") == 2,
                    "different accounts on the same endpoint are different libraries")
        }
    }

    @Test func testSameAccountAndEndpointIsMerged() throws {
        let queue = try makeQueue()
        try queue.write { db in
            for id in 1...2 {
                try db.execute(sql: """
                    INSERT INTO source (kind, iaIdentifier, originalURL, title, addedAt,
                                        followUpdates, memberCapHit, localIsFolder)
                    VALUES ('webDAV', 'alice', 'https://music.example.com/dav/', 'Music', ?, 0, 0, 0)
                    """, arguments: [Date(timeIntervalSince1970: Double(id))])
            }
        }
        try Schema.migrator().migrate(queue)
        try queue.read { db in
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM source") == 1)
            #expect(try Int64.fetchOne(db, sql: "SELECT id FROM source") == 2)
        }
    }

    @Test func testByteIdenticalLocalFilesFromDifferentRoutesAreMerged() throws {
        let queue = try makeQueue()
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO source (kind, title, addedAt, followUpdates, memberCapHit, localIsFolder)
                VALUES ('local', 'Local Files', ?, 0, 0, 0)
                """, arguments: [Date()])
            try db.execute(sql: "INSERT INTO album (sourceId, title) VALUES (1, 'Local Files')")
            for trackID in 1...2 {
                try db.execute(sql: """
                    INSERT INTO track (sourceId, albumId, title, sortKey, durationSec)
                    VALUES (1, 1, 'Same Bytes', '0001', ?)
                    """, arguments: [trackID == 1 ? 100.0 : 100.2])
                try db.execute(sql: """
                    INSERT INTO asset (trackId, kind, remoteURL, sizeBytes)
                    VALUES (?, 'localRef', ?, 4096)
                    """, arguments: [trackID, "file:///tmp/copy-\(trackID).wav"])
            }
            try db.execute(sql: "INSERT INTO favorite (trackId, favoritedAt) VALUES (2, ?)", arguments: [Date()])
            try db.execute(sql: "INSERT INTO play_history (trackId, playedAt) VALUES (1, ?)", arguments: [Date()])
        }

        try Schema.migrator().migrate(queue)

        try queue.read { db throws in
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track") == 1)
            let survivor = try #require(try Int64.fetchOne(db, sql: "SELECT id FROM track"))
            #expect(survivor == 2, "the favorite makes track 2 the survivor")
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM favorite WHERE trackId = ?",
                                    arguments: [survivor]) == 1)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM play_history WHERE trackId = ?",
                                    arguments: [survivor]) == 1)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset WHERE trackId = ?",
                                    arguments: [survivor]) == 1)
            #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
        }
    }

    @Test func testMigratingTwiceIsIdempotent() throws {
        let queue = try DatabaseQueue()
        try Schema.migrator().migrate(queue)
        try Schema.migrator().migrate(queue)
    }
}
