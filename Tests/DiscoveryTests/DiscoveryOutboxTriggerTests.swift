import GRDB
import XCTest

@testable import TonearmCore
@testable import TonearmDiscovery

/// C03 follow-up fixture: the `v19` SQL triggers
/// (`Sources/Data/DiscoveryMigrations.swift`) are the real outbox write-path
/// wiring plan §5 calls for ("Trace `ImportRouter`, AppState import methods,
/// folder scanning, remote provider sync, ... LibraryStore insert/update
/// methods and AudioCache completion. All committed core tracks become
/// discoverable by the outbox/reconciler"). Rather than re-instrument every
/// named call site, `v19` installs triggers directly on `track`/`asset` so
/// ANY writer — including ones not yet audited here — produces a real
/// `discovery_change` row.
///
/// Session 2/3 left this honestly marked as "no production code path creates
/// [outbox rows] yet ... this session's reconciler tests insert
/// `discovery_change` rows directly with raw SQL." This file closes that gap
/// by driving the triggers with plain `INSERT`/`UPDATE`/`DELETE` statements
/// (no manual outbox inserts) and, in the final test, a real `LibraryStore`
/// import end to end into a real `discovery_index_job`.
final class DiscoveryOutboxTriggerTests: XCTestCase {
    private func makeQueue() throws -> DatabaseQueue {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: config)
        try Schema.migrator().migrate(queue)
        return queue
    }

    @discardableResult
    private func insertSource(_ db: Database) throws -> Int64 {
        try db.execute(
            sql: """
                INSERT INTO source (kind, title, addedAt, followUpdates, memberCapHit, localIsFolder)
                VALUES ('local', 'Music', ?, 0, 0, 1)
                """, arguments: [Date()])
        return db.lastInsertedRowID
    }

    private func changes(_ db: Database) throws -> [DiscoveryChange] {
        try DiscoveryChange.order(Column("id")).fetchAll(db)
    }

    func testInsertingTrackFiresTrackInsertedTrigger() throws {
        let queue = try makeQueue()
        try queue.write { db in
            let sourceID = try self.insertSource(db)
            try db.execute(
                sql: "INSERT INTO track (sourceId, title, sortKey) VALUES (?, 'Song', 'song')",
                arguments: [sourceID])
            let trackID = db.lastInsertedRowID

            let rows = try self.changes(db)
            XCTAssertEqual(rows.count, 1)
            XCTAssertEqual(rows[0].kind, .trackInserted)
            XCTAssertEqual(rows[0].trackId, trackID)
        }
    }

    func testInsertingAssetFiresTrackInsertedTriggerForItsTrack() throws {
        let queue = try makeQueue()
        try queue.write { db in
            let sourceID = try self.insertSource(db)
            try db.execute(
                sql: "INSERT INTO track (sourceId, title, sortKey) VALUES (?, 'Song', 'song')",
                arguments: [sourceID])
            let trackID = db.lastInsertedRowID
            // Drain the track-insert row so the asset-insert trigger's row is
            // unambiguous below.
            try db.execute(sql: "DELETE FROM discovery_change")

            try db.execute(
                sql: "INSERT INTO asset (trackId, kind, relPath) VALUES (?, 'localFile', 'song.m4a')",
                arguments: [trackID])

            let rows = try self.changes(db)
            XCTAssertEqual(rows.count, 1)
            XCTAssertEqual(rows[0].kind, .trackInserted)
            XCTAssertEqual(rows[0].trackId, trackID)
        }
    }

    func testUpdatingTrackTitleFiresMetadataUpdatedTrigger() throws {
        let queue = try makeQueue()
        try queue.write { db in
            let sourceID = try self.insertSource(db)
            try db.execute(
                sql: "INSERT INTO track (sourceId, title, sortKey) VALUES (?, 'Song', 'song')",
                arguments: [sourceID])
            let trackID = db.lastInsertedRowID
            try db.execute(sql: "DELETE FROM discovery_change")

            try db.execute(sql: "UPDATE track SET title = 'Renamed' WHERE id = ?", arguments: [trackID])

            let rows = try self.changes(db)
            XCTAssertEqual(rows.count, 1)
            XCTAssertEqual(rows[0].kind, .trackMetadataUpdated)
            XCTAssertEqual(rows[0].trackId, trackID)
        }
    }

    func testUpdatingAssetContentColumnFiresAssetContentReplacedTrigger() throws {
        let queue = try makeQueue()
        try queue.write { db in
            let sourceID = try self.insertSource(db)
            try db.execute(
                sql: "INSERT INTO track (sourceId, title, sortKey) VALUES (?, 'Song', 'song')",
                arguments: [sourceID])
            let trackID = db.lastInsertedRowID
            try db.execute(
                sql: "INSERT INTO asset (trackId, kind, relPath) VALUES (?, 'localFile', 'song.m4a')",
                arguments: [trackID])
            let assetID = db.lastInsertedRowID
            try db.execute(sql: "DELETE FROM discovery_change")

            try db.execute(
                sql: "UPDATE asset SET relPath = 'song-remastered.m4a' WHERE id = ?",
                arguments: [assetID])

            let rows = try self.changes(db)
            XCTAssertEqual(rows.count, 1)
            XCTAssertEqual(rows[0].kind, .assetContentReplaced)
            XCTAssertEqual(rows[0].trackId, trackID)
        }
    }

    /// Plan §4: "Cache path/last-access changes alone are NOT content
    /// revisions." Updating a non-content column on `asset` must not fire
    /// `assetContentReplaced`.
    func testUpdatingAssetNonContentColumnDoesNotFireContentReplaced() throws {
        let queue = try makeQueue()
        try queue.write { db in
            let sourceID = try self.insertSource(db)
            try db.execute(
                sql: "INSERT INTO track (sourceId, title, sortKey) VALUES (?, 'Song', 'song')",
                arguments: [sourceID])
            let trackID = db.lastInsertedRowID
            try db.execute(
                sql: "INSERT INTO asset (trackId, kind, relPath) VALUES (?, 'localFile', 'song.m4a')",
                arguments: [trackID])
            let assetID = db.lastInsertedRowID
            try db.execute(sql: "DELETE FROM discovery_change")

            try db.execute(
                sql: "UPDATE asset SET unsupportedReason = 'codec unsupported' WHERE id = ?",
                arguments: [assetID])
            try db.execute(
                sql: "UPDATE asset SET needsReimport = 1 WHERE id = ?", arguments: [assetID])

            let rows = try self.changes(db)
            XCTAssertTrue(
                rows.isEmpty,
                "cache/status-only asset column changes must not create a content-replaced event")
        }
    }

    func testDeletingTrackFiresTrackDeletedTriggerWithNullTrackId() throws {
        let queue = try makeQueue()
        try queue.write { db in
            let sourceID = try self.insertSource(db)
            try db.execute(
                sql: "INSERT INTO track (sourceId, title, sortKey) VALUES (?, 'Song', 'song')",
                arguments: [sourceID])
            let trackID = db.lastInsertedRowID
            try db.execute(sql: "DELETE FROM discovery_change")

            try db.execute(sql: "DELETE FROM track WHERE id = ?", arguments: [trackID])

            let rows = try self.changes(db)
            XCTAssertEqual(rows.count, 1)
            XCTAssertEqual(rows[0].kind, .trackDeleted)
            XCTAssertNil(rows[0].trackId, "the deleted track's own id must not be referenced")
        }
    }

    func testDeletingSourceFiresSourceDeletedTrigger() throws {
        let queue = try makeQueue()
        try queue.write { db in
            let sourceID = try self.insertSource(db)
            try db.execute(sql: "DELETE FROM discovery_change")

            try db.execute(sql: "DELETE FROM source WHERE id = ?", arguments: [sourceID])

            let rows = try self.changes(db)
            XCTAssertEqual(rows.count, 1)
            XCTAssertEqual(rows[0].kind, .sourceDeleted)
            XCTAssertNil(rows[0].trackId)
        }
    }

    /// End-to-end: a real `LibraryStore` import (no manual outbox SQL
    /// anywhere in this test) must produce a real, drainable
    /// `discovery_index_job` through the trigger + reconciler pipeline.
    func testRealLibraryStoreImportProducesARealDiscoveryIndexJob() async throws {
        let store = try LibraryStore(inMemory: true)
        var source = Source(id: nil, kind: .local, iaIdentifier: nil, originalURL: nil,
                             title: "Local Files", addedAt: Date(), lastResolvedAt: nil,
                             followUpdates: false, licenseText: nil, memberCapHit: false)
        source = try await store.insertSource(source)
        var track = Track(id: nil, albumId: nil, sourceId: source.id!, title: "Song",
                           trackNo: 1, discNo: nil, durationSec: 180, codec: "MP3",
                           sampleRate: nil, bitDepthOrBitrate: nil, sortKey: "0001",
                           genre: nil, composer: nil, artistId: nil,
                           rgTrackGain: nil, rgAlbumGain: nil, rgTrackPeak: nil, rgAlbumPeak: nil)
        track = try await store.insertTrack(track)
        let asset = Asset(id: nil, trackId: track.id!, kind: .localRef, bookmark: nil,
                           relPath: nil, remoteURL: "file:///song.mp3", altRemoteURL: nil,
                           sizeBytes: nil, unsupportedReason: nil)
        try await store.insertAsset(asset)

        let writer = await store.dbQueue
        let repo = IndexJobRepository(writer: writer)
        let reconciler = DiscoveryReconciler(writer: writer, jobs: repo, pipelineVersion: 1)
        let processed = try await reconciler.processOutbox()
        XCTAssertGreaterThanOrEqual(
            processed, 1, "the track/asset insert triggers must have produced outbox rows")

        let job = try await repo.job(trackId: track.id!, pipelineVersion: 1)
        XCTAssertNotNil(job, "a real LibraryStore import must yield a real discovery_index_job")
        XCTAssertEqual(job?.state, .queued)

        let remaining = try await writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM discovery_change")!
        }
        XCTAssertEqual(remaining, 0, "processOutbox must drain everything the triggers wrote")
    }
}
