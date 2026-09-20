import Foundation
import GRDB

/// The DB-layer half of docs/plans/macos-app-cloud-sync-plan.md §4 —
/// resolving/persisting `syncID`s and applying an incoming
/// `DiscoveryEmbedding`/`DiscoveryTrackAnalysis` record's accept/reject/
/// requeue outcome. Lives here (not in `Sources/Sync/`, which cannot
/// depend on `Sources/Discovery/`'s `IndexJobRepository` without inverting
/// the normal TonearmCore→TonearmDiscovery dependency direction) so
/// `CloudSyncEngine` only needs to call one method per incoming record.
extension LibraryStore {

    /// The real, current local `syncID` for a track, generating and
    /// persisting one first if it's still `nil` — every existing local row
    /// was inserted without one (no call site sets it explicitly at insert
    /// time), so this is the point where a value actually gets committed
    /// rather than freshly regenerated on every `RecordMapping` call (which
    /// would silently produce a different `syncID` each sync pass).
    public func ensureTrackSyncID(trackId: Int64) throws -> String? {
        try dbQueue.write { db in
            guard var track = try Track.fetchOne(db, key: trackId) else { return nil }
            if let existing = track.syncID { return existing }
            let generated = UUID().uuidString
            track.syncID = generated
            try track.update(db)
            return generated
        }
    }

    public func localTrackId(forSyncID syncID: String) throws -> Int64? {
        try dbQueue.read { db in
            try Track.filter(Column("syncID") == syncID).fetchOne(db)?.id
        }
    }

    /// The local embedding by its OWN `syncID` (not the track's) plus its
    /// track's `syncID` — what `CloudSyncEngine.nextRecordZoneChangeBatch`
    /// needs to build the real `CKRecord` for a pending push.
    public func discoveryEmbedding(
        forSyncID syncID: String
    ) throws -> (embedding: DiscoveryEmbedding, trackSyncID: String?)? {
        try dbQueue.read { db in
            guard let embedding = try DiscoveryEmbedding
                .filter(Column("syncID") == syncID).fetchOne(db)
            else { return nil }
            let trackSyncID = try Track.fetchOne(db, key: embedding.trackId)?.syncID
            return (embedding, trackSyncID)
        }
    }

    public func discoveryTrackAnalysis(
        forSyncID syncID: String
    ) throws -> (analysis: DiscoveryTrackAnalysis, trackSyncID: String?)? {
        try dbQueue.read { db in
            guard let analysis = try DiscoveryTrackAnalysis
                .filter(Column("syncID") == syncID).fetchOne(db)
            else { return nil }
            let trackSyncID = try Track.fetchOne(db, key: analysis.trackId)?.syncID
            return (analysis, trackSyncID)
        }
    }

    /// The local `discovery_embedding`'s `syncID`, generating and
    /// persisting one first if needed — `nil` if this track has no local
    /// embedding at all (nothing to push).
    public func ensureDiscoveryEmbeddingSyncID(trackId: Int64) throws -> String? {
        try dbQueue.write { db in
            guard var embedding = try DiscoveryEmbedding.fetchOne(db, key: trackId) else { return nil }
            if let existing = embedding.syncID { return existing }
            let generated = UUID().uuidString
            embedding.syncID = generated
            try embedding.update(db)
            return generated
        }
    }

    public func ensureDiscoveryTrackAnalysisSyncID(trackId: Int64) throws -> String? {
        try dbQueue.write { db in
            guard var analysis = try DiscoveryTrackAnalysis.fetchOne(db, key: trackId) else { return nil }
            if let existing = analysis.syncID { return existing }
            let generated = UUID().uuidString
            analysis.syncID = generated
            try analysis.update(db)
            return generated
        }
    }

    /// Real report this whole feature answers: "let me index tracks with
    /// CloudKit sync so I can index much faster than on my phone for large
    /// libraries." Applies `DiscoveryEmbeddingSyncDecision`'s outcome for
    /// one incoming embedding record (plan §4.3). Returns what actually
    /// happened, for the status surface — never silently drops a record.
    public enum IncomingDiscoveryEmbeddingResult: Equatable, Sendable {
        case accepted
        case rejectedKeepLocal
        case rejectedRequeued
        /// The track this embedding belongs to doesn't exist locally yet
        /// (this device hasn't imported that source) — nothing to attach
        /// it to. Not a failure: the next sync pass retries once the track
        /// exists (plan §4.3 step 2 — "rely on the next pass").
        case trackNotYetImported
    }

    /// - Parameters:
    ///   - activePipelineVersion/activeModelVersion/activePreprocessingVersion/
    ///     activeSamplingVersion: this device's own currently-active
    ///     `DiscoveryPipelineVersion` constants. Passed in rather than
    ///     referenced directly — `DiscoveryPipelineVersion` lives in the
    ///     `TonearmDiscovery` SwiftPM product, which depends on this
    ///     (`TonearmCore`/`Sources/Data`) target, not the other way around;
    ///     the caller (the iOS adapter layer, which already links both) is
    ///     the correct place to know these values.
    public func applyIncomingDiscoveryEmbedding(
        _ embedding: DiscoveryEmbedding, trackSyncID: String?,
        activePipelineVersion: Int, activeModelVersion: Int,
        activePreprocessingVersion: Int, activeSamplingVersion: Int
    ) throws -> IncomingDiscoveryEmbeddingResult {
        guard let trackSyncID, let trackId = try localTrackId(forSyncID: trackSyncID) else {
            return .trackNotYetImported
        }
        let localExists = try dbQueue.read { db in
            try DiscoveryEmbedding.fetchOne(db, key: trackId) != nil
        }
        let decision = DiscoveryEmbeddingSyncDecision.decide(
            incomingModelVersion: embedding.modelVersion,
            incomingPreprocessingVersion: embedding.preprocessingVersion,
            incomingSamplingVersion: embedding.samplingVersion,
            activeModelVersion: activeModelVersion,
            activePreprocessingVersion: activePreprocessingVersion,
            activeSamplingVersion: activeSamplingVersion,
            localEmbeddingExists: localExists)

        switch decision {
        case .rejectKeepLocal:
            return .rejectedKeepLocal

        case .rejectRequeue:
            try requeueDiscoveryIndexJob(trackId: trackId, pipelineVersion: activePipelineVersion)
            return .rejectedRequeued

        case .accept:
            // This device resolves its OWN asset for the track — the
            // incoming record's assetId/assetRevision are the SENDING
            // device's local file identity, meaningless here (RecordMapping
            // never even carries them across).
            guard let assetId = try dbQueue.read({ db in
                try Asset.filter(Column("trackId") == trackId).fetchOne(db)?.id
            }) else {
                // No local asset for this track yet either — same
                // "nothing to attach it to" situation as an unimported
                // track; retry on a later pass.
                return .trackNotYetImported
            }
            try dbQueue.write { db in
                var row = embedding
                row.trackId = trackId
                row.assetId = assetId
                row.assetRevision = 1
                try row.upsert(db)

                var job = DiscoveryIndexJob(
                    trackId: trackId, selectedAssetId: assetId, assetRevision: 1,
                    pipelineVersion: activePipelineVersion, state: .complete,
                    createdAt: row.completedAt, updatedAt: row.completedAt,
                    completedWindows: 0, totalWindows: 0,
                    embeddingStageState: .complete, musicalAnalysisStageState: .unsupported)
                try job.upsert(db)
            }
            return .accepted
        }
    }

    /// Same accept/reject/requeue policy as `applyIncomingDiscoveryEmbedding`,
    /// adapted to `discovery_track_analysis`'s single `analysisVersion`
    /// field (it has no separate model/preprocessing/sampling axes) —
    /// deliberately not reusing `DiscoveryEmbeddingSyncDecision.decide(...)`,
    /// whose signature is specific to the embedding's three-version shape.
    public func applyIncomingDiscoveryTrackAnalysis(
        _ analysis: DiscoveryTrackAnalysis, trackSyncID: String?,
        activePipelineVersion: Int, activeAnalysisVersion: Int
    ) throws -> IncomingDiscoveryEmbeddingResult {
        guard let trackSyncID, let trackId = try localTrackId(forSyncID: trackSyncID) else {
            return .trackNotYetImported
        }
        let localExists = try dbQueue.read { db in
            try DiscoveryTrackAnalysis.fetchOne(db, key: trackId) != nil
        }
        guard analysis.analysisVersion == activeAnalysisVersion else {
            try requeueDiscoveryIndexJob(trackId: trackId, pipelineVersion: activePipelineVersion)
            return .rejectedRequeued
        }
        guard !localExists else { return .rejectedKeepLocal }

        guard let assetId = try dbQueue.read({ db in
            try Asset.filter(Column("trackId") == trackId).fetchOne(db)?.id
        }) else { return .trackNotYetImported }
        try dbQueue.write { db in
            var row = analysis
            row.trackId = trackId
            row.assetId = assetId
            row.assetRevision = 1
            try row.upsert(db)
        }
        return .accepted
    }

    /// Resets an existing `discovery_index_job` back to `queued` so this
    /// device re-indexes with its own active pipeline (plan §4.3's
    /// `.rejectRequeue` outcome). A no-op if no job row exists yet for this
    /// track — the normal reconciliation sweep will discover it needs
    /// indexing on its own. Deliberately a raw update rather than routing
    /// through `IndexJobRepository.enqueueOrRestart` (a different SwiftPM
    /// product this file cannot depend on without inverting
    /// TonearmCore→TonearmDiscovery) — mirrors that method's `restart: true`
    /// branch closely enough for this one field to matter here.
    private func requeueDiscoveryIndexJob(trackId: Int64, pipelineVersion: Int) throws {
        try dbQueue.write { db in
            guard var job = try DiscoveryIndexJob
                .filter(Column("trackId") == trackId)
                .filter(Column("pipelineVersion") == pipelineVersion)
                .fetchOne(db)
            else { return }
            job.state = .queued
            job.leaseToken = nil
            job.leaseExpiresAt = nil
            job.embeddingStageState = .pending
            job.updatedAt = Date()
            try job.update(db)
            try DiscoveryWindowCheckpoint.filter(Column("jobId") == job.id).deleteAll(db)
        }
    }
}
