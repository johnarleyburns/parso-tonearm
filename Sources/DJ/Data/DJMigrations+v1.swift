import Foundation
import GRDB

enum DJMigrations {
    static func registerV1(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("dj_v1") { db in

            // ---- artist ----
            try db.create(table: "artist") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("syncID", .text).notNull().unique()
                t.column("name", .text).notNull()
                t.column("sortName", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(indexOn: "artist", columns: ["sortName"])

            // ---- album ----
            try db.create(table: "album") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("syncID", .text).notNull().unique()
                t.column("title", .text).notNull()
                t.column("albumArtist", .text)
                t.column("year", .integer)
                t.column("artworkID", .text)
                t.column("createdAt", .datetime).notNull()
            }

            // ---- track (DJ-authoritative library row) ----
            try db.create(table: "track") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("syncID", .text).notNull().unique()
                t.column("albumID", .integer).references("album", onDelete: .setNull)
                t.column("title", .text).notNull()
                t.column("trackNo", .integer)
                t.column("discNo", .integer)
                t.column("durationSec", .double)
                t.column("codec", .text)
                t.column("sampleRate", .integer)
                t.column("channelCount", .integer)
                t.column("bitDepthOrBitrate", .text)
                t.column("contentHash", .text).notNull()
                t.column("sortKey", .text).notNull()
                t.column("bpm", .double)
                t.column("detectedBPM", .double)
                t.column("camelot", .text)
                t.column("musicalKey", .text)
                t.column("energy", .double)
                t.column("analysisVersion", .integer).notNull().defaults(to: 0)
                t.column("embeddingVersion", .integer).notNull().defaults(to: 0)
                t.column("analysisState", .text).notNull().defaults(to: "pending")
                t.column("stemState", .text).notNull().defaults(to: "none")
                t.column("addedAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(indexOn: "track", columns: ["sortKey"])
            try db.create(indexOn: "track", columns: ["bpm"])
            try db.create(indexOn: "track", columns: ["camelot"])
            try db.create(indexOn: "track", columns: ["analysisState"])

            // ---- track_artist (many-to-many, ordered, role) ----
            try db.create(table: "track_artist") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("trackID", .integer).notNull().references("track", onDelete: .cascade)
                t.column("artistID", .integer).notNull().references("artist", onDelete: .cascade)
                t.column("role", .text).notNull().defaults(to: "primary")
                t.column("position", .integer).notNull().defaults(to: 0)
            }
            try db.create(index: "idx_track_artist_track", on: "track_artist", columns: ["trackID"])

            // ---- genre + track_genre ----
            try db.create(table: "genre") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull().unique()
            }
            try db.create(table: "track_genre") { t in
                t.column("trackID", .integer).notNull().references("track", onDelete: .cascade)
                t.column("genreID", .integer).notNull().references("genre", onDelete: .cascade)
                t.primaryKey(["trackID", "genreID"])
            }

            // ---- folder (watched directories) ----
            try db.create(table: "folder") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("syncID", .text).notNull().unique()
                t.column("displayPath", .text).notNull()
                t.column("bookmark", .blob).notNull()
                t.column("watching", .boolean).notNull().defaults(to: true)
                t.column("addedAt", .datetime).notNull()
                t.column("lastScanAt", .datetime)
            }

            // ---- asset (file reference for a track; never a copy) ----
            try db.create(table: "asset") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("trackID", .integer).notNull().references("track", onDelete: .cascade)
                t.column("folderID", .integer).references("folder", onDelete: .setNull)
                t.column("bookmark", .blob)
                t.column("relPath", .text)
                t.column("sizeBytes", .integer)
                t.column("fileModifiedAt", .datetime)
                t.column("unsupportedReason", .text)
            }
            try db.create(index: "idx_asset_track", on: "asset", columns: ["trackID"])

            // ---- import_event (audit of ingestion) ----
            try db.create(table: "import_event") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("trackID", .integer).references("track", onDelete: .setNull)
                t.column("kind", .text).notNull()
                t.column("detail", .text)
                t.column("at", .datetime).notNull()
            }

            // ---- cue_point (hot cues + named markers) ----
            try db.create(table: "cue_point") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("syncID", .text).notNull().unique()
                t.column("trackID", .integer).notNull().references("track", onDelete: .cascade)
                t.column("samplePosition", .integer).notNull()
                t.column("kind", .text).notNull().defaults(to: "hot")
                t.column("label", .text)
                t.column("colorIndex", .integer).notNull().defaults(to: 0)
                t.column("hotIndex", .integer)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(index: "idx_cue_track", on: "cue_point", columns: ["trackID"])

            // ---- hot_cue_bank (per-track pad layout metadata) ----
            try db.create(table: "hot_cue_bank") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("trackID", .integer).notNull().references("track", onDelete: .cascade)
                t.column("bankIndex", .integer).notNull().defaults(to: 0)
                t.column("name", .text)
            }

            // ---- loop (in/out, beats; snaps to grid) ----
            try db.create(table: "loop") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("syncID", .text).notNull().unique()
                t.column("trackID", .integer).notNull().references("track", onDelete: .cascade)
                t.column("startSample", .integer).notNull()
                t.column("endSample", .integer).notNull()
                t.column("lengthBeats", .double)
                t.column("label", .text)
                t.column("isActive", .boolean).notNull().defaults(to: false)
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(index: "idx_loop_track", on: "loop", columns: ["trackID"])

            // ---- grid_correction (authoritative user override log) ----
            try db.create(table: "grid_correction") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("syncID", .text).notNull().unique()
                t.column("trackID", .integer).notNull().references("track", onDelete: .cascade)
                t.column("op", .text).notNull()
                t.column("valueDouble", .double)
                t.column("valueInt", .integer)
                t.column("appliedAt", .datetime).notNull()
            }

            // ---- playlist (static, ordered) ----
            try db.create(table: "playlist") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("syncID", .text).notNull().unique()
                t.column("title", .text).notNull()
                t.column("kind", .text).notNull().defaults(to: "manual")
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(table: "playlist_item") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("playlistID", .integer).notNull().references("playlist", onDelete: .cascade)
                t.column("trackID", .integer).notNull().references("track", onDelete: .cascade)
                t.column("position", .integer).notNull()
            }
            try db.create(index: "idx_pli_playlist", on: "playlist_item", columns: ["playlistID", "position"])

            // ---- smart_crate (a stored VibeQuery; resolves live) ----
            try db.create(table: "smart_crate") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("syncID", .text).notNull().unique()
                t.column("name", .text).notNull()
                t.column("queryJSON", .text).notNull()
                t.column("pinned", .boolean).notNull().defaults(to: false)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(table: "crate_rule") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("crateID", .integer).notNull().references("smart_crate", onDelete: .cascade)
                t.column("field", .text).notNull()
                t.column("op", .text).notNull()
                t.column("valueJSON", .text).notNull()
            }

            // ---- auto_playlist_brief (FREE; the user's intent) ----
            try db.create(table: "auto_playlist_brief") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("syncID", .text).notNull().unique()
                t.column("prompt", .text).notNull()
                t.column("arcKind", .text).notNull()
                t.column("arcPointsJSON", .text)
                t.column("targetSeconds", .integer)
                t.column("targetTrackCount", .integer)
                t.column("constraintsJSON", .text).notNull()
                t.column("seedTrackID", .integer).references("track", onDelete: .setNull)
                t.column("seedCrateID", .integer).references("smart_crate", onDelete: .setNull)
                t.column("randomSeed", .integer).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(table: "auto_playlist_result") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("briefID", .integer).notNull().references("auto_playlist_brief", onDelete: .cascade)
                t.column("playlistID", .integer).references("playlist", onDelete: .cascade)
                t.column("smartCrateID", .integer).references("smart_crate", onDelete: .cascade)
                t.column("generatedAt", .datetime).notNull()
                t.column("totalSeconds", .integer).notNull()
                t.column("arcError", .double).notNull()
                t.column("meanTransitionCost", .double).notNull()
                t.column("analysisVersion", .integer).notNull()
            }
            try db.create(table: "auto_playlist_item") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("resultID", .integer).notNull().references("auto_playlist_result", onDelete: .cascade)
                t.column("trackID", .integer).notNull().references("track", onDelete: .cascade)
                t.column("position", .integer).notNull()
                t.column("locked", .boolean).notNull().defaults(to: false)
                t.column("targetEnergy", .double).notNull()
                t.column("actualEnergy", .double).notNull()
                t.column("transitionCostIn", .double)
                t.column("semanticScore", .double).notNull()
            }
            try db.create(index: "idx_apl_item_result", on: "auto_playlist_item",
                          columns: ["resultID", "position"])
            try db.create(table: "auto_playlist_rejection") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("briefID", .integer).notNull().references("auto_playlist_brief", onDelete: .cascade)
                t.column("trackID", .integer).notNull().references("track", onDelete: .cascade)
                t.column("rejectedAt", .datetime).notNull()
            }
            try db.create(index: "idx_apl_reject", on: "auto_playlist_rejection", columns: ["briefID", "trackID"])

            // ---- gig_crate (PRO; promoted to performance readiness) ----
            try db.create(table: "gig_crate") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("syncID", .text).notNull().unique()
                t.column("name", .text).notNull()
                t.column("playlistID", .integer).references("playlist", onDelete: .setNull)
                t.column("smartCrateID", .integer).references("smart_crate", onDelete: .setNull)
                t.column("storageBudgetBytes", .integer).notNull()
                t.column("lastPerformedAt", .datetime)
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "gig_crate_track") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("gigCrateID", .integer).notNull().references("gig_crate", onDelete: .cascade)
                t.column("trackID", .integer).notNull().references("track", onDelete: .cascade)
                t.column("position", .integer).notNull()
                t.column("audioCached", .boolean).notNull().defaults(to: false)
                t.column("stemsState", .text).notNull().defaults(to: "pending")
                t.column("stemsBytes", .integer).notNull().defaults(to: 0)
            }
            try db.create(index: "idx_gct_crate", on: "gig_crate_track", columns: ["gigCrateID", "position"])

            // ---- rating ----
            try db.create(table: "rating") { t in
                t.column("trackID", .integer).notNull().references("track", onDelete: .cascade)
                t.column("syncID", .text).notNull().unique()
                t.column("stars", .integer).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.primaryKey(["trackID"])
            }

            // ---- tag + track_tag ----
            try db.create(table: "tag") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("syncID", .text).notNull().unique()
                t.column("name", .text).notNull().unique()
                t.column("colorIndex", .integer).notNull().defaults(to: 0)
            }
            try db.create(table: "track_tag") { t in
                t.column("trackID", .integer).notNull().references("track", onDelete: .cascade)
                t.column("tagID", .integer).notNull().references("tag", onDelete: .cascade)
                t.primaryKey(["trackID", "tagID"])
            }

            // ---- app_setting (typed key/value) ----
            try db.create(table: "app_setting") { t in
                t.column("key", .text).notNull()
                t.column("valueJSON", .text).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.primaryKey(["key"])
            }
        }
    }
}
