import GRDB
import Foundation
import Testing

@testable import TonearmCore

/// C01 fixture: upgrading a v17 database to v18 must preserve all existing
/// core rows exactly and add the new discovery_* tables with the FK/
/// cascade/uniqueness invariants plan §4 requires.
@Suite struct DiscoverySchemaMigrationTests {
    /// Cascade/uniqueness assertions need real FK enforcement, matching
    /// `LibraryStore`'s on-disk configuration (`config.foreignKeysEnabled = true`).
    private func makeQueue() throws -> DatabaseQueue {
        var config = Configuration()
        config.foreignKeysEnabled = true
        return try DatabaseQueue(configuration: config)
    }

    private func seedV17Catalog(_ queue: DatabaseQueue) throws {
        try queue.write { db in
            let now = Date()
            try db.execute(
                sql: """
                    INSERT INTO source (kind, title, addedAt, followUpdates, memberCapHit,
                                        localIsFolder, syncID)
                    VALUES ('local', 'Music', ?, 0, 0, 1, ?)
                    """, arguments: [now, UUID().uuidString])
            let sourceID = db.lastInsertedRowID

            try db.execute(
                sql: """
                    INSERT INTO track (sourceId, title, sortKey, syncID)
                    VALUES (?, 'Song One', 'song one', ?)
                    """, arguments: [sourceID, UUID().uuidString])
            let trackID = db.lastInsertedRowID

            try db.execute(
                sql: """
                    INSERT INTO asset (trackId, kind, relPath, syncID)
                    VALUES (?, 'localRef', 'song1.m4a', ?)
                    """, arguments: [trackID, UUID().uuidString])

            try db.execute(
                sql: """
                    INSERT INTO playlist (title, kind, watch, syncID)
                    VALUES ('My Playlist', 'manual', 0, ?)
                    """, arguments: [UUID().uuidString])
            let playlistID = db.lastInsertedRowID

            try db.execute(
                sql: """
                    INSERT INTO playlist_item (playlistId, position, trackId)
                    VALUES (?, 0, ?)
                    """, arguments: [playlistID, trackID])
        }
    }

    private func before(_ queue: DatabaseQueue) throws -> (
        sources: Int, tracks: Int, assets: Int, playlists: Int, items: Int, syncIDs: [String?]
    ) {
        try queue.read { db in
            (
                sources: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM source") ?? 0,
                tracks: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track") ?? 0,
                assets: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset") ?? 0,
                playlists: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM playlist") ?? 0,
                items: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM playlist_item") ?? 0,
                syncIDs: try String?.fetchAll(db, sql: "SELECT syncID FROM track ORDER BY id")
            )
        }
    }

    @Test func testV18UpgradePreservesExistingCoreData() throws {
        let queue = try makeQueue()
        try Schema.migrator(upTo: "v17").migrate(queue)
        try seedV17Catalog(queue)
        let snapshot = try before(queue)

        try Schema.migrator().migrate(queue)

        let after = try before(queue)
        #expect(after.sources == snapshot.sources)
        #expect(after.tracks == snapshot.tracks)
        #expect(after.assets == snapshot.assets)
        #expect(after.playlists == snapshot.playlists)
        #expect(after.items == snapshot.items)
        #expect(after.syncIDs == snapshot.syncIDs)
    }

    @Test func testV18CreatesAllDiscoveryTables() throws {
        let queue = try makeQueue()
        try Schema.migrator().migrate(queue)
        try queue.read { db throws in
            for table in [
                "discovery_asset_state", "discovery_track_analysis", "discovery_embedding",
                "discovery_index_job", "discovery_window_checkpoint", "discovery_change",
                "discovery_setting", "discovery_import_job", "discovery_import_item",
                "discovery_runtime",
            ] {
                #expect(try db.tableExists(table), "\(table) should exist after v18")
            }
        }
    }

    @Test func testDiscoveryTablesHaveNoSyncIDColumn() throws {
        // Plan §4: device-local tables are excluded from CloudKit export.
        // This repo's sync export list is keyed off syncID columns (v7), so
        // the absence of syncID is the structural guarantee.
        //
        // discovery_track_analysis and discovery_embedding are the
        // deliberate exception as of migration v25
        // (docs/plans/macos-app-cloud-sync-plan.md §4.1): they hold indexing
        // *outcomes*, not device-local queue/lease/scratch state, so they
        // sync — see testDiscoveryEmbeddingAndTrackAnalysisHaveSyncIDColumn
        // below for their matching positive assertion.
        let queue = try makeQueue()
        try Schema.migrator().migrate(queue)
        try queue.read { db throws in
            for table in [
                "discovery_asset_state",
                "discovery_index_job", "discovery_window_checkpoint", "discovery_change",
                "discovery_setting", "discovery_import_job", "discovery_import_item",
                "discovery_runtime",
            ] {
                #expect(
                    !(try db.columns(in: table).contains { $0.name == "syncID" }),
                    "\(table) must not be sync-exported")
            }
        }
    }

    @Test func testDiscoveryEmbeddingAndTrackAnalysisHaveSyncIDColumn() throws {
        let queue = try makeQueue()
        try Schema.migrator().migrate(queue)
        try queue.read { db throws in
            for table in ["discovery_embedding", "discovery_track_analysis"] {
                #expect(
                    try db.columns(in: table).contains { $0.name == "syncID" },
                    "\(table) is meant to sync its indexing outcome (plan §4.1)")
            }
        }
    }

    @Test func testDeletingTrackCascadesDiscoveryRows() throws {
        let queue = try makeQueue()
        try Schema.migrator().migrate(queue)
        try seedV17Catalog(queue)

        try queue.write { db throws in
            let trackID = try Int64.fetchOne(db, sql: "SELECT id FROM track LIMIT 1")!
            let assetID = try Int64.fetchOne(
                db, sql: "SELECT id FROM asset WHERE trackId = ?", arguments: [trackID])!

            try db.execute(
                sql: """
                    INSERT INTO discovery_asset_state (assetId, contentRevision, lastValidatedAt)
                    VALUES (?, 1, ?)
                    """, arguments: [assetID, Date()])
            try db.execute(
                sql: """
                    INSERT INTO discovery_index_job (id, trackId, pipelineVersion, state,
                        createdAt, updatedAt, embeddingStageState, musicalAnalysisStageState)
                    VALUES (?, ?, 1, 'queued', ?, ?, 'pending', 'pending')
                    """,
                arguments: [UUID().uuidString, trackID, Date(), Date()])

            #expect(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM discovery_asset_state") == 1)
            #expect(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM discovery_index_job") == 1)

            try db.execute(sql: "DELETE FROM track WHERE id = ?", arguments: [trackID])

            #expect(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM discovery_asset_state") == 0,
                "asset cascade (asset deleted via track cascade) must remove discovery_asset_state")
            #expect(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM discovery_index_job") == 0,
                "deleting a track must cascade-delete its index job")
        }
    }

    @Test func testOneActiveJobPerTrackAndPipelineVersionIsEnforced() throws {
        let queue = try makeQueue()
        try Schema.migrator().migrate(queue)
        try seedV17Catalog(queue)

        try queue.write { db in
            let trackID = try Int64.fetchOne(db, sql: "SELECT id FROM track LIMIT 1")!
            try db.execute(
                sql: """
                    INSERT INTO discovery_index_job (id, trackId, pipelineVersion, state,
                        createdAt, updatedAt, embeddingStageState, musicalAnalysisStageState)
                    VALUES (?, ?, 1, 'queued', ?, ?, 'pending', 'pending')
                    """,
                arguments: [UUID().uuidString, trackID, Date(), Date()])

            do {
                try db.execute(
                    sql: """
                        INSERT INTO discovery_index_job (id, trackId, pipelineVersion, state,
                            createdAt, updatedAt, embeddingStageState, musicalAnalysisStageState)
                        VALUES (?, ?, 1, 'queued', ?, ?, 'pending', 'pending')
                        """,
                    arguments: [UUID().uuidString, trackID, Date(), Date()])
                Issue.record("a second job for the same (trackId, pipelineVersion) must be rejected")
            } catch {
            }
        }
    }
}
