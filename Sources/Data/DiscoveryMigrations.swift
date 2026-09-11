import Foundation
import GRDB

/// Appended schema for unified-library CLAP indexing/search
/// (IMPLEMENT_CLAP_PLAN.md §4). Registered as core migration `v18` in
/// `Schema.swift`. This migration only adds tables — it never touches
/// `source`/`album`/`artist`/`track`/`asset`/`playlist`/`playlist_item`/
/// `favorite`/`play_history`/`custom_artwork` or any historical migration.
///
/// All ten tables here are device-local derived state: they are
/// intentionally NOT added to any CloudKit/sync export list (plan §4 —
/// "All new tables are device-local: exclude jobs, caches, derived
/// analysis, model state and checkpoints from CloudKit export"). None of
/// them gained a `syncID` column, unlike the v7 syncedTables migration.
enum DiscoveryMigrations {
    static func v18(_ db: Database) throws {
        try db.create(table: "discovery_asset_state") { t in
            t.column("assetId", .integer).primaryKey()
                .references("asset", onDelete: .cascade)
            t.column("contentRevision", .integer).notNull().defaults(to: 1)
                .check { $0 >= 1 }
            t.column("observedSizeBytes", .integer)
            t.column("observedMTime", .datetime)
            t.column("observedProviderValidator", .text)
            t.column("canonicalRevisionSignature", .text)
            t.column("lastValidatedAt", .datetime).notNull()
        }

        try db.create(table: "discovery_track_analysis") { t in
            t.column("trackId", .integer).primaryKey()
                .references("track", onDelete: .cascade)
            t.column("assetId", .integer).notNull()
                .references("asset", onDelete: .cascade)
            t.column("assetRevision", .integer).notNull()
            t.column("analysisVersion", .integer).notNull()
            t.column("bpm", .double)
            t.column("key", .text)
            t.column("energy", .double)
            t.column("phraseSummary", .text)
            t.column("analysisScopeSeconds", .double)
            t.column("completedAt", .datetime)
        }

        try db.create(table: "discovery_embedding") { t in
            t.column("trackId", .integer).primaryKey()
                .references("track", onDelete: .cascade)
            t.column("assetId", .integer).notNull()
                .references("asset", onDelete: .cascade)
            t.column("assetRevision", .integer).notNull()
            t.column("modelVersion", .integer).notNull()
            t.column("preprocessingVersion", .integer).notNull()
            t.column("samplingVersion", .integer).notNull()
            t.column("dimensions", .integer).notNull().check { $0 > 0 }
            t.column("quantizedVector", .blob).notNull()
            t.column("scale", .double).notNull()
            t.column("completedAt", .datetime).notNull()
        }
        try db.create(
            indexOn: "discovery_embedding",
            columns: ["modelVersion", "preprocessingVersion", "samplingVersion"])

        try db.create(table: "discovery_index_job") { t in
            t.column("id", .text).primaryKey()
            t.column("trackId", .integer).notNull()
                .references("track", onDelete: .cascade)
            t.column("selectedAssetId", .integer)
                .references("asset", onDelete: .setNull)
            t.column("assetRevision", .integer)
            t.column("pipelineVersion", .integer).notNull()
            t.column("state", .text).notNull()
            t.column("priority", .integer).notNull().defaults(to: 0)
            t.column("createdAt", .datetime).notNull()
            t.column("updatedAt", .datetime).notNull()
            t.column("nextAttemptAt", .datetime)
            t.column("attemptCount", .integer).notNull().defaults(to: 0)
            t.column("leaseToken", .text)
            t.column("leaseExpiresAt", .datetime)
            t.column("completedWindows", .integer).notNull().defaults(to: 0)
            t.column("totalWindows", .integer).notNull().defaults(to: 0)
            t.column("embeddingStageState", .text).notNull()
            t.column("musicalAnalysisStageState", .text).notNull()
            t.column("errorCode", .text)
            t.column("errorMessage", .text)
        }
        // One active logical job per (track, pipelineVersion) — plan §4.
        try db.create(
            indexOn: "discovery_index_job", columns: ["trackId", "pipelineVersion"],
            options: .unique)
        try db.create(indexOn: "discovery_index_job", columns: ["state", "priority"])
        try db.create(indexOn: "discovery_index_job", columns: ["nextAttemptAt"])

        try db.create(table: "discovery_window_checkpoint") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("jobId", .text).notNull()
                .references("discovery_index_job", onDelete: .cascade)
            t.column("revisionSignature", .text).notNull()
            t.column("windowIndex", .integer).notNull()
            t.column("startSeconds", .double).notNull()
            t.column("embeddingVector", .blob).notNull()
            t.column("poolingWeight", .double).notNull()
            t.column("completedAt", .datetime).notNull()
        }
        try db.create(
            indexOn: "discovery_window_checkpoint", columns: ["jobId", "windowIndex"],
            options: .unique)

        try db.create(table: "discovery_change") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("trackId", .integer)
                .references("track", onDelete: .cascade)
            t.column("kind", .text).notNull()
            t.column("createdAt", .datetime).notNull()
        }
        try db.create(indexOn: "discovery_change", columns: ["id"])

        try db.create(table: "discovery_setting") { t in
            t.column("key", .text).primaryKey()
            t.column("value", .text).notNull()
        }

        try db.create(table: "discovery_import_job") { t in
            t.column("id", .text).primaryKey()
            t.column("sourceId", .integer)
                .references("source", onDelete: .cascade)
            t.column("sourceKind", .text).notNull()
            t.column("resumeLocator", .blob)
            t.column("state", .text).notNull()
            t.column("providerCursor", .text)
            t.column("discoveredCount", .integer).notNull().defaults(to: 0)
            t.column("importedCount", .integer).notNull().defaults(to: 0)
            t.column("failedCount", .integer).notNull().defaults(to: 0)
            t.column("enumerationComplete", .boolean).notNull().defaults(to: false)
            t.column("lastError", .text)
            t.column("createdAt", .datetime).notNull()
            t.column("updatedAt", .datetime).notNull()
        }
        try db.create(indexOn: "discovery_import_job", columns: ["state"])

        try db.create(table: "discovery_import_item") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("jobId", .text).notNull()
                .references("discovery_import_job", onDelete: .cascade)
            t.column("itemIdentity", .text).notNull()
            t.column("state", .text).notNull()
            t.column("resultingTrackId", .integer)
                .references("track", onDelete: .setNull)
            t.column("error", .text)
        }
        try db.create(
            indexOn: "discovery_import_item", columns: ["jobId", "itemIdentity"],
            options: .unique)

        try db.create(table: "discovery_runtime") { t in
            t.column("id", .integer).primaryKey().check { $0 == 1 }
            t.column("lastRunAt", .datetime)
            t.column("lastStartAt", .datetime)
            t.column("lastStopAt", .datetime)
            t.column("lastStopReason", .text)
            t.column("lastBackgroundSubmissionResult", .text)
            t.column("lastBackgroundSubmissionAt", .datetime)
            t.column("lastSuccessfulWorkAt", .datetime)
        }
        try db.execute(sql: "INSERT INTO discovery_runtime (id) VALUES (1)")
    }

    /// Real outbox write-path wiring (IMPLEMENT_CLAP_PLAN.md §4/§5), added as
    /// core migration `v19`. Rather than instrument every one of the many
    /// named call sites individually (`ImportRouter`, AppState import
    /// methods, folder scanning, remote provider sync, AudioCache
    /// completion — plan §5), this uses the plan's own explicitly-sanctioned
    /// backstop mechanism: "SQL triggers are the backstop for writes outside
    /// LibraryStore, including sync/importers; keep trigger logic small and
    /// let a reconciler select assets and create jobs." A trigger on
    /// `track`/`asset` fires no matter which code path performs the insert/
    /// update, so this single migration covers every current AND future
    /// writer without an exhaustive, easy-to-miss per-call-site audit.
    ///
    /// `discovery_change.trackId` has `ON DELETE CASCADE` to `track` (v18),
    /// so a deletion event can never carry the just-deleted track's id (it
    /// would be cascaded away by the same DELETE statement that created it).
    /// Deletion events are therefore always written with `trackId = NULL`;
    /// `DiscoveryReconciler.processOutbox` already treats
    /// `trackDeleted`/`sourceDeleted` as pure drains that don't read
    /// `change.trackId` (FK cascade already removed the derived rows —
    /// plan §4), so this is consistent with the existing reconciler, not a
    /// new behavior for it to learn.
    static func v19(_ db: Database) throws {
        // New track (any writer): make it discoverable.
        try db.execute(
            sql: """
                CREATE TRIGGER discovery_change_track_inserted
                AFTER INSERT ON track
                BEGIN
                    INSERT INTO discovery_change (trackId, kind, createdAt)
                    VALUES (NEW.id, 'trackInserted', CURRENT_TIMESTAMP);
                END
                """)

        // Track metadata edited (title/artist/genre/etc. via any writer,
        // including TagEdit): presentation-only invalidation, never
        // re-embeds audio (plan §4).
        try db.execute(
            sql: """
                CREATE TRIGGER discovery_change_track_updated
                AFTER UPDATE ON track
                BEGIN
                    INSERT INTO discovery_change (trackId, kind, createdAt)
                    VALUES (NEW.id, 'trackMetadataUpdated', CURRENT_TIMESTAMP);
                END
                """)

        // Track deleted (any writer). FK cascade already removed
        // discovery_index_job/discovery_embedding/etc for this track by the
        // time this fires; trackId must be NULL here (see doc comment).
        try db.execute(
            sql: """
                CREATE TRIGGER discovery_change_track_deleted
                AFTER DELETE ON track
                BEGIN
                    INSERT INTO discovery_change (trackId, kind, createdAt)
                    VALUES (NULL, 'trackDeleted', CURRENT_TIMESTAMP);
                END
                """)

        // Source deleted (any writer).
        try db.execute(
            sql: """
                CREATE TRIGGER discovery_change_source_deleted
                AFTER DELETE ON source
                BEGIN
                    INSERT INTO discovery_change (trackId, kind, createdAt)
                    VALUES (NULL, 'sourceDeleted', CURRENT_TIMESTAMP);
                END
                """)

        // New asset attached to a track (any writer): the track may only
        // just now have become analyzable. `enqueueOrRestart` is idempotent
        // (no-op if a job already exists for this track), so this is safe
        // to fire even for a second/alternate asset on an already-indexed
        // track.
        try db.execute(
            sql: """
                CREATE TRIGGER discovery_change_asset_inserted
                AFTER INSERT ON asset
                BEGIN
                    INSERT INTO discovery_change (trackId, kind, createdAt)
                    VALUES (NEW.trackId, 'trackInserted', CURRENT_TIMESTAMP);
                END
                """)

        // Asset content actually changed (re-imported/re-linked file,
        // different bytes) — bumps the job's content revision, restarting
        // its analysis (plan §4: "Source replacement changes the revision
        // even if the title is identical"). Deliberately narrow to the
        // columns that represent WHICH bytes are read; cache/last-access
        // bookkeeping columns are not part of this table and are not
        // watched here (plan §4: "Cache path/last-access changes alone are
        // NOT content revisions").
        try db.execute(
            sql: """
                CREATE TRIGGER discovery_change_asset_content_replaced
                AFTER UPDATE OF bookmark, relPath, remoteURL, altRemoteURL, sizeBytes ON asset
                WHEN NEW.bookmark IS NOT OLD.bookmark
                    OR NEW.relPath IS NOT OLD.relPath
                    OR NEW.remoteURL IS NOT OLD.remoteURL
                    OR NEW.altRemoteURL IS NOT OLD.altRemoteURL
                    OR NEW.sizeBytes IS NOT OLD.sizeBytes
                BEGIN
                    INSERT INTO discovery_change (trackId, kind, createdAt)
                    VALUES (NEW.trackId, 'assetContentReplaced', CURRENT_TIMESTAMP);
                END
                """)
    }

    /// C05 status persistence (IMPLEMENT_CLAP_PLAN.md §4/§11 C05): widen the
    /// singleton `discovery_runtime` telemetry row with the fields the plan's
    /// C05 status surface calls for beyond the v18 set — the last coded error,
    /// a compact coverage snapshot string ("238 / 1042") captured at the end
    /// of the last run, and the next scheduled background-run time (the
    /// `earliestBeginDate` of the most recent `BGProcessingTaskRequest`).
    /// Still telemetry, never the authoritative queue.
    static func v20(_ db: Database) throws {
        try db.alter(table: "discovery_runtime") { t in
            t.add(column: "lastError", .text)
            t.add(column: "coverageSnapshot", .text)
            t.add(column: "nextScheduledAt", .datetime)
        }
    }
}
