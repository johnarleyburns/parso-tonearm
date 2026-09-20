import Foundation
import GRDB

// MARK: - Migrations v15-v21

extension Schema {
    static func registerV15toV21(_ migrator: inout DatabaseMigrator, upTo target: String?) {
        if shouldRegister("v15", upTo: target) {
            migrator.registerMigration("v15") { db in
                // Watch rearchitecture §8.1: the phone owns *desired download roots* and the
                // jobs that satisfy them. The v12 `watchTransfer` table cannot represent roots,
                // reference counts, retry attempts, or the watch's reported manifest, so this is
                // a fresh set of tables. The old tables stay until the Phase 6 cutover.
                try db.create(table: "watchDownloadRoot") { t in
                    t.column("rootID", .text).primaryKey()
                    t.column("kind", .text).notNull()
                    t.column("sourceID", .text).notNull()
                    t.column("title", .text).notNull().defaults(to: "")
                    t.column("desiredTrackIDs", .text).notNull()   // JSON array of watch track IDs
                    t.column("phoneRevision", .integer).notNull()
                    t.column("createdAt", .datetime).notNull()
                }
                try db.create(table: "watchDownloadJob") { t in
                    t.column("requestID", .text).primaryKey()
                    t.column("trackID", .text).notNull()
                    t.column("rootIDs", .text).notNull()           // JSON array
                    t.column("priority", .integer).notNull().defaults(to: 2)
                    t.column("state", .text).notNull()
                    t.column("failureClass", .text)
                    t.column("attempt", .integer).notNull().defaults(to: 0)
                    t.column("nextAttemptAt", .datetime)
                    t.column("expectedBytes", .integer)
                    t.column("expectedSHA256", .text)
                    t.column("errorCode", .text)
                    t.column("message", .text)
                    t.column("createdAt", .datetime).notNull()
                    t.column("updatedAt", .datetime).notNull()
                }
                try db.create(indexOn: "watchDownloadJob", columns: ["trackID"])
                try db.create(indexOn: "watchDownloadJob", columns: ["state"])
                // The watch's last reported installed truth (§1.6, second authority).
                try db.create(table: "watchDownloadManifestEntry") { t in
                    t.column("trackID", .text).primaryKey()
                    t.column("bytes", .integer).notNull()
                    t.column("manifestID", .text).notNull()
                    t.column("reportedAt", .datetime).notNull()
                }
                // Single-row monotonic revision for setDownloadRoots / removeAssets.
                try db.create(table: "watchDownloadRevision") { t in
                    t.column("id", .integer).primaryKey()
                    t.column("value", .integer).notNull()
                }
                try db.execute(sql: "INSERT INTO watchDownloadRevision (id, value) VALUES (1, 0)")
            }
        }

        if shouldRegister("v16", upTo: target) {
            migrator.registerMigration("v16") { db in
                // Watch rearchitecture Phase 8 (P3/P4): a desired-download root can be paused from
                // the iPhone. Pause is durable — a relaunch must not silently resume transfers the
                // owner stopped. Existing rows default to not paused, which is what they did before.
                try db.alter(table: "watchDownloadRoot") { t in
                    t.add(column: "paused", .boolean).notNull().defaults(to: false)
                }
            }
        }

        if shouldRegister("v17", upTo: target) {
            migrator.registerMigration("v17") { db in
                // Watch rearchitecture Phase 10 (§12): the pre-cutover watch transfer pipeline
                // is deleted. `watchTransfer` / `watchManifest` (v12) were superseded by the
                // v15 `watchDownloadRoot` / `watchDownloadJob` / `watchDownloadManifestEntry`
                // tables at the Phase 6 cutover and have had no reader or writer since. Drop
                // them so no legacy schema remains.
                try db.execute(sql: "DROP TABLE IF EXISTS watchTransfer")
                try db.execute(sql: "DROP TABLE IF EXISTS watchManifest")
            }
        }

        if shouldRegister("v18", upTo: target) {
            migrator.registerMigration("v18") { db in
                try DiscoveryMigrations.v18(db)
            }
        }

        if shouldRegister("v19", upTo: target) {
            migrator.registerMigration("v19") { db in
                try DiscoveryMigrations.v19(db)
            }
        }

        if shouldRegister("v20", upTo: target) {
            migrator.registerMigration("v20") { db in
                try DiscoveryMigrations.v20(db)
            }
        }

        if shouldRegister("v21", upTo: target) {
            migrator.registerMigration("v21") { db in
                // Album- and source-level custom artwork (mirrors the v5 track-level
                // `custom_artwork` table). Lets a user set one image for a whole
                // album or source, not just individual tracks. `syncID` is carried
                // for CloudKit parity but is not yet wired into the sync engine,
                // matching `custom_artwork`'s own current (unwired) syncID column.
                try db.create(table: "custom_artwork_album") { t in
                    t.column("albumId", .integer).notNull().unique()
                        .references("album", onDelete: .cascade)
                    t.column("artworkId", .text).notNull()
                    t.column("syncID", .text)
                }
                try db.create(indexOn: "custom_artwork_album", columns: ["syncID"], options: .unique)

                try db.create(table: "custom_artwork_source") { t in
                    t.column("sourceId", .integer).notNull().unique()
                        .references("source", onDelete: .cascade)
                    t.column("artworkId", .text).notNull()
                    t.column("syncID", .text)
                }
                try db.create(indexOn: "custom_artwork_source", columns: ["syncID"], options: .unique)
            }
        }

        if shouldRegister("v22", upTo: target) {
            migrator.registerMigration("v22") { db in
                // Real, persisted re-resolution reference for a `.remote` asset —
                // previously only the once-resolved `remoteURL` (and possibly
                // stale/expired) survived a save; the provider-native node
                // id/path a `RemoteLibraryProvider.resolve(node:)` call needs was
                // discarded entirely (docs/plans/remote-sparse-indexing.md,
                // "Prerequisite"/Phase 0 investigation). Without this, "Make
                // Offline"/"Download" silently used dead credentials/links for
                // every provider except Subsonic once reached outside a live
                // browse session — a real, separate bug this column fixes
                // alongside the field's other future use (sparse remote
                // indexing).
                try db.alter(table: "asset") { t in
                    t.add(column: "remoteNodeID", .text)
                    t.add(column: "remoteNodePath", .text)
                }
            }
        }

        if shouldRegister("v23", upTo: target) {
            migrator.registerMigration("v23") { db in
                // Transition Lab persistence
                // (docs/plans/UNIFIED_TONEARM_MY_MUSIC_TRANSITION_LAB_HANDOFF.md
                // §15) — deliberately separate from `discovery_track_analysis`
                // (bounded, up-to-60s-midpoint Discovery analysis) since this is
                // a full-song `PortableAnalysisV1` payload from
                // `ParsoAudioAnalysis.FullAnalysis`, a different schema/
                // algorithm entirely.
                try db.create(table: "transition_full_analysis") { t in
                    t.autoIncrementedPrimaryKey("id")
                    t.column("trackId", .integer).notNull()
                        .references("track", onDelete: .cascade)
                    t.column("assetId", .integer).notNull()
                        .references("asset", onDelete: .cascade)
                    t.column("assetRevision", .integer).notNull()
                    t.column("schemaVersion", .integer).notNull()
                    t.column("algorithmID", .text).notNull()
                    // The Codable `PortableAnalysisV1` JSON payload, as-is —
                    // its own `init(from:)` already rejects a schema/
                    // algorithm-ID mismatch or an out-of-range value, so a
                    // decode failure on read is the "stale, re-analyze"
                    // signal for free (no separate validity column needed).
                    t.column("payload", .blob).notNull()
                    t.column("completedAt", .datetime).notNull()
                }
                try db.create(
                    indexOn: "transition_full_analysis", columns: ["trackId"], options: .unique)

                // One row per prepared (or attempted) transition between two
                // adjacent tracks in a specific playlist — "status" lets Set
                // Practice show prepared/needs-work per edge without
                // re-running TransitionPlanner every time the screen opens.
                try db.create(table: "transition_playlist_edge") { t in
                    t.autoIncrementedPrimaryKey("id")
                    t.column("playlistId", .integer).notNull()
                        .references("playlist", onDelete: .cascade)
                    t.column("outgoingTrackId", .integer).notNull()
                        .references("track", onDelete: .cascade)
                    t.column("incomingTrackId", .integer).notNull()
                        .references("track", onDelete: .cascade)
                    t.column("outgoingRevision", .integer).notNull()
                    t.column("incomingRevision", .integer).notNull()
                    // The Codable `AudioTransitionProposal` the user picked/
                    // last previewed for this edge — nil-able because an
                    // edge can exist in "needsWork" status with no proposal
                    // yet chosen (e.g. TransitionPlanner returned no
                    // candidates for this pair).
                    t.column("proposalPayload", .blob)
                    t.column("status", .text).notNull()
                    t.column("updatedAt", .datetime).notNull()
                }
                try db.create(
                    indexOn: "transition_playlist_edge",
                    columns: ["playlistId", "outgoingTrackId", "incomingTrackId"], options: .unique)
            }
        }

        if shouldRegister("v24", upTo: target) {
            migrator.registerMigration("v24") { db in
                // Real report: "none of the Jamendo artwork is loading" — a
                // genuinely-imported `.remote` asset (Jamendo, or any future
                // provider) had nowhere to remember its real, public,
                // non-authenticated cover URL (Jamendo's `album_image`), so
                // it always fell through to embedded-tag/iTunes-search
                // fallbacks that usually miss for obscure CC tracks.
                // Deliberately separate from `remoteNodeID`/`remoteNodePath`
                // (v22, re-resolves an authenticated node) and from
                // `Asset.transientArtwork` (never persisted, because MOST
                // provider artwork needs auth headers/expiring URLs) — this
                // column is only ever populated with a URL already known to
                // be stable and public.
                try db.alter(table: "asset") { t in
                    t.add(column: "persistedArtworkURL", .text)
                }
            }
        }

        if shouldRegister("v25", upTo: target) {
            migrator.registerMigration("v25") { db in
                // docs/plans/macos-app-cloud-sync-plan.md §4.1 — these two
                // tables are the deliberate exception to
                // `DiscoveryMigrations.swift`'s "all discovery tables are
                // device-local" header comment: unlike the other eight
                // (jobs, checkpoints, asset state — device-specific
                // scratch/queue state with no meaning on another device),
                // these two hold indexing *outcomes*, which are exactly
                // what should carry across a user's own devices so a Mac
                // (more CPU, no thermal throttling) can index a large
                // library and have the phone see the results without
                // re-processing the audio itself. Existing rows get `NULL`
                // syncID, backfilled lazily the same way the v7
                // syncedTables migration's own synced types are — a UUID
                // generated the first time a row is actually mapped for
                // sync, not eagerly here.
                try db.alter(table: "discovery_embedding") { t in
                    t.add(column: "syncID", .text)
                }
                try db.create(indexOn: "discovery_embedding", columns: ["syncID"], options: .unique)

                try db.alter(table: "discovery_track_analysis") { t in
                    t.add(column: "syncID", .text)
                }
                try db.create(
                    indexOn: "discovery_track_analysis", columns: ["syncID"], options: .unique)
            }
        }
    }
}
