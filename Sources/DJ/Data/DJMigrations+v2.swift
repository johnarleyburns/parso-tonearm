import Foundation
import GRDB

extension DJMigrations {
    static func registerV2(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("dj_v2") { db in

            // ---- analysis_version (registry of algorithm sets; §15.1) ----
            try db.create(table: "analysis_version") { t in
                t.column("stage", .text).notNull()          // fft|beat|key|phrase|loudness|waveform|embedding
                t.column("version", .integer).notNull()
                t.column("descriptor", .text).notNull()     // human note, e.g. "HPCP+Krumhansl v3"
                t.column("introducedAt", .datetime).notNull()
                t.primaryKey(["stage", "version"])
            }

            // ---- analysis_run (per track, per stage: the resumable state machine; §15.1) ----
            try db.create(table: "analysis_run") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("trackID", .integer).notNull().references("track", onDelete: .cascade)
                t.column("stage", .text).notNull()
                t.column("version", .integer).notNull()
                t.column("state", .text).notNull()          // pending|running|done|failed|skipped
                t.column("attempts", .integer).notNull().defaults(to: 0)
                t.column("lastError", .text)
                t.column("startedAt", .datetime)
                t.column("finishedAt", .datetime)
                t.column("durationMS", .integer)
            }
            try db.create(index: "idx_run_track_stage", on: "analysis_run", columns: ["trackID", "stage"])
            try db.create(index: "idx_run_state", on: "analysis_run", columns: ["state"])

            // ---- loudness (LUFS + ReplayGain + DR; §15.2, FR-ANL-1) ----
            try db.create(table: "loudness") { t in
                t.column("trackID", .integer).notNull().references("track", onDelete: .cascade)
                t.column("integratedLUFS", .double)         // ITU-R BS.1770
                t.column("truePeakDBTP", .double)
                t.column("replayGainDB", .double)           // compatible with TonearmCore.ReplayGain
                t.column("dynamicRangeDB", .double)         // crest / EBU DR
                t.column("loudnessRangeLU", .double)        // LRA
                t.column("version", .integer).notNull()
                t.primaryKey(["trackID"])
            }

            // ---- frame_features (one BLOB per track: N frames x M features; §15.3) ----
            try db.create(table: "frame_features") { t in
                t.column("trackID", .integer).notNull().references("track", onDelete: .cascade)
                t.column("frameCount", .integer).notNull()
                t.column("hopSize", .integer).notNull()     // samples between frames
                t.column("fftSize", .integer).notNull()
                t.column("sampleRate", .integer).notNull()
                t.column("featureMask", .integer).notNull() // bitmask of which features present
                t.column("blob", .blob).notNull()           // FrameFeatures binary layout (App. C)
                t.column("version", .integer).notNull()
                t.primaryKey(["trackID"])
            }

            // ---- onset_envelope (one BLOB per track: Float32 novelty curve; §15.3) ----
            try db.create(table: "onset_envelope") { t in
                t.column("trackID", .integer).notNull().references("track", onDelete: .cascade)
                t.column("sampleRate", .double).notNull()   // envelope frame rate (Hz)
                t.column("count", .integer).notNull()
                t.column("blob", .blob).notNull()
                t.column("version", .integer).notNull()
                t.primaryKey(["trackID"])
            }

            // ---- tempo_candidate (top-K BPM hypotheses with confidence; §15.3, FR-ANL-4) ----
            try db.create(table: "tempo_candidate") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("trackID", .integer).notNull().references("track", onDelete: .cascade)
                t.column("bpm", .double).notNull()
                t.column("confidence", .double).notNull()
                t.column("rank", .integer).notNull()        // 0 = best
            }
            try db.create(index: "idx_tempo_track", on: "tempo_candidate", columns: ["trackID", "rank"])

            // ---- beat_grid (header; authoritative grid metadata; §15.3) ----
            try db.create(table: "beat_grid") { t in
                t.column("trackID", .integer).notNull().references("track", onDelete: .cascade)
                t.column("syncID", .text).notNull().unique()
                t.column("bpm", .double).notNull()          // grid tempo (may be corrected)
                t.column("firstBeatSample", .integer).notNull()
                t.column("beatCount", .integer).notNull()
                t.column("isConstantTempo", .boolean).notNull().defaults(to: true)
                t.column("source", .text).notNull()         // detected|corrected|imported
                t.column("confidence", .double)
                t.column("version", .integer).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.primaryKey(["trackID"])
            }

            // ---- beat_blob (per-beat sample positions + confidence; §15.3) ----
            try db.create(table: "beat_blob") { t in
                t.column("trackID", .integer).notNull().references("track", onDelete: .cascade)
                t.column("blob", .blob).notNull()           // Int64 sample positions + Float32 confidence
                t.primaryKey(["trackID"])
            }

            // ---- downbeat (bar starts; anchors phrase & "1"; §15.3) ----
            try db.create(table: "downbeat") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("trackID", .integer).notNull().references("track", onDelete: .cascade)
                t.column("beatIndex", .integer).notNull()   // index into beat grid
                t.column("samplePosition", .integer).notNull()
                t.column("barNumber", .integer).notNull()
                t.column("confidence", .double)
            }
            try db.create(index: "idx_downbeat_track", on: "downbeat", columns: ["trackID"])

            // ---- key_estimate (global + optional per-segment; §15.3) ----
            try db.create(table: "key_estimate") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("trackID", .integer).notNull().references("track", onDelete: .cascade)
                t.column("scope", .text).notNull().defaults(to: "global") // global|segment
                t.column("startSample", .integer)           // null for global
                t.column("endSample", .integer)
                t.column("camelot", .text).notNull()        // "8A"
                t.column("tonic", .integer).notNull()       // 0..11 (C=0)
                t.column("mode", .text).notNull()           // major|minor
                t.column("confidence", .double).notNull()
                t.column("version", .integer).notNull()
            }
            try db.create(index: "idx_key_track", on: "key_estimate", columns: ["trackID", "scope"])

            // ---- phrase (intro/verse/chorus/breakdown/drop/outro; §15.3) ----
            try db.create(table: "phrase") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("syncID", .text).notNull().unique()
                t.column("trackID", .integer).notNull().references("track", onDelete: .cascade)
                t.column("startSample", .integer).notNull()
                t.column("endSample", .integer).notNull()
                t.column("startBeat", .integer)
                t.column("lengthBeats", .integer)           // e.g., 32
                t.column("type", .text).notNull()           // intro|verse|build|chorus|breakdown|drop|outro
                t.column("energy", .double)                 // 0...10 within phrase
                t.column("confidence", .double)
                t.column("version", .integer).notNull()
            }
            try db.create(index: "idx_phrase_track", on: "phrase", columns: ["trackID", "startSample"])

            // ---- energy_curve (BLOB: Float32 per-beat or per-frame energy 0...1; §15.3) ----
            try db.create(table: "energy_curve") { t in
                t.column("trackID", .integer).notNull().references("track", onDelete: .cascade)
                t.column("resolution", .text).notNull()     // beat|frame
                t.column("count", .integer).notNull()
                t.column("blob", .blob).notNull()
                t.column("version", .integer).notNull()
                t.primaryKey(["trackID"])
            }

            // ---- waveform_pyramid (multi-resolution min/max/rms; §15.3, §26) ----
            try db.create(table: "waveform_pyramid") { t in
                t.column("trackID", .integer).notNull().references("track", onDelete: .cascade)
                t.column("levels", .integer).notNull()      // number of resolution levels
                t.column("baseSamplesPerBin", .integer).notNull()
                t.column("channelLayout", .text).notNull()  // mono|stereo-sum|stereo-split
                t.column("blob", .blob).notNull()           // packed per-level {min,max,rms}
                t.column("version", .integer).notNull()
                t.primaryKey(["trackID"])
            }
        }
    }
}
