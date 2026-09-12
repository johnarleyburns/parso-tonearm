import XCTest
import GRDB

@testable import TonearmDJ

/// `dj_v3` originally created the embedding tables backing the DJ-local
/// semantic-search subsystem (`VectorStore`/`SemanticSearchService`/
/// `EmbeddingCoordinator`). That subsystem was deleted from `Sources`
/// before C02's catalog deletion, and `dj_v12` (IMPLEMENT_CLAP_PLAN.md C02)
/// went on to drop `track_embedding`/`window_embedding` themselves outright
/// — they were both dead schema (no reader/writer left in `Sources`) AND an
/// FK into the now-deleted DJ-local `track` table. `DJTrackEmbedding`/
/// `DJWindowEmbedding` (the record types) were deleted along with the
/// catalog surface, so the round-trip tests that exercised them are gone
/// too — not fixture-mechanics issues, genuinely deleted functionality.
/// `embedding_version`/`vector_matrix_meta` never referenced `track` and
/// are untouched — their tests remain.
final class MigrationV3Tests: XCTestCase {

    func testMigrationOrderIsAppendOnly() {
        XCTAssertEqual(DJSchema.migrationOrder,
                       ["dj_v1", "dj_v2", "dj_v3", "dj_v4", "dj_v5", "dj_v6", "dj_v7", "dj_v8", "dj_v9", "dj_v10", "dj_v11", "dj_v12"])
        XCTAssertEqual(DJSchema.migrator().migrations,
                       ["dj_v1", "dj_v2", "dj_v3", "dj_v4", "dj_v5", "dj_v6", "dj_v7", "dj_v8", "dj_v9", "dj_v10", "dj_v11", "dj_v12"])
    }

    func testV3EmbeddingVersionAndVectorMatrixMetaSurviveButTrackEmbeddingTablesAreGone() throws {
        let db = try DatabaseQueue()
        try DJSchema.migrator().migrate(db)
        try db.read { db in
            for table in ["embedding_version", "vector_matrix_meta"] {
                XCTAssertTrue(try db.tableExists(table), "missing table \(table)")
            }
            for table in ["track_embedding", "window_embedding"] {
                XCTAssertFalse(try db.tableExists(table),
                               "\(table) backed the deleted semantic-search subsystem and had an FK into the deleted catalog `track` table — dj_v12 drops it outright")
            }
        }
    }

    func testEmbeddingVersionSeeded() throws {
        let db = try DatabaseQueue()
        try DJSchema.migrator().migrate(db)
        let row = try db.read { db in
            try DJEmbeddingVersion.fetchAll(db).first
        }
        let seeded = try XCTUnwrap(row)
        XCTAssertEqual(seeded.version, 1)
        XCTAssertEqual(seeded.modelName, EmbeddingModelSpec.musicCLAPMetadata.modelName)
        XCTAssertEqual(seeded.dimensions, 512)
        XCTAssertEqual(seeded.windowSeconds, 10)
        XCTAssertEqual(seeded.hopSeconds, 5)
        XCTAssertEqual(seeded.pooling, "attention")
    }

    func testVectorMatrixMetaSingleton() throws {
        let db = try DatabaseQueue()
        try DJSchema.migrator().migrate(db)
        try db.write { db in
            var meta = DJVectorMatrixMeta(id: 1, rowCount: 0, tombstoneCount: 0,
                                          dims: 512, tier: "A", lastCompactedAt: nil)
            try meta.insert(db)
        }
        let fetched = try db.read { db in
            try DJVectorMatrixMeta.fetchAll(db).first
        }
        XCTAssertEqual(fetched?.tier, "A")
        XCTAssertEqual(fetched?.dims, 512)
    }

    /// C02 (`dj_v12`): `track` itself is the deleted duplicate catalog, not
    /// a "prior table" append-only guarantees keep — `analysis_run`-family
    /// tables (recreated FK-free by `dj_v12`, not dropped outright) are the
    /// right survivors to check here.
    func testAppendOnlyKeepsPriorSupplementaryTables() throws {
        let db = try DatabaseQueue()
        try DJSchema.migrator().migrate(db)
        try db.read { db in
            for table in ["analysis_version", "loudness", "beat_grid"] {
                XCTAssertTrue(try db.tableExists(table), "missing table \(table)")
            }
            XCTAssertFalse(try db.tableExists("track"),
                           "the DJ-local catalog `track` table is deleted, not kept")
        }
    }
}
