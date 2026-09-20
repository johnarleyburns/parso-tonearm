import XCTest
import GRDB
@testable import TonearmCore

/// docs/plans/macos-app-cloud-sync-plan.md §4 — DB-layer half of the
/// discovery-index sync feature: syncID persistence and the accept/reject/
/// requeue outcome actually landing in the database.
final class LibraryStoreDiscoverySyncTests: XCTestCase {

    private func makeStore() throws -> LibraryStore {
        try LibraryStore(inMemory: true)
    }

    private func seedTrackWithAsset(_ store: LibraryStore) async throws -> (trackId: Int64, assetId: Int64) {
        let source = try await store.insertSource(
            Source(id: nil, kind: .local, iaIdentifier: nil, originalURL: nil,
                   title: "Src", addedAt: Date(), lastResolvedAt: nil,
                   followUpdates: false, licenseText: nil, memberCapHit: false,
                   localIsFolder: false, artworkTrackId: nil))
        let sourceId = try XCTUnwrap(source.id)
        let track = try await store.insertTrack(
            Track(id: nil, albumId: nil, sourceId: sourceId, title: "Track",
                  trackNo: 1, discNo: nil, durationSec: nil, codec: nil,
                  sampleRate: nil, bitDepthOrBitrate: nil, sortKey: "a"))
        let trackId = try XCTUnwrap(track.id)
        let asset = try await store.insertAsset(
            Asset(id: nil, trackId: trackId, kind: .localRef, bookmark: nil,
                  relPath: "a.flac", remoteURL: nil, altRemoteURL: nil,
                  sizeBytes: nil, unsupportedReason: nil))
        let assetId = try XCTUnwrap(asset.id)
        return (trackId, assetId)
    }

    func testEnsureTrackSyncIDGeneratesAndPersists() async throws {
        let store = try makeStore()
        let (trackId, _) = try await seedTrackWithAsset(store)
        let first = try await store.ensureTrackSyncID(trackId: trackId)
        XCTAssertNotNil(first)
        let second = try await store.ensureTrackSyncID(trackId: trackId)
        XCTAssertEqual(first, second, "must not regenerate a different syncID on a second call")
    }

    func testLocalTrackIdResolvesByGeneratedSyncID() async throws {
        let store = try makeStore()
        let (trackId, _) = try await seedTrackWithAsset(store)
        let generated = try await store.ensureTrackSyncID(trackId: trackId)
        let syncID = try XCTUnwrap(generated)
        let resolved = try await store.localTrackId(forSyncID: syncID)
        XCTAssertEqual(resolved, trackId)
    }

    func testApplyIncomingEmbeddingAcceptsWhenNotYetIndexed() async throws {
        let store = try makeStore()
        let (trackId, _) = try await seedTrackWithAsset(store)
        let generatedSyncID = try await store.ensureTrackSyncID(trackId: trackId)
        let trackSyncID = try XCTUnwrap(generatedSyncID)

        let incoming = DiscoveryEmbedding(
            trackId: 999, assetId: 999, assetRevision: 1, modelVersion: 1,
            preprocessingVersion: 1, samplingVersion: 1, dimensions: 2,
            quantizedVector: Data([1, 2]), scale: 0.1, completedAt: Date(), syncID: "EMB-1")

        let result = try await store.applyIncomingDiscoveryEmbedding(
            incoming, trackSyncID: trackSyncID,
            activePipelineVersion: 1, activeModelVersion: 1,
            activePreprocessingVersion: 1, activeSamplingVersion: 1)
        XCTAssertEqual(result, .accepted)

        let saved = try await store.dbQueue.read { db in
            try DiscoveryEmbedding.fetchOne(db, key: trackId)
        }
        XCTAssertEqual(saved?.trackId, trackId, "accepted row must be keyed by the LOCAL trackId")
        XCTAssertEqual(saved?.quantizedVector, Data([1, 2]))
    }

    func testApplyIncomingEmbeddingRejectsAndKeepsLocalWhenAlreadyIndexed() async throws {
        let store = try makeStore()
        let (trackId, assetId) = try await seedTrackWithAsset(store)
        let generatedSyncID = try await store.ensureTrackSyncID(trackId: trackId)
        let trackSyncID = try XCTUnwrap(generatedSyncID)
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
        XCTAssertEqual(result, .rejectedKeepLocal)

        let saved = try await store.dbQueue.read { db in
            try DiscoveryEmbedding.fetchOne(db, key: trackId)
        }
        XCTAssertEqual(saved?.quantizedVector, Data([9]), "local row must be untouched")
    }

    func testApplyIncomingEmbeddingRequeuesLocalJobOnVersionMismatch() async throws {
        let store = try makeStore()
        let (trackId, assetId) = try await seedTrackWithAsset(store)
        let generatedSyncID = try await store.ensureTrackSyncID(trackId: trackId)
        let trackSyncID = try XCTUnwrap(generatedSyncID)
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
        XCTAssertEqual(result, .rejectedRequeued)

        let job = try await store.dbQueue.read { db in
            try DiscoveryIndexJob
                .filter(Column("trackId") == trackId)
                .filter(Column("pipelineVersion") == 1)
                .fetchOne(db)
        }
        XCTAssertEqual(job?.state, .queued, "the LOCAL job must be reset so this device re-indexes itself")
    }

    func testApplyIncomingEmbeddingIsPendingWhenTrackNotYetImported() async throws {
        let store = try makeStore()
        let incoming = DiscoveryEmbedding(
            trackId: 999, assetId: 999, assetRevision: 1, modelVersion: 1,
            preprocessingVersion: 1, samplingVersion: 1, dimensions: 2,
            quantizedVector: Data([1, 2]), scale: 0.1, completedAt: Date(), syncID: "EMB-4")
        let result = try await store.applyIncomingDiscoveryEmbedding(
            incoming, trackSyncID: "no-such-track",
            activePipelineVersion: 1, activeModelVersion: 1,
            activePreprocessingVersion: 1, activeSamplingVersion: 1)
        XCTAssertEqual(result, .trackNotYetImported)
    }
}
