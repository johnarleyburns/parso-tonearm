import Foundation
import Testing
import GRDB
@testable import TonearmCore

/// docs/plans/macos-app-cloud-sync-plan.md §4 — DB-layer half of the
/// discovery-index sync feature: syncID persistence and the accept/reject/
/// requeue outcome actually landing in the database.
@Suite struct LibraryStoreDiscoverySyncTests {

    private func makeStore() throws -> LibraryStore {
        try LibraryStore(inMemory: true)
    }

    private func seedTrackWithAsset(_ store: LibraryStore) async throws -> (trackId: Int64, assetId: Int64) {
        let source = try await store.insertSource(
            Source(id: nil, kind: .local, iaIdentifier: nil, originalURL: nil,
                   title: "Src", addedAt: Date(), lastResolvedAt: nil,
                   followUpdates: false, licenseText: nil, memberCapHit: false,
                   localIsFolder: false, artworkTrackId: nil))
        let sourceId = try #require(source.id)
        let track = try await store.insertTrack(
            Track(id: nil, albumId: nil, sourceId: sourceId, title: "Track",
                  trackNo: 1, discNo: nil, durationSec: nil, codec: nil,
                  sampleRate: nil, bitDepthOrBitrate: nil, sortKey: "a"))
        let trackId = try #require(track.id)
        let asset = try await store.insertAsset(
            Asset(id: nil, trackId: trackId, kind: .localRef, bookmark: nil,
                  relPath: "a.flac", remoteURL: nil, altRemoteURL: nil,
                  sizeBytes: nil, unsupportedReason: nil))
        let assetId = try #require(asset.id)
        return (trackId, assetId)
    }

    @Test func testEnsureTrackSyncIDGeneratesAndPersists() async throws {
        let store = try makeStore()
        let (trackId, _) = try await seedTrackWithAsset(store)
        let first = try await store.ensureTrackSyncID(trackId: trackId)
        #expect(first != nil)
        let second = try await store.ensureTrackSyncID(trackId: trackId)
        #expect(first == second, "must not regenerate a different syncID on a second call")
    }

    @Test func testLocalTrackIdResolvesByGeneratedSyncID() async throws {
        let store = try makeStore()
        let (trackId, _) = try await seedTrackWithAsset(store)
        let generated = try await store.ensureTrackSyncID(trackId: trackId)
        let syncID = try #require(generated)
        let resolved = try await store.localTrackId(forSyncID: syncID)
        #expect(resolved == trackId)
    }

    @Test func testApplyIncomingEmbeddingAcceptsWhenNotYetIndexed() async throws {
        let store = try makeStore()
        let (trackId, _) = try await seedTrackWithAsset(store)
        let generatedSyncID = try await store.ensureTrackSyncID(trackId: trackId)
        let trackSyncID = try #require(generatedSyncID)

        let incoming = DiscoveryEmbedding(
            trackId: 999, assetId: 999, assetRevision: 1, modelVersion: 1,
            preprocessingVersion: 1, samplingVersion: 1, dimensions: 2,
            quantizedVector: Data([1, 2]), scale: 0.1, completedAt: Date(), syncID: "EMB-1")

        let result = try await store.applyIncomingDiscoveryEmbedding(
            incoming, trackSyncID: trackSyncID,
            activePipelineVersion: 1, activeModelVersion: 1,
            activePreprocessingVersion: 1, activeSamplingVersion: 1)
        #expect(result == .accepted)

        let saved = try await store.dbQueue.read { db in
            try DiscoveryEmbedding.fetchOne(db, key: trackId)
        }
        #expect(saved?.trackId == trackId, "accepted row must be keyed by the LOCAL trackId")
        #expect(saved?.quantizedVector == Data([1, 2]))
    }

    @Test func testApplyIncomingEmbeddingRejectsAndKeepsLocalWhenAlreadyIndexed() async throws {
        let store = try makeStore()
        let (trackId, assetId) = try await seedTrackWithAsset(store)
        let generatedSyncID = try await store.ensureTrackSyncID(trackId: trackId)
        let trackSyncID = try #require(generatedSyncID)
        try await store.seedBuiltInEmbedding(
            trackId: trackId, assetId: assetId, pipelineVersion: 1,
            modelVersion: 1, preprocessingVersion: 1, samplingVersion: 1,
            dimensions: 1, quantizedVector: Data([9]), scale: 1, completedAt: Date())

        let incoming = DiscoveryEmbedding(
            trackId: 999, assetId: 999, assetRevision: 1, modelVersion: 1,
            preprocessingVersion: 1, samplingVersion: 1, dimensions: 2,
            quantizedVector: Data([1, 2]), scale: 0.1, completedAt: Date(), syncID: "EMB-2")
        let result = try await store.applyIncomingDiscoveryEmbedding(
            incoming, trackSyncID: trackSyncID,
            activePipelineVersion: 1, activeModelVersion: 1,
            activePreprocessingVersion: 1, activeSamplingVersion: 1)
        #expect(result == .rejectedKeepLocal)

        let saved = try await store.dbQueue.read { db in
            try DiscoveryEmbedding.fetchOne(db, key: trackId)
        }
        #expect(saved?.quantizedVector == Data([9]), "local row must be untouched")
    }

    @Test func testApplyIncomingEmbeddingRequeuesLocalJobOnVersionMismatch() async throws {
        let store = try makeStore()
        let (trackId, assetId) = try await seedTrackWithAsset(store)
        let generatedSyncID = try await store.ensureTrackSyncID(trackId: trackId)
        let trackSyncID = try #require(generatedSyncID)
        // A completed local job at pipeline version 1, but no embedding yet
        // (the job's own completion sets one, so seed the job directly).
        try await store.dbQueue.write { db in
            var job = DiscoveryIndexJob(
                trackId: trackId, selectedAssetId: assetId, assetRevision: 1,
                pipelineVersion: 1, state: .complete,
                createdAt: Date(), updatedAt: Date(),
                completedWindows: 0, totalWindows: 0,
                embeddingStageState: .complete, musicalAnalysisStageState: .unsupported)
            try job.insert(db)
        }

        let incompatible = DiscoveryEmbedding(
            trackId: 999, assetId: 999, assetRevision: 1, modelVersion: 2,
            preprocessingVersion: 1, samplingVersion: 1, dimensions: 2,
            quantizedVector: Data([1, 2]), scale: 0.1, completedAt: Date(), syncID: "EMB-3")
        let result = try await store.applyIncomingDiscoveryEmbedding(
            incompatible, trackSyncID: trackSyncID,
            activePipelineVersion: 1, activeModelVersion: 1,
            activePreprocessingVersion: 1, activeSamplingVersion: 1)
        #expect(result == .rejectedRequeued)

        let job = try await store.dbQueue.read { db in
            try DiscoveryIndexJob
                .filter(Column("trackId") == trackId)
                .filter(Column("pipelineVersion") == 1)
                .fetchOne(db)
        }
        #expect(job?.state == .queued, "the LOCAL job must be reset so this device re-indexes itself")
    }

    @Test func testApplyIncomingEmbeddingIsPendingWhenTrackNotYetImported() async throws {
        let store = try makeStore()
        let incoming = DiscoveryEmbedding(
            trackId: 999, assetId: 999, assetRevision: 1, modelVersion: 1,
            preprocessingVersion: 1, samplingVersion: 1, dimensions: 2,
            quantizedVector: Data([1, 2]), scale: 0.1, completedAt: Date(), syncID: "EMB-4")
        let result = try await store.applyIncomingDiscoveryEmbedding(
            incoming, trackSyncID: "no-such-track",
            activePipelineVersion: 1, activeModelVersion: 1,
            activePreprocessingVersion: 1, activeSamplingVersion: 1)
        #expect(result == .trackNotYetImported)
    }

    @Test func testPendingSyncRecordUpsertsPrunesAndDiscards() async throws {
        let store = try makeStore()
        let old = Date().addingTimeInterval(-91 * 86_400)
        try await store.upsertPendingSyncRecord(recordName: "r", recordType: "DJTrackPrep",
                                                payload: Data([1]),
                                                trackKeys: [.init(strength: .meta, value: "hash")],
                                                receivedAt: old)
        try await store.upsertPendingSyncRecord(recordName: "r", recordType: "DJTrackPrep",
                                                payload: Data([2]), trackKeys: [], receivedAt: Date())
        let count = try await store.pendingSyncRecordCount()
        let saved = try await store.pendingSyncRecords()
        #expect(count == 1)
        #expect(saved.first?.payload == Data([2]))
        let pruned = try await store.prunePendingSyncRecords(olderThan: Date().addingTimeInterval(-90 * 86_400))
        #expect(pruned == 0)
        try await store.discardPendingSyncRecords()
        let remaining = try await store.pendingSyncRecordCount()
        #expect(remaining == 0)
    }
}
