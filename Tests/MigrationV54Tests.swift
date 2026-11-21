import GRDB
import Foundation
import Testing
@testable import TonearmCore

/// v54: cloud Sources created from a raw token (or an older token response
/// without an account label) get merged by provider-native node-ID overlap.
/// The same files under one account prove the same library even when no email
/// label was persisted; disjoint or weakly-overlapping accounts stay separate.
@Suite struct MigrationV54Tests {
    private func makeQueue() throws -> DatabaseQueue {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: config)
        try Schema.migrator(upTo: "v53").migrate(queue)
        return queue
    }

    private func insertCloudSource(_ db: Database, kind: String = "oneDrive") throws -> Int64 {
        try db.execute(sql: """
            INSERT INTO source (kind, title, addedAt, followUpdates, memberCapHit, localIsFolder)
            VALUES (?, 'Cloud', ?, 0, 0, 0)
            """, arguments: [kind, Date()])
        return db.lastInsertedRowID
    }

    private func insertTracks(_ db: Database, sourceID: Int64, nodes: [String]) throws -> [Int64] {
        try db.execute(sql: "INSERT INTO album (sourceId, title) VALUES (?, 'Cloud')",
                       arguments: [sourceID])
        let albumID = db.lastInsertedRowID
        var ids: [Int64] = []
        for node in nodes {
            try db.execute(sql: """
                INSERT INTO track (sourceId, albumId, title, sortKey, durationSec)
                VALUES (?, ?, ?, '0001', 100)
                """, arguments: [sourceID, albumID, node])
            let trackID = db.lastInsertedRowID
            try db.execute(sql: """
                INSERT INTO asset (trackId, kind, remoteURL, remoteNodeID, sizeBytes)
                VALUES (?, 'remote', ?, ?, 4096)
                """, arguments: [trackID, "https://cloud.example/\(node)", node])
            ids.append(trackID)
        }
        return ids
    }

    @Test func testOverlappingUnlabelledCloudSourcesMerge() throws {
        let queue = try makeQueue()
        let first = try queue.write { db -> (Int64, [Int64]) in
            let source = try insertCloudSource(db)
            let tracks = try insertTracks(db, sourceID: source, nodes: (1...10).map { "shared-\($0)" })
            try db.execute(sql: "INSERT INTO favorite (trackId, favoritedAt) VALUES (?, ?)",
                           arguments: [tracks[0], Date()])
            return (source, tracks)
        }
        try queue.write { db in
            let source = try insertCloudSource(db)
            let tracks = try insertTracks(db, sourceID: source, nodes: (1...10).map { "shared-\($0)" })
            try db.execute(sql: "INSERT INTO play_history (trackId, playedAt) VALUES (?, ?)",
                           arguments: [tracks[0], Date()])
        }

        try Schema.migrator().migrate(queue)

        try queue.read { db throws in
            let sourceCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM source")
            let canonical = try Int64.fetchOne(db, sql: "SELECT id FROM source")
            let trackCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track")
            let survivorRaw = try Int64.fetchOne(db, sql: "SELECT trackId FROM favorite")
            let survivor = try #require(survivorRaw)
            let favorite = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM favorite WHERE trackId = ?", arguments: [survivor])
            let history = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM play_history WHERE trackId = ?", arguments: [survivor])
            let audit = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM merged_source WHERE oldSourceId = ? AND canonicalSourceId = ?",
                arguments: [first.0, canonical])
            let violations = try Row.fetchAll(db, sql: "PRAGMA foreign_key_check")

            #expect(sourceCount == 1)
            #expect(canonical == 2, "newest source survives with its credential")
            #expect(trackCount == 10, "one track per shared provider node")
            #expect(favorite == 1)
            #expect(history == 1, "the loser's play history moves to the survivor")
            #expect(audit == 1)
            #expect(violations.isEmpty)
        }
    }

    @Test func testDisjointUnlabelledCloudSourcesStaySeparate() throws {
        let queue = try makeQueue()
        try queue.write { db in
            let first = try insertCloudSource(db)
            _ = try insertTracks(db, sourceID: first, nodes: (1...5).map { "a-\($0)" })
            let second = try insertCloudSource(db)
            _ = try insertTracks(db, sourceID: second, nodes: (1...5).map { "b-\($0)" })
        }
        try Schema.migrator().migrate(queue)
        try queue.read { db in
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM source")
            #expect(count == 2, "different accounts with no shared files must stay separate")
        }
    }

    @Test func testWeakOverlapDoesNotMergeAccounts() throws {
        let queue = try makeQueue()
        try queue.write { db in
            let first = try insertCloudSource(db)
            _ = try insertTracks(db, sourceID: first, nodes: (1...10).map { "a-\($0)" })
            let second = try insertCloudSource(db)
            _ = try insertTracks(db, sourceID: second,
                                 nodes: (8...10).map { "a-\($0)" } + (1...7).map { "b-\($0)" })
        }
        try Schema.migrator().migrate(queue)
        try queue.read { db in
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM source")
            #expect(count == 2, "a few shared files are not enough to merge two accounts")
        }
    }

    @Test func testDifferentProvidersNeverMergeOnSharedNodes() throws {
        let queue = try makeQueue()
        try queue.write { db in
            let first = try insertCloudSource(db, kind: "googleDrive")
            _ = try insertTracks(db, sourceID: first, nodes: (1...5).map { "same-\($0)" })
            let second = try insertCloudSource(db, kind: "oneDrive")
            _ = try insertTracks(db, sourceID: second, nodes: (1...5).map { "same-\($0)" })
        }
        try Schema.migrator().migrate(queue)
        try queue.read { db in
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM source")
            #expect(count == 2)
        }
    }

    @Test func testMigratingTwiceIsIdempotent() throws {
        let queue = try DatabaseQueue()
        try Schema.migrator().migrate(queue)
        try Schema.migrator().migrate(queue)
    }
}
