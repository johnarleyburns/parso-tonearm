import GRDB
import XCTest
@testable import TonearmCore

/// v46: `track.indexed` — a single flag set TRUE only once both `discovery_embedding` (CLAP) and
/// `discovery_track_analysis` (BPM/camelot/energy) exist for a track, closing the real gap where
/// those two commits were (and, pre-fix, still are at the SQL layer) two separate transactions —
/// `BoundedIndexWorker.commitAnalysis`'s doc comment documents exactly this. Real bug fix: Mood
/// search could return a track with a CLAP embedding but no BPM/key to mix-match against.
final class MigrationV46Tests: XCTestCase {
    private func makeQueue() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try Schema.migrator(upTo: "v45").migrate(queue)
        return queue
    }

    private func insertTrack(_ db: Database, sourceId: Int64) throws -> Int64 {
        try db.execute(sql: """
            INSERT INTO track (sourceId, title, sortKey, syncID) VALUES (?, 'T', 'a', ?)
            """, arguments: [sourceId, UUID().uuidString])
        return db.lastInsertedRowID
    }

    private func insertSource(_ db: Database) throws -> Int64 {
        try db.execute(sql: """
            INSERT INTO source (kind, title, addedAt, followUpdates, memberCapHit, syncID)
            VALUES ('local', 'Lib', ?, 0, 0, ?)
            """, arguments: [Date(), UUID().uuidString])
        return db.lastInsertedRowID
    }

    /// `discovery_embedding`/`discovery_track_analysis`'s `assetId` is a real `NOT NULL` FK to
    /// `asset` — a literal placeholder id with no matching row (the original version of this
    /// fixture used `1`) fails with "FOREIGN KEY constraint failed" the moment foreign keys are
    /// enforced. Insert a real asset row instead.
    private func insertAsset(_ db: Database, trackId: Int64) throws -> Int64 {
        try db.execute(sql: """
            INSERT INTO asset (trackId, kind, relPath, sizeBytes) VALUES (?, 'localRef', 'x', 1)
            """, arguments: [trackId])
        return db.lastInsertedRowID
    }

    private func insertEmbedding(_ db: Database, trackId: Int64, assetId: Int64) throws {
        try db.execute(sql: """
            INSERT INTO discovery_embedding
                (trackId, assetId, assetRevision, modelVersion, preprocessingVersion,
                 samplingVersion, dimensions, quantizedVector, scale, completedAt)
            VALUES (?, ?, 1, 1, 1, 1, 1, x'00', 1.0, ?)
            """, arguments: [trackId, assetId, Date()])
    }

    private func insertAnalysis(_ db: Database, trackId: Int64, assetId: Int64) throws {
        try db.execute(sql: """
            INSERT INTO discovery_track_analysis
                (trackId, assetId, assetRevision, analysisVersion, bpm, key, energy, completedAt)
            VALUES (?, ?, 1, 1, 120, '8A', 5.0, ?)
            """, arguments: [trackId, assetId, Date()])
    }

    private func insertJob(
        _ db: Database, trackId: Int64, embedding: String, analysis: String, state: String
    ) throws {
        try db.execute(sql: """
            INSERT INTO discovery_index_job
                (id, trackId, pipelineVersion, state, priority, createdAt, updatedAt,
                 attemptCount, completedWindows, totalWindows, embeddingStageState,
                 musicalAnalysisStageState)
            VALUES (?, ?, 1, ?, 0, ?, ?, 0, 0, 0, ?, ?)
            """, arguments: [
                UUID().uuidString, trackId, state, Date(), Date(), embedding, analysis,
            ])
    }

    func testV46AddsTheIndexedColumnDefaultingToFalse() throws {
        let queue = try makeQueue()
        var trackId: Int64 = 0
        try queue.write { db in
            let sourceId = try self.insertSource(db)
            trackId = try self.insertTrack(db, sourceId: sourceId)
        }
        try Schema.migrator().migrate(queue)
        try queue.read { db in
            let columns = Set(try db.columns(in: "track").map(\.name))
            XCTAssertTrue(columns.contains("indexed"))
            let row = try Row.fetchOne(db, sql: "SELECT indexed FROM track WHERE id = ?", arguments: [trackId])
            XCTAssertEqual(row?["indexed"] as Int?, 0, "an existing row must default to false, not true")
        }
    }

    func testMigratingTwiceIsIdempotent() throws {
        let queue = try DatabaseQueue()
        try Schema.migrator().migrate(queue)
        try Schema.migrator().migrate(queue)
    }

    /// The common, already-correct case: a track whose embedding AND analysis both already
    /// exist (however the old, non-atomic code got there) is retroactively marked indexed
    /// instantly, with no re-processing.
    func testBackfillMarksAlreadyFullyAnalyzedTracksIndexed() throws {
        let queue = try makeQueue()
        var trackId: Int64 = 0
        try queue.write { db in
            let sourceId = try self.insertSource(db)
            trackId = try self.insertTrack(db, sourceId: sourceId)
            let assetId = try self.insertAsset(db, trackId: trackId)
            try self.insertEmbedding(db, trackId: trackId, assetId: assetId)
            try self.insertAnalysis(db, trackId: trackId, assetId: assetId)
            try self.insertJob(
                db, trackId: trackId, embedding: "complete", analysis: "complete", state: "complete")
        }
        try Schema.migrator().migrate(queue)
        try queue.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT indexed FROM track WHERE id = ?", arguments: [trackId])
            XCTAssertEqual(row?["indexed"] as Int?, 1)
        }
    }

    /// The genuinely inconsistent case this migration exists to repair: a job already marked
    /// terminal-complete on both stages, but the track is missing one of the two tables (exactly
    /// the pre-fix race). It must be reset to a fresh, re-triable state rather than staying stuck
    /// `isComplete` forever with no data to show for it.
    func testInconsistentCompleteJobMissingAnalysisIsRequeued() throws {
        let queue = try makeQueue()
        var trackId: Int64 = 0
        try queue.write { db in
            let sourceId = try self.insertSource(db)
            trackId = try self.insertTrack(db, sourceId: sourceId)
            let assetId = try self.insertAsset(db, trackId: trackId)
            try self.insertEmbedding(db, trackId: trackId, assetId: assetId)
            // No analysis row -- the stuck-half-indexed state.
            try self.insertJob(
                db, trackId: trackId, embedding: "complete", analysis: "failed", state: "complete")
        }
        try Schema.migrator().migrate(queue)
        try queue.read { db in
            let trackRow = try Row.fetchOne(db, sql: "SELECT indexed FROM track WHERE id = ?", arguments: [trackId])
            XCTAssertEqual(trackRow?["indexed"] as Int?, 0, "must not be marked indexed without both tables")
            let jobRow = try Row.fetchOne(
                db, sql: "SELECT state, embeddingStageState, musicalAnalysisStageState, attemptCount FROM discovery_index_job WHERE trackId = ?",
                arguments: [trackId])
            XCTAssertEqual(jobRow?["state"] as String?, "queued", "must be reset to retry, not left stuck complete")
            XCTAssertEqual(jobRow?["embeddingStageState"] as String?, "pending")
            XCTAssertEqual(jobRow?["musicalAnalysisStageState"] as String?, "pending")
            XCTAssertEqual(jobRow?["attemptCount"] as Int?, 0)
        }
    }

    /// A job still genuinely in progress (not yet terminal on both stages) must be left
    /// completely untouched -- the migration only repairs already-"complete" inconsistencies,
    /// never interferes with real in-flight work.
    func testInProgressJobIsNotTouchedByBackfill() throws {
        let queue = try makeQueue()
        var trackId: Int64 = 0
        try queue.write { db in
            let sourceId = try self.insertSource(db)
            trackId = try self.insertTrack(db, sourceId: sourceId)
            let assetId = try self.insertAsset(db, trackId: trackId)
            try self.insertEmbedding(db, trackId: trackId, assetId: assetId)
            try self.insertJob(
                db, trackId: trackId, embedding: "complete", analysis: "pending", state: "queued")
        }
        try Schema.migrator().migrate(queue)
        try queue.read { db in
            let jobRow = try Row.fetchOne(
                db, sql: "SELECT embeddingStageState FROM discovery_index_job WHERE trackId = ?",
                arguments: [trackId])
            XCTAssertEqual(jobRow?["embeddingStageState"] as String?, "complete",
                "a genuinely in-progress job's completed embedding stage must not be reset")
        }
    }

    /// Regression: the original v46 attempt broke roughly a dozen unrelated pre-existing tests
    /// that migrate to a pre-v46 schema snapshot and then fetch `Track` rows through GRDB's
    /// default `FetchableRecord` conformance -- a genuinely-missing (not merely NULL) column on a
    /// non-optional property throws "column not found" rather than falling back to the property's
    /// Swift default. `Track.init(row:)` (`Records.swift`) must decode such a row without
    /// throwing, same as every test and call site did before this column ever existed.
    func testFetchingTrackAgainstPreV46SchemaDoesNotThrow() throws {
        let queue = try makeQueue()
        try queue.write { db in
            let sourceId = try self.insertSource(db)
            _ = try self.insertTrack(db, sourceId: sourceId)
        }
        try queue.read { db in
            let tracks = try Track.fetchAll(db, sql: "SELECT * FROM track")
            XCTAssertEqual(tracks.count, 1)
            XCTAssertEqual(tracks.first?.indexed, false, "a pre-v46 row has no column to read -- defaults to false")
        }
    }
}
