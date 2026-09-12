import Foundation
import GRDB

extension DJMigrations {
    /// `dj_v12` — C02 (IMPLEMENT_CLAP_PLAN.md), the actual catalog deletion.
    ///
    /// Sessions 12-17 already moved every *membership* row (crate/playlist/
    /// auto-playlist/mix-timeline `trackID` columns) onto core `LibraryStore`
    /// ids and dropped their FK to this database's own `track` table
    /// (dj_v8-v11). Session 18's audit found the one piece those sessions
    /// left standing: `DJLibraryStore.importFolder` (plus the dead
    /// `importDownloadedTracks`) still wrote a full **second catalog** —
    /// `artist`/`album`/`track`/`asset`/`folder`/`import_event`/
    /// `track_artist`/`genre`/`track_genre` — duplicating exactly what core
    /// `LibraryStore` (Sources/Data/LibraryStore.swift) already owns. The
    /// orchestrating session verified `importFolder` has **zero production
    /// callers** (`LibraryModel.importFolder` was rewired onto core
    /// `IngestService.addFolder` in session 14) — so this migration finally
    /// drops that duplicate catalog outright.
    ///
    /// `track_embedding`/`window_embedding` (dj_v3) go with it: they backed
    /// the semantic-search subsystem (`VectorStore`/`SemanticSearchService`/
    /// `EmbeddingCoordinator`) that was already deleted from `Sources` before
    /// this session started (confirmed by `git status`/`rg`), so they are
    /// dead schema referencing a table this migration removes anyway.
    /// `embedding_version`/`vector_matrix_meta` do NOT reference `track` and
    /// are left alone — touching them is not this migration's job.
    ///
    /// Every remaining table that legitimately stores DJ-local
    /// *supplementary* data keyed by a **core** track id — not a second copy
    /// of track/artist/album identity — is kept, but its FK to the
    /// now-deleted `track` table must go, exactly like dj_v8-v11 dropped the
    /// same FK from `playlist_item`/`gig_crate_track`/`auto_playlist_*`/
    /// `mix_track_event`: grid corrections (`grid_correction`), analysis
    /// artifacts (`analysis_run`/`loudness`/`frame_features`/
    /// `onset_envelope`/`tempo_candidate`/`beat_grid`/`beat_blob`/
    /// `downbeat`/`key_estimate`/`phrase`/`energy_curve`/
    /// `waveform_pyramid`), the stem cache (`stem_cache`), the deck-render
    /// seam's `cue_point`/`loop` (read by `WaveformRepository`), and the
    /// still-unwired-but-kept `hot_cue_bank`/`rating`/`track_tag`/
    /// `performance_session`. None of these tables store track/artist/
    /// album/asset identity themselves — they only reference a track id — so
    /// keeping them is not "a second catalog," matching the reasoning that
    /// already justified keeping MIDI profiles DJ-local (session 18).
    ///
    /// Every recreated table is emptied, same as dj_v8-v11: there is no
    /// mapping from an old DJ-local `track.id` to a core id to translate
    /// existing rows through (this pre-1.0 app has no released user data to
    /// preserve across that gap), and in DEBUG
    /// `eraseDatabaseOnSchemaChange` already wipes on every schema change.
    static func registerV12(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("dj_v12") { db in

            // MARK: - Drop the duplicate catalog outright

            try db.drop(table: "track_artist")
            try db.drop(table: "track_genre")
            try db.drop(table: "genre")
            try db.drop(table: "asset")
            try db.drop(table: "import_event")
            try db.drop(table: "track_embedding")
            try db.drop(table: "window_embedding")
            try db.drop(table: "track")
            try db.drop(table: "album")
            try db.drop(table: "artist")
            try db.drop(table: "folder")

            // MARK: - Recreate supplementary tables without the FK to `track`

            try db.drop(table: "cue_point")
            try db.create(table: "cue_point") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("syncID", .text).notNull().unique()
                // No FK: trackID is a core LibraryStore track id (C02).
                t.column("trackID", .integer).notNull()
                t.column("samplePosition", .integer).notNull()
                t.column("kind", .text).notNull().defaults(to: "hot")
                t.column("label", .text)
                t.column("colorIndex", .integer).notNull().defaults(to: 0)
                t.column("hotIndex", .integer)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(index: "idx_cue_track", on: "cue_point", columns: ["trackID"])

            try db.drop(table: "hot_cue_bank")
            try db.create(table: "hot_cue_bank") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("trackID", .integer).notNull()
                t.column("bankIndex", .integer).notNull().defaults(to: 0)
                t.column("name", .text)
            }

            try db.drop(table: "loop")
            try db.create(table: "loop") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("syncID", .text).notNull().unique()
                t.column("trackID", .integer).notNull()
                t.column("startSample", .integer).notNull()
                t.column("endSample", .integer).notNull()
                t.column("lengthBeats", .double)
                t.column("label", .text)
                t.column("isActive", .boolean).notNull().defaults(to: false)
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(index: "idx_loop_track", on: "loop", columns: ["trackID"])

            try db.drop(table: "grid_correction")
            try db.create(table: "grid_correction") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("syncID", .text).notNull().unique()
                t.column("trackID", .integer).notNull()
                t.column("op", .text).notNull()
                t.column("valueDouble", .double)
                t.column("valueInt", .integer)
                t.column("appliedAt", .datetime).notNull()
            }

            try db.drop(table: "rating")
            try db.create(table: "rating") { t in
                t.column("trackID", .integer).notNull()
                t.column("syncID", .text).notNull().unique()
                t.column("stars", .integer).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.primaryKey(["trackID"])
            }

            try db.drop(table: "track_tag")
            try db.create(table: "track_tag") { t in
                t.column("trackID", .integer).notNull()
                t.column("tagID", .integer).notNull().references("tag", onDelete: .cascade)
                t.primaryKey(["trackID", "tagID"])
            }

            try db.drop(table: "analysis_run")
            try db.create(table: "analysis_run") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("trackID", .integer).notNull()
                t.column("stage", .text).notNull()
                t.column("version", .integer).notNull()
                t.column("state", .text).notNull()
                t.column("attempts", .integer).notNull().defaults(to: 0)
                t.column("lastError", .text)
                t.column("startedAt", .datetime)
                t.column("finishedAt", .datetime)
                t.column("durationMS", .integer)
            }
            try db.create(index: "idx_run_track_stage", on: "analysis_run", columns: ["trackID", "stage"])
            try db.create(index: "idx_run_state", on: "analysis_run", columns: ["state"])

            try db.drop(table: "loudness")
            try db.create(table: "loudness") { t in
                t.column("trackID", .integer).notNull()
                t.column("integratedLUFS", .double)
                t.column("truePeakDBTP", .double)
                t.column("replayGainDB", .double)
                t.column("dynamicRangeDB", .double)
                t.column("loudnessRangeLU", .double)
                t.column("version", .integer).notNull()
                t.primaryKey(["trackID"])
            }

            try db.drop(table: "frame_features")
            try db.create(table: "frame_features") { t in
                t.column("trackID", .integer).notNull()
                t.column("frameCount", .integer).notNull()
                t.column("hopSize", .integer).notNull()
                t.column("fftSize", .integer).notNull()
                t.column("sampleRate", .integer).notNull()
                t.column("featureMask", .integer).notNull()
                t.column("blob", .blob).notNull()
                t.column("version", .integer).notNull()
                t.primaryKey(["trackID"])
            }

            try db.drop(table: "onset_envelope")
            try db.create(table: "onset_envelope") { t in
                t.column("trackID", .integer).notNull()
                t.column("sampleRate", .double).notNull()
                t.column("count", .integer).notNull()
                t.column("blob", .blob).notNull()
                t.column("version", .integer).notNull()
                t.primaryKey(["trackID"])
            }

            try db.drop(table: "tempo_candidate")
            try db.create(table: "tempo_candidate") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("trackID", .integer).notNull()
                t.column("bpm", .double).notNull()
                t.column("confidence", .double).notNull()
                t.column("rank", .integer).notNull()
            }
            try db.create(index: "idx_tempo_track", on: "tempo_candidate", columns: ["trackID", "rank"])

            try db.drop(table: "beat_grid")
            try db.create(table: "beat_grid") { t in
                t.column("trackID", .integer).notNull()
                t.column("syncID", .text).notNull().unique()
                t.column("bpm", .double).notNull()
                t.column("firstBeatSample", .integer).notNull()
                t.column("beatCount", .integer).notNull()
                t.column("isConstantTempo", .boolean).notNull().defaults(to: true)
                t.column("source", .text).notNull()
                t.column("confidence", .double)
                t.column("version", .integer).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.primaryKey(["trackID"])
            }

            try db.drop(table: "beat_blob")
            try db.create(table: "beat_blob") { t in
                t.column("trackID", .integer).notNull()
                t.column("blob", .blob).notNull()
                t.primaryKey(["trackID"])
            }

            try db.drop(table: "downbeat")
            try db.create(table: "downbeat") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("trackID", .integer).notNull()
                t.column("beatIndex", .integer).notNull()
                t.column("samplePosition", .integer).notNull()
                t.column("barNumber", .integer).notNull()
                t.column("confidence", .double)
            }
            try db.create(index: "idx_downbeat_track", on: "downbeat", columns: ["trackID"])

            try db.drop(table: "key_estimate")
            try db.create(table: "key_estimate") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("trackID", .integer).notNull()
                t.column("scope", .text).notNull().defaults(to: "global")
                t.column("startSample", .integer)
                t.column("endSample", .integer)
                t.column("camelot", .text).notNull()
                t.column("tonic", .integer).notNull()
                t.column("mode", .text).notNull()
                t.column("confidence", .double).notNull()
                t.column("version", .integer).notNull()
            }
            try db.create(index: "idx_key_track", on: "key_estimate", columns: ["trackID", "scope"])

            try db.drop(table: "phrase")
            try db.create(table: "phrase") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("syncID", .text).notNull().unique()
                t.column("trackID", .integer).notNull()
                t.column("startSample", .integer).notNull()
                t.column("endSample", .integer).notNull()
                t.column("startBeat", .integer)
                t.column("lengthBeats", .integer)
                t.column("type", .text).notNull()
                t.column("energy", .double)
                t.column("confidence", .double)
                t.column("version", .integer).notNull()
            }
            try db.create(index: "idx_phrase_track", on: "phrase", columns: ["trackID", "startSample"])

            try db.drop(table: "energy_curve")
            try db.create(table: "energy_curve") { t in
                t.column("trackID", .integer).notNull()
                t.column("resolution", .text).notNull()
                t.column("count", .integer).notNull()
                t.column("blob", .blob).notNull()
                t.column("version", .integer).notNull()
                t.primaryKey(["trackID"])
            }

            try db.drop(table: "waveform_pyramid")
            try db.create(table: "waveform_pyramid") { t in
                t.column("trackID", .integer).notNull()
                t.column("levels", .integer).notNull()
                t.column("baseSamplesPerBin", .integer).notNull()
                t.column("channelLayout", .text).notNull()
                t.column("blob", .blob).notNull()
                t.column("version", .integer).notNull()
                t.primaryKey(["trackID"])
            }

            try db.drop(table: "stem_cache")
            try db.create(table: "stem_cache") { t in
                t.column("trackID", .integer).notNull()
                t.column("contentHash", .text).notNull()
                t.column("modelVersion", .integer).notNull()
                t.column("sampleRate", .integer).notNull()
                t.column("channelCount", .integer).notNull()
                t.column("totalBytes", .integer).notNull()
                t.column("pathsJSON", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.primaryKey(["trackID", "modelVersion"])
            }

            try db.drop(table: "performance_session")
            try db.create(table: "performance_session") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("syncID", .text).notNull().unique()
                t.column("startedAt", .datetime).notNull()
                t.column("endedAt", .datetime)
                // No FK: both are core LibraryStore track ids (never actually
                // written today — `performance_session` has zero readers or
                // writers anywhere in `Sources`, confirmed by `rg`).
                t.column("deckAStartTrackID", .integer)
                t.column("deckBStartTrackID", .integer)
            }
        }
    }
}
