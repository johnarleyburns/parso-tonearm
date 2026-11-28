import GRDB
import Foundation
import Testing

@testable import TonearmCore
@testable import TonearmDiscovery

/// C03 fixtures for the outbox/bootstrap reconciler: bootstrap covers ALL
/// existing tracks (not just future imports), bootstrap/outbox replay is
/// idempotent, content replacement restarts the job, and metadata-only
/// edits/deletes do not create spurious re-analysis.
@Suite struct DiscoveryReconcilerTests {
    private func makeQueue() throws -> DatabaseQueue {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: config)
        try Schema.migrator().migrate(queue)
        return queue
    }

    @discardableResult
    private func insertTrack(_ queue: DatabaseQueue, title: String = "Song") async throws -> Int64 {
        try await queue.write { db in
            if try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM source") == 0 {
                try db.execute(
                    sql: """
                        INSERT INTO source (kind, title, addedAt, followUpdates, memberCapHit,
                                            localIsFolder)
                        VALUES ('local', 'Music', ?, 0, 0, 1)
                        """, arguments: [Date()])
            }
            let sourceID = try Int64.fetchOne(db, sql: "SELECT id FROM source LIMIT 1")!
            try db.execute(
                sql: "INSERT INTO track (sourceId, title, sortKey) VALUES (?, ?, ?)",
                arguments: [sourceID, title, title.lowercased()])
            return db.lastInsertedRowID
        }
    }

    /// Bootstrap must cover tracks that existed BEFORE discovery shipped —
    /// not only future imports (plan §4: "Bootstrap ALL existing core
    /// tracks, not just future imports").
    @Test func testBootstrapCoversAllExistingTracksAcrossPages() async throws {
        let queue = try makeQueue()
        for i in 0..<(DiscoveryReconciler.bootstrapPageSize + 25) {
            try await insertTrack(queue, title: "Song \(i)")
        }
        let repo = IndexJobRepository(writer: queue)
        let reconciler = DiscoveryReconciler(writer: queue, jobs: repo, pipelineVersion: 1)

        let enqueued = try await reconciler.bootstrapAllTracks()
        #expect(enqueued == DiscoveryReconciler.bootstrapPageSize + 25)

        let jobCount = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM discovery_index_job")!
        }
        #expect(jobCount == DiscoveryReconciler.bootstrapPageSize + 25)
    }

    @Test func testBootstrapIsIdempotent() async throws {
        let queue = try makeQueue()
        try await insertTrack(queue)
        let repo = IndexJobRepository(writer: queue)
        let reconciler = DiscoveryReconciler(writer: queue, jobs: repo, pipelineVersion: 1)

        let first = try await reconciler.bootstrapAllTracks()
        let second = try await reconciler.bootstrapAllTracks()
        #expect(first == 1)
        #expect(second == 0, "re-running bootstrap must not duplicate jobs")
    }

    @Test func testBootstrapRequeuesMissingMusicalAnalysis() async throws {
        let queue = try makeQueue()
        let trackID = try await insertTrack(queue, title: "Needs BPM and key")
        let repo = IndexJobRepository(writer: queue)
        let reconciler = DiscoveryReconciler(
            writer: queue, jobs: repo, pipelineVersion: DiscoveryPipelineVersion.pipeline)
        _ = try await reconciler.bootstrapAllTracks()

        try await queue.write { db in
            try db.execute(
                sql: """
                    UPDATE discovery_index_job
                    SET state = 'complete', musicalAnalysisStageState = 'unsupported'
                    WHERE trackId = ?
                    """, arguments: [trackID])
        }

        let migrated = try await reconciler.bootstrapAllTracks()
        #expect(migrated == 1)
        let loadedJob = try await repo.job(
            trackId: trackID, pipelineVersion: DiscoveryPipelineVersion.pipeline)
        let job = try #require(loadedJob)
        #expect(job.state == .queued)
        #expect(job.musicalAnalysisStageState == .pending)
    }

    @Test func testTrackInsertedChangeCreatesJobAndDrainsOutbox() async throws {
        let queue = try makeQueue()
        // The v19 `discovery_change_track_inserted` trigger already wrote the
        // outbox row for this insert (Sources/Data/DiscoveryMigrations.swift)
        // — no manual outbox insert needed here.
        let trackID = try await insertTrack(queue)
        let repo = IndexJobRepository(writer: queue)
        let reconciler = DiscoveryReconciler(writer: queue, jobs: repo, pipelineVersion: 1)

        let processed = try await reconciler.processOutbox()
        #expect(processed == 1)

        let job = try await repo.job(trackId: trackID, pipelineVersion: 1)
        #expect(job != nil)

        let remainingChanges = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM discovery_change")!
        }
        #expect(remainingChanges == 0, "processed outbox rows must be removed")
    }

    /// Metadata-only edits must not create a fresh revision / re-embed
    /// (plan §4: "Do not make every metadata edit re-embed audio").
    @Test func testMetadataUpdateChangeDoesNotTouchExistingJob() async throws {
        let queue = try makeQueue()
        let trackID = try await insertTrack(queue)
        let repo = IndexJobRepository(writer: queue)
        let reconciler = DiscoveryReconciler(writer: queue, jobs: repo, pipelineVersion: 1)
        try await reconciler.bootstrapAllTracks()
        let before = try await repo.job(trackId: trackID, pipelineVersion: 1)!

        try await queue.write { db in
            try db.execute(
                sql: "INSERT INTO discovery_change (trackId, kind, createdAt) VALUES (?, ?, ?)",
                arguments: [trackID, "trackMetadataUpdated", Date()])
        }
        try await reconciler.processOutbox()

        let after = try await repo.job(trackId: trackID, pipelineVersion: 1)!
        #expect(before.assetRevision == after.assetRevision)
        #expect(before.state == after.state)
        #expect(before.updatedAt == after.updatedAt, "metadata edits must not restart the job")
    }

    /// Content replacement DOES bump the revision and restart the job (plan
    /// §4: "Source replacement changes the revision even if the title is
    /// identical").
    @Test func testAssetContentReplacedRestartsJobWithNewRevision() async throws {
        let queue = try makeQueue()
        let trackID = try await insertTrack(queue)
        let repo = IndexJobRepository(writer: queue)
        let reconciler = DiscoveryReconciler(writer: queue, jobs: repo, pipelineVersion: 1)
        try await reconciler.bootstrapAllTracks()

        // Simulate the job having completed once already.
        let claim = try await repo.claimNextJob()!
        try await repo.completeMusicalAnalysis(
            jobId: claim.job.id, leaseToken: claim.leaseToken, state: .complete)
        let completed = try await repo.job(trackId: trackID, pipelineVersion: 1)!
        #expect(completed.state == .complete)

        try await queue.write { db in
            try db.execute(
                sql: "INSERT INTO discovery_change (trackId, kind, createdAt) VALUES (?, ?, ?)",
                arguments: [trackID, "assetContentReplaced", Date()])
        }
        try await reconciler.processOutbox()

        let restarted = try await repo.job(trackId: trackID, pipelineVersion: 1)!
        #expect(restarted.id == completed.id, "same logical job, restarted")
        #expect(restarted.state == .queued)
        #expect(restarted.musicalAnalysisStageState == .pending)
        #expect(restarted.assetRevision ?? 0 > completed.assetRevision ?? 0)
    }

    // MARK: - Downloaded/on-device only (real report: "2631 tracks waiting
    // on their audio file... I want to only index downloaded / on-device
    // tracks")

    @discardableResult
    private func insertAsset(
        _ queue: DatabaseQueue, trackId: Int64, kind: String, relPath: String? = nil,
        remoteURL: String? = nil
    ) async throws -> Int64 {
        try await queue.write { db in
            try db.execute(
                sql: "INSERT INTO asset (trackId, kind, relPath, remoteURL) VALUES (?, ?, ?, ?)",
                arguments: [trackId, kind, relPath, remoteURL])
            return db.lastInsertedRowID
        }
    }

    /// A track whose only asset is a bare remote/cloud original (never
    /// downloaded) must not get an index job at all — the old behavior
    /// created one anyway and it sat in `waitingForAsset` permanently,
    /// since nothing was ever going to make a network-only asset locally
    /// resolvable on its own.
    @Test func testBootstrapSkipsATrackWhoseOnlyAssetIsRemote() async throws {
        let queue = try makeQueue()
        let trackID = try await insertTrack(queue)
        try await insertAsset(
            queue, trackId: trackID, kind: "remote", remoteURL: "https://example.com/song.mp3")
        let repo = IndexJobRepository(writer: queue)
        let reconciler = DiscoveryReconciler(writer: queue, jobs: repo, pipelineVersion: 1)

        let enqueued = try await reconciler.bootstrapAllTracks()
        #expect(enqueued == 0, "a remote-only track must not be enqueued for indexing")
        let job = try await repo.job(trackId: trackID, pipelineVersion: 1)
        #expect(job == nil)
    }

    /// A track with a real local asset (relPath) is unaffected — it is
    /// still eligible and gets that asset selected, exactly as before.
    @Test func testBootstrapStillEnqueuesATrackWithARealLocalAsset() async throws {
        let queue = try makeQueue()
        let trackID = try await insertTrack(queue)
        let assetID = try await insertAsset(
            queue, trackId: trackID, kind: "localRef", relPath: "song.m4a")
        let repo = IndexJobRepository(writer: queue)
        let reconciler = DiscoveryReconciler(writer: queue, jobs: repo, pipelineVersion: 1)

        let enqueued = try await reconciler.bootstrapAllTracks()
        #expect(enqueued == 1)
        let job = try await repo.job(trackId: trackID, pipelineVersion: 1)
        #expect(job?.selectedAssetId == assetID)
    }

    /// A track with NO asset rows yet (a local import still writing its
    /// asset) stays eligible with a `nil` selected asset, same as before —
    /// only a track whose assets ALL resolve to remote/cloud is skipped.
    @Test func testBootstrapStillEnqueuesATrackWithNoAssetRowsYet() async throws {
        let queue = try makeQueue()
        let trackID = try await insertTrack(queue)
        let repo = IndexJobRepository(writer: queue)
        let reconciler = DiscoveryReconciler(writer: queue, jobs: repo, pipelineVersion: 1)

        let enqueued = try await reconciler.bootstrapAllTracks()
        #expect(enqueued == 1)
        let job = try await repo.job(trackId: trackID, pipelineVersion: 1)
        #expect(job != nil)
        #expect(job?.selectedAssetId == nil)
    }

    /// `remoteOnlyTrackCount()` feeds the Settings confirmation dialog's
    /// data-cost estimate — it must count exactly the tracks
    /// `assetSelection` treats as ineligible (remote-only), never a track
    /// that already has a real local asset or one with no asset rows yet
    /// (still eligible/pending, not "remote-only").
    @Test func testRemoteOnlyTrackCountMatchesIneligibleTracks() async throws {
        let queue = try makeQueue()
        let remoteOnly = try await insertTrack(queue, title: "Remote")
        try await insertAsset(
            queue, trackId: remoteOnly, kind: "remote", remoteURL: "https://example.com/a.mp3")
        let local = try await insertTrack(queue, title: "Local")
        try await insertAsset(queue, trackId: local, kind: "localRef", relPath: "b.m4a")
        let noAssetYet = try await insertTrack(queue, title: "Pending")
        _ = noAssetYet

        let repo = IndexJobRepository(writer: queue)
        let reconciler = DiscoveryReconciler(writer: queue, jobs: repo, pipelineVersion: 1)

        let count = try await reconciler.remoteOnlyTrackCount()
        #expect(count == 1)
    }

    /// A `trackInserted` outbox event for a remote-only track is drained
    /// (no infinite outbox loop) without ever creating a job.
    @Test func testTrackInsertedOutboxEventSkipsARemoteOnlyTrack() async throws {
        let queue = try makeQueue()
        let trackID = try await insertTrack(queue)
        try await insertAsset(
            queue, trackId: trackID, kind: "remote", remoteURL: "https://example.com/song.mp3")
        let repo = IndexJobRepository(writer: queue)
        let reconciler = DiscoveryReconciler(writer: queue, jobs: repo, pipelineVersion: 1)

        try await reconciler.processOutbox()
        let remainingChanges = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM discovery_change")!
        }
        #expect(remainingChanges == 0, "the outbox rows must still be drained")
        let job = try await repo.job(trackId: trackID, pipelineVersion: 1)
        #expect(job == nil)
    }

    /// Real-installs cleanup: `pruneJobsForUndownloadedTracks()` removes an
    /// existing `waitingForAsset` job for a track that is (and always was)
    /// remote-only, but leaves alone a `waitingForAsset` job for a track
    /// that genuinely has a local asset (some other, real wait reason).
    @Test func testPruneRemovesOnlyJobsForTracksWithNoLocalAsset() async throws {
        let queue = try makeQueue()
        let repo = IndexJobRepository(writer: queue)
        let reconciler = DiscoveryReconciler(writer: queue, jobs: repo, pipelineVersion: 1)

        let remoteTrackID = try await insertTrack(queue, title: "Remote Song")
        try await insertAsset(
            queue, trackId: remoteTrackID, kind: "remote",
            remoteURL: "https://example.com/song.mp3")
        let remoteJob = try await repo.enqueueOrRestart(
            trackId: remoteTrackID, selectedAssetId: nil, assetRevision: nil, pipelineVersion: 1)

        let localTrackID = try await insertTrack(queue, title: "Local Song")
        let localAssetID = try await insertAsset(
            queue, trackId: localTrackID, kind: "localRef", relPath: "song.m4a")
        let localJob = try await repo.enqueueOrRestart(
            trackId: localTrackID, selectedAssetId: localAssetID, assetRevision: 1,
            pipelineVersion: 1)

        // Drive both jobs to `.waitingForAsset` directly (a full claim/lease
        // round trip isn't what this test is about, and `claimNextJob`'s
        // immediate-reclaim-on-null-nextAttemptAt behavior makes claiming
        // both jobs in a fixed order unreliable here).
        for jobId in [remoteJob.id, localJob.id] {
            try await queue.write { db in
                try db.execute(
                    sql: "UPDATE discovery_index_job SET state = 'waitingForAsset' WHERE id = ?",
                    arguments: [jobId])
            }
        }

        let pruned = try await reconciler.pruneJobsForUndownloadedTracks()
        #expect(pruned == 1)
        let remainingRemoteJob = try await repo.job(id: remoteJob.id)
        #expect(remainingRemoteJob == nil, "the remote-only track's job must be gone")
        let remainingLocalJob = try await repo.job(id: localJob.id)
        #expect(remainingLocalJob != nil, "a track with a real local asset must be untouched")
        #expect(remainingLocalJob?.state == .waitingForAsset)
    }

    /// trackDeleted/sourceDeleted changes: the FK cascade already removed
    /// the job; the reconciler must still drain (delete) the outbox row
    /// rather than looping on it forever.
    @Test func testDeletedTrackChangeIsDrainedWithoutError() async throws {
        let queue = try makeQueue()
        let trackID = try await insertTrack(queue)
        let repo = IndexJobRepository(writer: queue)
        let reconciler = DiscoveryReconciler(writer: queue, jobs: repo, pipelineVersion: 1)
        try await reconciler.bootstrapAllTracks()

        // The v19 `discovery_change_track_deleted` trigger writes the outbox
        // row itself, with trackId NULL (the deleted track's own id cascades
        // away before the AFTER DELETE trigger's INSERT could reference it).
        try await queue.write { db in
            try db.execute(sql: "DELETE FROM track WHERE id = ?", arguments: [trackID])
        }
        let processed = try await reconciler.processOutbox()
        #expect(processed == 1)
        let remaining = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM discovery_change")!
        }
        #expect(remaining == 0)
    }

    // MARK: - Legacy remote node backfill (real report: "the button doesn't
    // do anything, no tracks are queued from my 2,600+ remote tracks" —
    // those assets predate remoteNodeID/remoteNodePath persistence, commit
    // 0a80ff8, so they fail sparse-indexing eligibility no matter how many
    // times bootstrap runs).

    private struct FakeRemoteProvider: RemoteLibraryProvider {
        let sourceKind: SourceKind = .webDAV
        let tree: [String: [RemoteNode]]
        func browse(path: String) async throws -> [RemoteNode] { tree[path] ?? [] }
        func resolve(node: RemoteNode) async throws -> ResolvedAsset {
            ResolvedAsset(url: URL(string: "https://example.com/resolved")!)
        }
        func refresh() async throws {}
    }

    @discardableResult
    private func insertRemoteSource(_ queue: DatabaseQueue) async throws -> Int64 {
        try await queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO source (kind, title, addedAt, followUpdates, memberCapHit,
                                        localIsFolder)
                    VALUES ('webDAV', 'My Server', ?, 0, 0, 0)
                    """, arguments: [Date()])
            return db.lastInsertedRowID
        }
    }

    @discardableResult
    private func insertIASource(_ queue: DatabaseQueue) async throws -> Int64 {
        try await queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO source (kind, title, addedAt, followUpdates, memberCapHit,
                                        localIsFolder)
                    VALUES ('iaItem', 'An Archive.org Item', ?, 0, 0, 0)
                    """, arguments: [Date()])
            return db.lastInsertedRowID
        }
    }

    @discardableResult
    private func insertTrack(_ queue: DatabaseQueue, sourceId: Int64, title: String) async throws -> Int64 {
        try await queue.write { db in
            try db.execute(
                sql: "INSERT INTO track (sourceId, title, sortKey) VALUES (?, ?, ?)",
                arguments: [sourceId, title, title.lowercased()])
            return db.lastInsertedRowID
        }
    }

    @Test func testBackfillMatchesLegacyRemoteAssetBySizeAndPersistsNodeReference() async throws {
        let queue = try makeQueue()
        let sourceID = try await insertRemoteSource(queue)
        let trackID = try await insertTrack(queue, sourceId: sourceID, title: "Song One")
        let assetID = try await insertAsset(
            queue, trackId: trackID, kind: "remote", remoteURL: "https://old.example.com/song1.mp3")
        try await queue.write { db in
            try db.execute(sql: "UPDATE asset SET sizeBytes = ? WHERE id = ?", arguments: [12345, assetID])
        }
        let repo = IndexJobRepository(writer: queue)
        let reconciler = DiscoveryReconciler(
            writer: queue, jobs: repo, pipelineVersion: 1, remoteIndexingEnabled: { true })
        let node = RemoteNode(
            id: "node-1", title: "Song One", path: "/music/song1.mp3", kind: .audio, sizeBytes: 12345)
        let provider = FakeRemoteProvider(tree: ["": [node]])

        let backfilled = await reconciler.backfillRemoteNodeReferences { _ in provider }
        #expect(backfilled == 1)

        let row = try await queue.read { db -> [String?] in
            let row = try Row.fetchOne(db, sql: "SELECT remoteNodeID, remoteNodePath FROM asset WHERE id = ?",
                arguments: [assetID])!
            return [row["remoteNodeID"], row["remoteNodePath"]]
        }
        #expect(row[0] == "node-1")
        #expect(row[1] == "/music/song1.mp3")
    }

    @Test func testBackfillDoesNothingWhenRemoteIndexingIsDisabled() async throws {
        let queue = try makeQueue()
        let sourceID = try await insertRemoteSource(queue)
        let trackID = try await insertTrack(queue, sourceId: sourceID, title: "Song One")
        _ = try await insertAsset(
            queue, trackId: trackID, kind: "remote", remoteURL: "https://old.example.com/song1.mp3")
        let repo = IndexJobRepository(writer: queue)
        // Default remoteIndexingEnabled closure returns false.
        let reconciler = DiscoveryReconciler(writer: queue, jobs: repo, pipelineVersion: 1)
        let node = RemoteNode(id: "node-1", title: "Song One", path: "/music/song1.mp3", kind: .audio)
        let provider = FakeRemoteProvider(tree: ["": [node]])

        let backfilled = await reconciler.backfillRemoteNodeReferences { _ in provider }
        #expect(backfilled == 0, "must not make network calls when the setting is off")
    }

    /// When size is unknown (or ambiguous), falls back to matching by
    /// normalized title.
    @Test func testBackfillFallsBackToTitleMatchWhenSizeIsUnavailable() async throws {
        let queue = try makeQueue()
        let sourceID = try await insertRemoteSource(queue)
        let trackID = try await insertTrack(queue, sourceId: sourceID, title: "Unique Title")
        let assetID = try await insertAsset(
            queue, trackId: trackID, kind: "remote", remoteURL: "https://old.example.com/x.mp3")
        let repo = IndexJobRepository(writer: queue)
        let reconciler = DiscoveryReconciler(
            writer: queue, jobs: repo, pipelineVersion: 1, remoteIndexingEnabled: { true })
        let node = RemoteNode(id: "node-2", title: "Unique Title", path: "/music/x.mp3", kind: .audio)
        let provider = FakeRemoteProvider(tree: ["": [node]])

        let backfilled = await reconciler.backfillRemoteNodeReferences { _ in provider }
        #expect(backfilled == 1)

        let nodePath = try await queue.read { db in
            try Row.fetchOne(db, sql: "SELECT remoteNodePath FROM asset WHERE id = ?",
                arguments: [assetID])!["remoteNodePath"] as String?
        }
        #expect(nodePath == "/music/x.mp3")
    }

    /// Recurses into `.directory`/`.collection` container nodes to find
    /// leaf tracks nested below the root.
    @Test func testBackfillRecursesIntoDirectories() async throws {
        let queue = try makeQueue()
        let sourceID = try await insertRemoteSource(queue)
        let trackID = try await insertTrack(queue, sourceId: sourceID, title: "Nested Song")
        let assetID = try await insertAsset(
            queue, trackId: trackID, kind: "remote", remoteURL: "https://old.example.com/nested.mp3")
        try await queue.write { db in
            try db.execute(sql: "UPDATE asset SET sizeBytes = ? WHERE id = ?", arguments: [999, assetID])
        }
        let repo = IndexJobRepository(writer: queue)
        let reconciler = DiscoveryReconciler(
            writer: queue, jobs: repo, pipelineVersion: 1, remoteIndexingEnabled: { true })
        let folder = RemoteNode(id: "folder-1", title: "Album", path: "/Album", kind: .directory)
        let node = RemoteNode(
            id: "node-3", title: "Nested Song", path: "/Album/nested.mp3", kind: .audio, sizeBytes: 999)
        let provider = FakeRemoteProvider(tree: ["": [folder], "/Album": [node]])

        let backfilled = await reconciler.backfillRemoteNodeReferences { _ in provider }
        #expect(backfilled == 1)

        let nodePath = try await queue.read { db in
            try Row.fetchOne(db, sql: "SELECT remoteNodePath FROM asset WHERE id = ?",
                arguments: [assetID])!["remoteNodePath"] as String?
        }
        #expect(nodePath == "/Album/nested.mp3")
    }

    /// Real root cause found auditing the first backfill fix:
    /// `RemoteLibraryProviderFactory.provider(for:)` never supported
    /// Internet Archive source kinds (it threw `.unsupportedURL` for them),
    /// so the crawl-and-match path could never have worked for IA-origin
    /// remote tracks — very likely the largest remote-library source type
    /// in this app — no matter how good the matching heuristic was. IA
    /// assets get a direct, network-free path instead: the node reference
    /// is just the already-persisted `remoteURL` reflected back, matching
    /// what `IARemoteLibraryProvider.browse` itself would construct. This
    /// must not call `providerFactory` at all (that closure is set up to
    /// fail in this test, to prove the network path isn't used).
    @Test func testBackfillUsesRemoteURLDirectlyForArchiveOrgSourcesNoNetworkCall() async throws {
        let queue = try makeQueue()
        let sourceID = try await insertIASource(queue)
        let trackID = try await insertTrack(queue, sourceId: sourceID, title: "IA Track")
        let assetID = try await insertAsset(
            queue, trackId: trackID, kind: "remote",
            remoteURL: "https://archive.org/download/some-item/track01.mp3")
        let repo = IndexJobRepository(writer: queue)
        let reconciler = DiscoveryReconciler(
            writer: queue, jobs: repo, pipelineVersion: 1, remoteIndexingEnabled: { true })

        let backfilled = await reconciler.backfillRemoteNodeReferences { _ in
            Issue.record("must not construct/crawl a provider for an Internet Archive source")
            throw URLError(.unsupportedURL)
        }
        #expect(backfilled == 1)

        let row = try await queue.read { db -> [String?] in
            let row = try Row.fetchOne(db, sql: "SELECT remoteNodeID, remoteNodePath FROM asset WHERE id = ?",
                arguments: [assetID])!
            return [row["remoteNodeID"], row["remoteNodePath"]]
        }
        #expect(row[0] == "https://archive.org/download/some-item/track01.mp3")
        #expect(row[1] == "https://archive.org/download/some-item/track01.mp3")
    }

    // MARK: - Jamendo tracks only index once genuinely "in My Music" (real report: only index
    // what the user has listened to, downloaded, or added to a playlist, not merely browsed)

    @discardableResult
    private func insertJamendoSource(_ queue: DatabaseQueue) async throws -> Int64 {
        try await queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO source (kind, title, addedAt, followUpdates, memberCapHit,
                                        localIsFolder)
                    VALUES ('jamendoGenre', 'Electronic', ?, 0, 0, 0)
                    """, arguments: [Date()])
            return db.lastInsertedRowID
        }
    }

    private func recordPlay(_ queue: DatabaseQueue, trackId: Int64) async throws {
        try await queue.write { db in
            try db.execute(
                sql: "INSERT INTO play_history (trackId, playedAt) VALUES (?, ?)",
                arguments: [trackId, Date()])
        }
    }

    private func addToPlaylist(_ queue: DatabaseQueue, trackId: Int64) async throws {
        try await queue.write { db in
            try db.execute(sql: "INSERT INTO playlist (kind, title) VALUES ('manual', 'My Playlist')")
            let playlistID = db.lastInsertedRowID
            try db.execute(
                sql: "INSERT INTO playlist_item (playlistId, position, trackId) VALUES (?, 0, ?)",
                arguments: [playlistID, trackId])
        }
    }

    /// A browsed-but-never-used Jamendo track (just a remote asset from importing it, same as
    /// any other remote track) must not be enqueued at all, even though an identical non-Jamendo
    /// remote track with the same asset shape already is (see
    /// `testBootstrapSkipsATrackWhoseOnlyAssetIsRemote`/`testBootstrapStillEnqueuesATrackWithNoAssetRowsYet`
    /// for the normal, unaffected behavior that must stay unaffected for non-Jamendo sources).
    @Test func testJamendoTrackWithNoUsageSignalIsNotEnqueued() async throws {
        let queue = try makeQueue()
        let sourceID = try await insertJamendoSource(queue)
        let trackID = try await insertTrack(queue, sourceId: sourceID, title: "Browsed Only")
        let repo = IndexJobRepository(writer: queue)
        let reconciler = DiscoveryReconciler(writer: queue, jobs: repo, pipelineVersion: 1)

        let enqueued = try await reconciler.bootstrapAllTracks()
        #expect(enqueued == 0, "a merely-browsed Jamendo track must not be enqueued")
        let job = try await repo.job(trackId: trackID, pipelineVersion: 1)
        #expect(job == nil)
    }

    @Test func testJamendoTrackBecomesEligibleOnceListenedTo() async throws {
        let queue = try makeQueue()
        let sourceID = try await insertJamendoSource(queue)
        let trackID = try await insertTrack(queue, sourceId: sourceID, title: "Listened")
        try await recordPlay(queue, trackId: trackID)
        let repo = IndexJobRepository(writer: queue)
        let reconciler = DiscoveryReconciler(writer: queue, jobs: repo, pipelineVersion: 1)

        let enqueued = try await reconciler.bootstrapAllTracks()
        #expect(enqueued == 1)
        let job = try await repo.job(trackId: trackID, pipelineVersion: 1)
        #expect(job != nil)
    }

    @Test func testJamendoTrackBecomesEligibleOnceDownloaded() async throws {
        let queue = try makeQueue()
        let sourceID = try await insertJamendoSource(queue)
        let trackID = try await insertTrack(queue, sourceId: sourceID, title: "Downloaded")
        try await insertAsset(queue, trackId: trackID, kind: "managedCopy", relPath: "song.m4a")
        let repo = IndexJobRepository(writer: queue)
        let reconciler = DiscoveryReconciler(writer: queue, jobs: repo, pipelineVersion: 1)

        let enqueued = try await reconciler.bootstrapAllTracks()
        #expect(enqueued == 1)
        let job = try await repo.job(trackId: trackID, pipelineVersion: 1)
        #expect(job != nil)
    }

    @Test func testJamendoTrackBecomesEligibleOnceAddedToAPlaylist() async throws {
        let queue = try makeQueue()
        let sourceID = try await insertJamendoSource(queue)
        let trackID = try await insertTrack(queue, sourceId: sourceID, title: "Playlisted")
        try await addToPlaylist(queue, trackId: trackID)
        let repo = IndexJobRepository(writer: queue)
        let reconciler = DiscoveryReconciler(writer: queue, jobs: repo, pipelineVersion: 1)

        let enqueued = try await reconciler.bootstrapAllTracks()
        #expect(enqueued == 1)
        let job = try await repo.job(trackId: trackID, pipelineVersion: 1)
        #expect(job != nil)
    }

    /// A non-Jamendo remote track with the exact same asset-free shape as the skipped Jamendo
    /// track above is unaffected by this gate — it's eligible with a nil selected asset exactly
    /// as before (`testBootstrapStillEnqueuesATrackWithNoAssetRowsYet`'s normal behavior).
    @Test func testNonJamendoRemoteTrackIsUnaffectedByTheJamendoGate() async throws {
        let queue = try makeQueue()
        let sourceID = try await insertRemoteSource(queue)
        let trackID = try await insertTrack(queue, sourceId: sourceID, title: "Not Jamendo")
        let repo = IndexJobRepository(writer: queue)
        let reconciler = DiscoveryReconciler(writer: queue, jobs: repo, pipelineVersion: 1)

        let enqueued = try await reconciler.bootstrapAllTracks()
        #expect(enqueued == 1, "only Jamendo sources are gated by usage signal")
        let job = try await repo.job(trackId: trackID, pipelineVersion: 1)
        #expect(job != nil)
    }
}
