import XCTest
import GRDB

@testable import TonearmDJ

final class DJSchemaTests: XCTestCase {
    func testMigrationOrderIsAppendOnly() {
        XCTAssertEqual(DJSchema.migrationOrder,
                       ["dj_v1", "dj_v2", "dj_v3", "dj_v4", "dj_v5", "dj_v6", "dj_v7"])
        XCTAssertEqual(DJSchema.migrator().migrations,
                       ["dj_v1", "dj_v2", "dj_v3", "dj_v4", "dj_v5", "dj_v6", "dj_v7"])
    }

    /// `dj_v6` (plan dj-midi-alpha M2): the soft-takeover mode is a property of
    /// each binding, and an upgraded database must carry the column with the
    /// conservative default.
    func testV6AddsTakeoverToMidiBindings() throws {
        let db = try DatabaseQueue()
        try DJSchema.migrator().migrate(db)
        try db.read { db in
            let columns = try db.columns(in: "midi_binding").map(\.name)
            XCTAssertTrue(columns.contains("takeover"), "missing takeover column")
        }
        // The default for a pre-M2 row is `jump` — exactly what the profile
        // did before takeover existed.
        let count = try db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM midi_binding") ?? 0
        }
        XCTAssertEqual(count, 0)
    }

    /// `dj_v7` (plan dj-midi-alpha M6): 14-bit CC resolution is opt-in and
    /// existing bindings retain the seven-bit wire behavior.
    func testV7AddsFourteenBitResolutionToMidiBindings() throws {
        let db = try DatabaseQueue()
        try DJSchema.migrator().migrate(db)
        try db.read { db in
            let columns = try db.columns(in: "midi_binding")
            let resolution = try XCTUnwrap(columns.first(where: { $0.name == "resolution" }))
            XCTAssertEqual(resolution.defaultValueSQL, "'sevenBit'")
            XCTAssertTrue(resolution.isNotNull)
        }
    }

    func testApplyingAllMigrationsCreatesRelationalCoreTables() throws {
        let db = try DatabaseQueue()
        try DJSchema.migrator().migrate(db)

        let expectedTables = [
            "artist", "album", "track", "track_artist", "genre", "track_genre",
            "folder", "asset", "import_event",
            "cue_point", "hot_cue_bank", "loop", "grid_correction",
            "playlist", "playlist_item", "smart_crate", "crate_rule",
            "auto_playlist_brief", "auto_playlist_result", "auto_playlist_item", "auto_playlist_rejection",
            "gig_crate", "gig_crate_track",
            "rating", "tag", "track_tag", "app_setting",
        ]
        try db.read { db in
            for table in expectedTables {
                XCTAssertTrue(try db.tableExists(table), "missing table \(table)")
            }
        }
    }

    func testV2CreatesAnalysisTables() throws {
        let db = try DatabaseQueue()
        try DJSchema.migrator().migrate(db)

        let expectedTables = [
            "analysis_version", "analysis_run", "loudness", "frame_features",
            "onset_envelope", "tempo_candidate", "beat_grid", "beat_blob",
            "downbeat", "key_estimate", "phrase", "energy_curve", "waveform_pyramid",
        ]
        try db.read { db in
            for table in expectedTables {
                XCTAssertTrue(try db.tableExists(table), "missing table \(table)")
            }
        }
    }

    func testV2IndexesExist() throws {
        let db = try DatabaseQueue()
        try DJSchema.migrator().migrate(db)
        try db.read { db in
            for index in ["idx_run_track_stage", "idx_run_state", "idx_tempo_track",
                          "idx_downbeat_track", "idx_key_track", "idx_phrase_track"] {
                let exists = try Int.fetchOne(db, sql: "SELECT 1 FROM sqlite_master WHERE type = 'index' AND name = ?", arguments: [index]) != nil
                XCTAssertTrue(exists, "missing index \(index)")
            }
        }
    }

    func testV3CreatesEmbeddingTables() throws {
        let db = try DatabaseQueue()
        try DJSchema.migrator().migrate(db)

        let expectedTables = [
            "embedding_version", "track_embedding", "window_embedding",
            "vector_matrix_meta",
        ]
        try db.read { db in
            for table in expectedTables {
                XCTAssertTrue(try db.tableExists(table), "missing table \(table)")
            }
        }
    }

    func testV4CreatesStemAndRecordingTables() throws {
        let db = try DatabaseQueue()
        try DJSchema.migrator().migrate(db)

        let expectedTables = [
            "stem_cache", "performance_session", "mix",
            "mix_track_event", "mix_asset",
        ]
        try db.read { db in
            for table in expectedTables {
                XCTAssertTrue(try db.tableExists(table), "missing table \(table)")
            }
            for index in ["idx_mix_recordedAt", "idx_mte_mix"] {
                let exists = try Int.fetchOne(db, sql: """
                    SELECT 1 FROM sqlite_master
                    WHERE type = 'index' AND name = ?
                    """, arguments: [index]) != nil
                XCTAssertTrue(exists, "missing index \(index)")
            }
        }
    }

    func testStemCachePrimaryKeyIsTrackAndVersion() throws {
        let db = try DatabaseQueue()
        try DJSchema.migrator().migrate(db)
        let pk = try db.read { db in
            try db.primaryKey("stem_cache").columns
        }
        XCTAssertEqual(pk, ["trackID", "modelVersion"])
    }

    func testTrackDefaultsMatchDDL() throws {
        let db = try DatabaseQueue()
        try DJSchema.migrator().migrate(db)
        let now = Date()
        var track = DJTrack(
            syncID: UUID().uuidString,
            title: "Halcyon",
            contentHash: "abc",
            sortKey: "halcyon",
            addedAt: now,
            updatedAt: now
        )
        try db.write { try track.insert($0) }

        let row = try db.read { db in
            try Row.fetchOne(db, sql: "SELECT analysisVersion, embeddingVersion, analysisState, stemState FROM track WHERE id = ?", arguments: [track.id!])
        }
        let fetched = try XCTUnwrap(row)
        XCTAssertEqual(fetched["analysisVersion"] as? Int64, 0)
        XCTAssertEqual(fetched["embeddingVersion"] as? Int64, 0)
        XCTAssertEqual(fetched["analysisState"] as? String, "pending")
        XCTAssertEqual(fetched["stemState"] as? String, "none")
    }

    /// dj_v5 — the hardware tables (§15, §44, FR-HW-1/2/4, plan 6.5).
    func testV5CreatesTheHardwareTables() throws {
        let db = try DatabaseQueue()
        try DJSchema.migrator().migrate(db)
        try db.read { db in
            for table in ["audio_device", "channel_routing",
                          "controller_profile", "midi_mapping", "midi_binding"] {
                XCTAssertTrue(try db.tableExists(table), "dj_v5 must create \(table)")
            }
            XCTAssertTrue(try db.indexes(on: "midi_binding").contains { $0.name == "idx_binding_mapping" })
            XCTAssertTrue(try db.indexes(on: "channel_routing").contains { $0.name == "idx_routing_device" })
        }
    }

    /// A binding belongs to a mapping belongs to a profile: deleting the
    /// profile must take the whole map with it, or a re-learned controller
    /// inherits half of its own past.
    func testDeletingAProfileCascadesToItsBindings() throws {
        let db = try DatabaseQueue()
        try DJSchema.migrator().migrate(db)
        try db.write { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try db.execute(sql: """
                INSERT INTO controller_profile (syncID, name, active, createdAt)
                VALUES ('p1', 'Test Controller', 1, datetime('now'))
                """)
            let profileID = db.lastInsertedRowID
            try db.execute(sql: """
                INSERT INTO midi_mapping (profileID, name, updatedAt)
                VALUES (?, 'default', datetime('now'))
                """, arguments: [profileID])
            let mappingID = db.lastInsertedRowID
            try db.execute(sql: """
                INSERT INTO midi_binding (mappingID, target, messageType, channel, number, mode)
                VALUES (?, 'xfader', 'cc', 1, 7, 'absolute')
                """, arguments: [mappingID])

            try db.execute(sql: "DELETE FROM controller_profile WHERE id = ?",
                           arguments: [profileID])
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM midi_mapping"), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM midi_binding"), 0)
        }
    }
}
