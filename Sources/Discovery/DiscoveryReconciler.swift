import Foundation
import GRDB
import TonearmCore

/// Turns core catalog state (and the `discovery_change` outbox) into
/// `discovery_index_job` rows, without ever materializing the whole catalog
/// on the caller's thread (plan §4: "At launch and after outbox changes,
/// reconcile in bounded pages (200 tracks) ... using indexed keyset
/// pagination, not a full catalog materialization").
///
/// This type does no decode/inference/network work itself — it only
/// ensures the job queue accurately reflects the core catalog. The actual
/// audio work is `IndexWorker` (C04, not implemented this session).
public actor DiscoveryReconciler {
    public static let bootstrapPageSize = 200

    private let writer: any DatabaseWriter
    private let jobs: IndexJobRepository
    private let pipelineVersion: Int
    private let clock: () -> Date

    public init(
        writer: any DatabaseWriter,
        jobs: IndexJobRepository,
        pipelineVersion: Int = DiscoveryPipelineVersion.pipeline,
        clock: @escaping () -> Date = Date.init
    ) {
        self.writer = writer
        self.jobs = jobs
        self.pipelineVersion = pipelineVersion
        self.clock = clock
    }

    /// Bootstrap every existing core track that has no job yet for the
    /// current pipeline version, in ascending-id keyset pages of 200. Safe
    /// to call repeatedly (idempotent: `enqueueOrRestart` is a no-op for a
    /// track that already has a job).
    @discardableResult
    public func bootstrapAllTracks() async throws -> Int {
        var lastID: Int64 = 0
        var enqueued = 0
        while true {
            let page = try await pageOfTracksNeedingJobs(afterId: lastID)
            if page.isEmpty { break }
            for trackId in page {
                let assetId = try await preferredAssetId(trackId: trackId)
                try await jobs.enqueueOrRestart(
                    trackId: trackId,
                    selectedAssetId: assetId,
                    assetRevision: assetId == nil ? nil : 1,
                    pipelineVersion: pipelineVersion)
                enqueued += 1
            }
            lastID = page.last!
            if page.count < Self.bootstrapPageSize { break }
        }
        return enqueued
    }

    /// One page of trackIds with `id > afterId` that do not yet have a job
    /// for `pipelineVersion`, using indexed keyset pagination (no OFFSET
    /// scan). The preferred asset is resolved per track by `preferredAssetId`.
    private func pageOfTracksNeedingJobs(afterId: Int64) async throws -> [Int64] {
        try await writer.read { db in
            try Int64.fetchAll(
                db,
                sql: """
                    SELECT t.id
                    FROM track t
                    WHERE t.id > ?
                      AND NOT EXISTS (
                          SELECT 1 FROM discovery_index_job j
                          WHERE j.trackId = t.id AND j.pipelineVersion = ?
                      )
                    ORDER BY t.id
                    LIMIT ?
                    """,
                arguments: [afterId, pipelineVersion, DiscoveryReconciler.bootstrapPageSize])
        }
    }

    /// Drain the `discovery_change` outbox, translating each entry into a
    /// job mutation, then delete the processed rows. Content replacement
    /// restarts the job (new revision); metadata edits and deletions do not
    /// re-embed audio (plan §4: "Do not make every metadata edit
    /// re-embed audio").
    @discardableResult
    public func processOutbox(pageSize: Int = 200) async throws -> Int {
        let changes = try await writer.read { db in
            try DiscoveryChange.order(Column("id")).limit(pageSize).fetchAll(db)
        }
        guard !changes.isEmpty else { return 0 }

        for change in changes {
            switch change.kind {
            case .trackInserted:
                if let trackId = change.trackId {
                    let assetId = try await preferredAssetId(trackId: trackId)
                    try await jobs.enqueueOrRestart(
                        trackId: trackId,
                        selectedAssetId: assetId,
                        assetRevision: assetId == nil ? nil : 1,
                        pipelineVersion: pipelineVersion)
                }
            case .assetContentReplaced:
                if let trackId = change.trackId {
                    let assetId = try await preferredAssetId(trackId: trackId)
                    if let existing = try await jobs.job(
                        trackId: trackId, pipelineVersion: pipelineVersion)
                    {
                        let nextRevision = (existing.assetRevision ?? 0) + 1
                        try await jobs.enqueueOrRestart(
                            trackId: trackId,
                            selectedAssetId: assetId,
                            assetRevision: nextRevision,
                            pipelineVersion: pipelineVersion,
                            restart: true)
                    } else {
                        try await jobs.enqueueOrRestart(
                            trackId: trackId,
                            selectedAssetId: assetId,
                            assetRevision: assetId == nil ? nil : 1,
                            pipelineVersion: pipelineVersion)
                    }
                }
            case .trackDeleted, .sourceDeleted:
                // FK cascades already removed the job/derived rows; nothing
                // further to reconcile.
                break
            case .trackMetadataUpdated:
                // Presentation-only; does not touch analysis/embeddings.
                break
            }
        }

        let lastId = changes.last?.id ?? 0
        try await writer.write { db in
            try db.execute(
                sql: "DELETE FROM discovery_change WHERE id <= ?", arguments: [lastId])
        }
        return changes.count
    }

    private func preferredAssetId(trackId: Int64) async throws -> Int64? {
        try await writer.read { db in
            let assets = try Asset
                .filter(Column("trackId") == trackId)
                .order(Column("id"))
                .fetchAll(db)
            return DiscoveryReconciler.preferredAsset(from: assets)?.id
        }
    }

    /// Deterministic preferred analyzable asset (plan §5): "valid local
    /// original, then complete cache, then explicitly authorized downloadable
    /// original; tie by asset ID". The "complete cache" tier (tier 1) is not
    /// evaluated here — `AudioCache` completeness needs `ParsoAudioStreaming`,
    /// which this target does not depend on; a cached-but-not-local remote
    /// asset therefore ranks with the downloadable original (tier 2) and the
    /// bounded worker's `AnalysisAssetResolver` still resolves a complete
    /// cache at read time if one exists.
    static func preferredAsset(from assets: [Asset]) -> Asset? {
        assets
            .filter { $0.id != nil && $0.unsupportedReason == nil }
            .min { lhs, rhs in
                (assetTier(lhs), lhs.id ?? .max) < (assetTier(rhs), rhs.id ?? .max)
            }
    }

    /// 0 = valid local original (resolvable without network), 2 = downloadable
    /// / remote original, 3 = present but flagged not-on-this-device.
    private static func assetTier(_ asset: Asset) -> Int {
        if asset.needsReimport { return 3 }
        switch asset.kind {
        case .localRef, .managedCopy, .builtIn:
            let hasLocalPath =
                asset.bookmark != nil
                || asset.relPath != nil
                || (asset.remoteURL.flatMap(URL.init(string:))?.isFileURL ?? false)
            return hasLocalPath ? 0 : 2
        case .remote:
            return 2
        }
    }
}
