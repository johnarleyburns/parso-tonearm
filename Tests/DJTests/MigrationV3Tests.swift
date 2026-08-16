import XCTest
import GRDB

@testable import TonearmDJ

final class MigrationV3Tests: XCTestCase {

    func testMigrationOrderIsAppendOnly() {
        XCTAssertEqual(DJSchema.migrationOrder,
                       ["dj_v1", "dj_v2", "dj_v3", "dj_v4", "dj_v5", "dj_v6"])
        XCTAssertEqual(DJSchema.migrator().migrations,
                       ["dj_v1", "dj_v2", "dj_v3", "dj_v4", "dj_v5", "dj_v6"])
    }

    func testV3CreatesEmbeddingTables() throws {
        let db = try DatabaseQueue()
        try DJSchema.migrator().migrate(db)
        try db.read { db in
            for table in ["embedding_version", "track_embedding",
                          "window_embedding", "vector_matrix_meta"] {
                XCTAssertTrue(try db.tableExists(table), "missing table \(table)")
            }
            for index in ["idx_trackemb_row", "idx_winemb_track"] {
                let exists = try Int.fetchOne(db, sql: """
                    SELECT 1 FROM sqlite_master
                    WHERE type = 'index' AND name = ?
                    """, arguments: [index]) != nil
                XCTAssertTrue(exists, "missing index \(index)")
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

    func testTrackEmbeddingRoundTrip() throws {
        let db = try DatabaseQueue()
        try DJSchema.migrator().migrate(db)

        let now = Date()
        var track = DJTrack(syncID: UUID().uuidString, title: "Halcyon",
                            contentHash: "abc", sortKey: "halcyon",
                            addedAt: now, updatedAt: now)
        try db.write { db in
            try track.insert(db)

            let int8 = [Int8](repeating: 0, count: 512)
            var embedding = DJTrackEmbedding(trackID: track.id!, int8Vector: int8,
                                             scale: 0.0078, matrixRow: 3, version: 1)
            try embedding.insert(db)
        }

        let fetched = try db.read { db in
            try DJTrackEmbedding
                .filter(Column("trackID") == track.id!)
                .fetchOne(db)
        }
        let value = try XCTUnwrap(fetched)
        XCTAssertEqual(value.trackID, track.id!)
        XCTAssertEqual(value.dims, 512)
        XCTAssertEqual(value.scale, 0.0078)
        XCTAssertEqual(value.matrixRow, 3)
        XCTAssertEqual(value.version, 1)
        XCTAssertEqual(value.int8Vector, [Int8](repeating: 0, count: 512))
    }

    func testWindowEmbeddingRoundTrip() throws {
        let db = try DatabaseQueue()
        try DJSchema.migrator().migrate(db)

        let now = Date()
        var track = DJTrack(syncID: UUID().uuidString, title: "Windowed",
                            contentHash: "xyz", sortKey: "windowed",
                            addedAt: now, updatedAt: now)
        try db.write { db in
            try track.insert(db)
            var window = DJWindowEmbedding(trackID: track.id!, windowIndex: 2,
                                           startSample: 480_000, endSample: 960_000,
                                           vector: Data([1, 2, 3]), scale: 0.5, version: 1)
            try window.insert(db)
        }

        let fetched = try db.read { db in
            try DJWindowEmbedding
                .filter(Column("trackID") == track.id!)
                .fetchOne(db)
        }
        let value = try XCTUnwrap(fetched)
        XCTAssertEqual(value.windowIndex, 2)
        XCTAssertEqual(value.startSample, 480_000)
        XCTAssertEqual(value.endSample, 960_000)
        XCTAssertEqual(value.vector, Data([1, 2, 3]))
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

    func testAppendOnlyKeepsPriorTables() throws {
        let db = try DatabaseQueue()
        try DJSchema.migrator().migrate(db)
        try db.read { db in
            for table in ["track", "analysis_version", "loudness", "beat_grid"] {
                XCTAssertTrue(try db.tableExists(table), "missing table \(table)")
            }
        }
    }
}
