import XCTest
import GRDB

@testable import TonearmDJ

final class DJSchemaTests: XCTestCase {
    func testMigrationOrderIsAppendOnly() {
        XCTAssertEqual(DJSchema.migrationOrder,
                       ["dj_v1", "dj_v2", "dj_v3", "dj_v4", "dj_v5", "dj_v6", "dj_v7", "dj_v8", "dj_v9", "dj_v10", "dj_v11", "dj_v12"])
        XCTAssertEqual(DJSchema.migrator().migrations,
                       ["dj_v1", "dj_v2", "dj_v3", "dj_v4", "dj_v5", "dj_v6", "dj_v7", "dj_v8", "dj_v9", "dj_v10", "dj_v11", "dj_v12"])
    }

    /// `dj_v8` (IMPLEMENT_CLAP_PLAN.md C02): `playlist_item.trackID` no longer
    /// has a foreign key into this database's own `track` table, because
    /// `PlaylistCrateImporter` now stores the *core* `LibraryStore` track id
    /// there directly — an id that lives in a different database file and
    /// never satisfies a DJ-local FK.
    func testV8DropsPlaylistItemTrackForeignKey() throws {
        let db = try DatabaseQueue()
        try DJSchema.migrator().migrate(db)
        try db.read { db in
            let foreignKeys = try db.foreignKeys(on: "playlist_item")
            XCTAssertFalse(foreignKeys.contains { $0.destinationTable == "track" },
                           "playlist_item.trackID must not FK into the DJ-local track table")
            XCTAssertTrue(foreignKeys.contains { $0.destinationTable == "playlist" },
                          "playlist_item.playlistID must still cascade with its playlist")
            let columns = try db.columns(in: "playlist_item").map(\.name)
            XCTAssertEqual(Set(columns), ["id", "playlistID", "trackID", "position"])
        }
    }

    /// `dj_v9` (IMPLEMENT_CLAP_PLAN.md C02, session 14): `gig_crate_track.
    /// trackID` no longer has a foreign key into this database's own `track`
    /// table, because `GigCrateRepository.promote` copies the (now core)
    /// `playlist_item.trackID` straight through — an id that lives in a
    /// different database file and never satisfies a DJ-local FK.
    func testV9DropsGigCrateTrackTrackForeignKey() throws {
        let db = try DatabaseQueue()
        try DJSchema.migrator().migrate(db)
        try db.read { db in
            let foreignKeys = try db.foreignKeys(on: "gig_crate_track")
            XCTAssertFalse(foreignKeys.contains { $0.destinationTable == "track" },
                           "gig_crate_track.trackID must not FK into the DJ-local track table")
            XCTAssertTrue(foreignKeys.contains { $0.destinationTable == "gig_crate" },
                          "gig_crate_track.gigCrateID must still cascade with its gig_crate")
            let columns = try db.columns(in: "gig_crate_track").map(\.name)
            XCTAssertEqual(Set(columns), ["id", "gigCrateID", "trackID", "position",
                                          "audioCached", "stemsState", "stemsBytes"])
        }
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

    /// C02 (`dj_v12`): the DJ-local catalog tables (`artist`/`album`/`track`/
    /// `track_artist`/`genre`/`track_genre`/`folder`/`asset`/`import_event`)
    /// are dropped outright — every remaining table here stores only
    /// DJ-local *supplementary* data keyed by a **core** `LibraryStore`
    /// track id, never a second copy of track/artist/album identity.
    func testApplyingAllMigrationsCreatesRelationalCoreTables() throws {
        let db = try DatabaseQueue()
        try DJSchema.migrator().migrate(db)

        let expectedTables = [
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

        let deletedCatalogTables = [
            "artist", "album", "track", "track_artist", "genre", "track_genre",
            "folder", "asset", "import_event",
        ]
        try db.read { db in
            for table in deletedCatalogTables {
                XCTAssertFalse(try db.tableExists(table),
                               "\(table) is the deleted duplicate catalog — must not exist")
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

    /// C02 (`dj_v12`): `track_embedding`/`window_embedding` backed the
    /// semantic-search subsystem (`VectorStore`/`SemanticSearchService`/
    /// `EmbeddingCoordinator`), already deleted from `Sources`, and were an
    /// FK-to-the-deleted-catalog table besides — `dj_v12` drops both
    /// outright rather than just stripping their FK. `embedding_version`/
    /// `vector_matrix_meta` never referenced `track` and are untouched.
    func testV3CreatesEmbeddingTables() throws {
        let db = try DatabaseQueue()
        try DJSchema.migrator().migrate(db)

        let survivingTables = ["embedding_version", "vector_matrix_meta"]
        try db.read { db in
            for table in survivingTables {
                XCTAssertTrue(try db.tableExists(table), "missing table \(table)")
            }
            for table in ["track_embedding", "window_embedding"] {
                XCTAssertFalse(try db.tableExists(table),
                               "\(table) backed the deleted semantic-search subsystem — must not exist")
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

    // `testTrackDefaultsMatchDDL` (DJ-local `track` table default-column
    // DDL) was deleted by C02/`dj_v12`: the DJ-local catalog `track` table
    // it tested no longer exists — that is a duplicate-catalog table this
    // migration correctly retired, not a fixture-mechanics issue to patch.

    /// `dj_v10` (IMPLEMENT_CLAP_PLAN.md C02): `auto_playlist_item.trackID`,
    /// `auto_playlist_rejection.trackID` and `auto_playlist_brief.
    /// seedTrackID` no longer have a foreign key into this database's own
    /// `track` table, because `PlaylistGenerator`'s candidates now come from
    /// `SearchService` keyed by the *core* `LibraryStore` track id — an id
    /// that lives in a different database file and never satisfies a
    /// DJ-local FK.
    func testV10DropsAutoPlaylistTrackForeignKeys() throws {
        let db = try DatabaseQueue()
        try DJSchema.migrator().migrate(db)
        try db.read { db in
            let briefFKs = try db.foreignKeys(on: "auto_playlist_brief")
            XCTAssertFalse(briefFKs.contains { $0.destinationTable == "track" },
                           "auto_playlist_brief.seedTrackID must not FK into the DJ-local track table")
            XCTAssertTrue(briefFKs.contains { $0.destinationTable == "smart_crate" },
                          "auto_playlist_brief.seedCrateID must still set-null with its crate")

            let itemFKs = try db.foreignKeys(on: "auto_playlist_item")
            XCTAssertFalse(itemFKs.contains { $0.destinationTable == "track" },
                           "auto_playlist_item.trackID must not FK into the DJ-local track table")
            XCTAssertTrue(itemFKs.contains { $0.destinationTable == "auto_playlist_result" },
                          "auto_playlist_item.resultID must still cascade with its result")

            let rejectionFKs = try db.foreignKeys(on: "auto_playlist_rejection")
            XCTAssertFalse(rejectionFKs.contains { $0.destinationTable == "track" },
                           "auto_playlist_rejection.trackID must not FK into the DJ-local track table")
            XCTAssertTrue(rejectionFKs.contains { $0.destinationTable == "auto_playlist_brief" },
                          "auto_playlist_rejection.briefID must still cascade with its brief")
        }
    }

    /// `dj_v11` (IMPLEMENT_CLAP_PLAN.md C02): `mix_track_event.trackID` no
    /// longer has a foreign key into this database's own `track` table,
    /// because `RecordingService` resolves the §37.4 timeline snapshot from
    /// the *core* `LibraryStore` (`MixTimeline.entries.trackID` is a core id
    /// everywhere deck-load happens) — an id that lives in a different
    /// database file and never satisfies a DJ-local FK. Before this
    /// migration, `foreignKeysEnabled = true` meant every `finalizeRecordingMix`
    /// with a non-empty timeline threw on the INSERT and the mix was marked
    /// corrupt — not merely a display bug.
    func testV11DropsMixTrackEventTrackForeignKey() throws {
        let db = try DatabaseQueue()
        try DJSchema.migrator().migrate(db)
        try db.read { db in
            let foreignKeys = try db.foreignKeys(on: "mix_track_event")
            XCTAssertFalse(foreignKeys.contains { $0.destinationTable == "track" },
                           "mix_track_event.trackID must not FK into the DJ-local track table")
            XCTAssertTrue(foreignKeys.contains { $0.destinationTable == "mix" },
                          "mix_track_event.mixID must still cascade with its mix")
            let columns = try db.columns(in: "mix_track_event").map(\.name)
            XCTAssertEqual(Set(columns), ["id", "mixID", "trackID", "title", "artist", "deck",
                                          "startOffsetSec", "bpmAtPlay", "camelotAtPlay", "position"])
        }
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
