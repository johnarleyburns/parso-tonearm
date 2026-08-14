import Foundation
import GRDB

extension DJMigrations {
    /// `dj_v4` — stems + recording (plan §4, decision 6). Append-only; no
    /// existing table changes, the M1–M5 convention. `stem_cache` carries the
    /// content-addressed, model-versioned stem set (§36.4, decision 5); the four
    /// recording tables are §15.5's DDL **verbatim** (the repo's `dj_v1` carries
    /// only `gig_crate`/`gig_crate_track`, so the session/mix tables land here).
    static func registerV4(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("dj_v4") { db in

            // ---- stem_cache (content-addressed, model-versioned; §36.4) ----
            // One row per (track, modelVersion). On disk the set lives under
            // `Caches/TonearmDJ/Stems/<contentHash>/<modelVersion>/<kind>.caf`
            // (backup-excluded, §13.1); the row records its presence, size and
            // the four relative `.caf` paths. A model upgrade writes a *new*
            // version row + directory and leaves the old one for eviction —
            // invalidation is clean, like `analysis_version` (§36.4).
            try db.create(table: "stem_cache") { t in
                t.column("trackID", .integer).notNull().references("track", onDelete: .cascade)
                t.column("contentHash", .text).notNull()      // SHA-256 of the source audio
                t.column("modelVersion", .integer).notNull()  // AnalysisVersions.stems
                t.column("sampleRate", .integer).notNull()    // 48000
                t.column("channelCount", .integer).notNull()  // 2 (stereo voices)
                t.column("totalBytes", .integer).notNull()
                t.column("pathsJSON", .text).notNull()        // {vocals|drums|bass|other: relPath}
                t.column("createdAt", .datetime).notNull()
                t.primaryKey(["trackID", "modelVersion"])
            }

            // ---- §15.5 verbatim: performance_session (a DJ set in progress or completed) ----
            try db.create(table: "performance_session") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("syncID", .text).notNull().unique()
                t.column("startedAt", .datetime).notNull()
                t.column("endedAt", .datetime)
                t.column("deckAStartTrackID", .integer).references("track", onDelete: .setNull)
                t.column("deckBStartTrackID", .integer).references("track", onDelete: .setNull)
            }

            // ---- §15.5 verbatim: mix (recorded output; FR-REC-1) ----
            try db.create(table: "mix") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("syncID", .text).notNull().unique()
                t.column("sessionID", .integer).references("performance_session", onDelete: .setNull)
                t.column("title", .text).notNull()
                t.column("notes", .text)
                t.column("durationSec", .double).notNull()
                t.column("trackCount", .integer).notNull()
                t.column("format", .text).notNull()          // "m4a-aac-256"
                t.column("bitrateKbps", .integer)
                t.column("sizeBytes", .integer)
                t.column("artworkID", .text)                 // locally generated
                t.column("recordedAt", .datetime).notNull()
                t.column("syncPolicy", .text).notNull().defaults(to: "localOnly") // localOnly|syncToPhone
                t.column("localState", .text).notNull().defaults(to: "complete")  // recording|complete|corrupt
            }
            try db.create(index: "idx_mix_recordedAt", on: "mix", columns: ["recordedAt"])

            // ---- §15.5 verbatim: mix_track_event (playlist history within a mix; FR-REC-2) ----
            try db.create(table: "mix_track_event") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("mixID", .integer).notNull().references("mix", onDelete: .cascade)
                t.column("trackID", .integer).references("track", onDelete: .setNull)
                t.column("title", .text).notNull()           // snapshot (survives track deletion)
                t.column("artist", .text)
                t.column("deck", .text).notNull()            // A|B
                t.column("startOffsetSec", .double).notNull() // position within the mix
                t.column("bpmAtPlay", .double)
                t.column("camelotAtPlay", .text)
                t.column("position", .integer).notNull()      // 1..n order
            }
            try db.create(index: "idx_mte_mix", on: "mix_track_event", columns: ["mixID", "position"])

            // ---- §15.5 verbatim: mix_asset (local file + CKAsset lifecycle; §38.6) ----
            try db.create(table: "mix_asset") { t in
                t.column("mixID", .integer).notNull().references("mix", onDelete: .cascade)
                t.column("localRelPath", .text).notNull()     // "Mixes/<uuid>.m4a"
                t.column("ckRecordName", .text)               // "DJMix-<syncID>"
                t.column("ckAssetUploaded", .boolean).notNull().defaults(to: false)
                t.column("uploadedBytes", .integer).notNull().defaults(to: 0)
                t.column("totalBytes", .integer)
                t.column("lastUploadAt", .datetime)
                t.primaryKey(["mixID"])
            }
        }
    }
}
