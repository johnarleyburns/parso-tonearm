import GRDB
import XCTest
@testable import TonearmCore

/// v44: drops 13 of `dj_track_prep`'s 17 non-key columns (hot cues, loops, a full
/// analysis-payload blob) — confirmed zero readers anywhere outside the DJ plumbing files
/// themselves. Only `bpm`/`camelotKey`/`bpmOverride` (read by `djLoadTrackInfo`) and `syncID`/
/// `analysisUpdatedAt` (sync bookkeeping) survive. A plain `ALTER TABLE ... DROP COLUMN` can't
/// remove `loopInSeconds`/`loopOutSeconds` directly (SQLite refuses to drop a column its own
/// CHECK constraint references), so this migration rebuilds the table instead.
final class MigrationV44Tests: XCTestCase {
    func testV44DropsTheDeadColumnsAndKeepsTheLiveOnes() throws {
        let queue = try DatabaseQueue()
        try Schema.migrator(upTo: "v43").migrate(queue)

        var trackId: Int64 = 0
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO source (kind, title, addedAt, followUpdates, memberCapHit,
                                    localIsFolder, syncID)
                VALUES ('local', 'Music', ?, 0, 0, 1, ?)
                """, arguments: [Date(), UUID().uuidString])
            let sourceId = db.lastInsertedRowID
            try db.execute(sql: """
                INSERT INTO track (sourceId, title, sortKey, syncID)
                VALUES (?, 'Track', 'a', ?)
                """, arguments: [sourceId, UUID().uuidString])
            trackId = db.lastInsertedRowID
            try db.execute(sql: """
                INSERT INTO dj_track_prep
                (trackId, hotCuesJSON, cuePointSeconds, loopInSeconds, loopOutSeconds,
                 hotCuesUpdatedAt, analysisPayload, analysisAlgorithm, analysisPayloadVersion,
                 sourceSampleRate, sourceFrameCount, bpm, camelotKey, analysisUpdatedAt, syncID,
                 bpmOverride, firstBeatOverride, keyShiftSemitones)
                VALUES (?, '{"1":2.5}', 1.0, 8, 12, ?, ?, 'pae-1.2', 1, 48000, 123, 126, '8A', ?,
                        'PREP-1', 130, 0.25, 2)
                """, arguments: [trackId, Date(), Data([1, 2, 3]), Date()])
        }

        // Migrate to head (v44).
        try Schema.migrator().migrate(queue)

        try queue.read { db in
            let columns = Set(try db.columns(in: "dj_track_prep").map(\.name))
            XCTAssertEqual(columns, ["trackId", "bpm", "camelotKey", "analysisUpdatedAt", "syncID", "bpmOverride"])

            let row = try XCTUnwrap(try DJTrackPrep.fetchOne(db, key: trackId))
            XCTAssertEqual(row.bpm, 126)
            XCTAssertEqual(row.camelotKey, "8A")
            XCTAssertEqual(row.syncID, "PREP-1")
            XCTAssertEqual(row.bpmOverride, 130)
            XCTAssertNotNil(row.analysisUpdatedAt)
        }
    }

    func testMigratingTwiceIsIdempotent() throws {
        let queue = try DatabaseQueue()
        try Schema.migrator().migrate(queue)
        try Schema.migrator().migrate(queue)
    }

    /// The rebuilt table keeps its foreign-key cascade from `track` — deleting the track must
    /// still remove its `dj_track_prep` row.
    func testForeignKeyCascadeSurvivesTheRebuild() throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: config)
        try Schema.migrator().migrate(queue)

        var trackId: Int64 = 0
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO source (kind, title, addedAt, followUpdates, memberCapHit,
                                    localIsFolder, syncID)
                VALUES ('local', 'Music', ?, 0, 0, 1, ?)
                """, arguments: [Date(), UUID().uuidString])
            let sourceId = db.lastInsertedRowID
            try db.execute(sql: """
                INSERT INTO track (sourceId, title, sortKey, syncID)
                VALUES (?, 'Track', 'a', ?)
                """, arguments: [sourceId, UUID().uuidString])
            trackId = db.lastInsertedRowID
            var prep = DJTrackPrep(trackId: trackId, bpm: 120, camelotKey: "5A")
            try prep.insert(db)
        }

        try queue.write { db in
            try db.execute(sql: "DELETE FROM track WHERE id = ?", arguments: [trackId])
        }

        let remaining = try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM dj_track_prep WHERE trackId = ?", arguments: [trackId])
        }
        XCTAssertEqual(remaining, 0)
    }
}
