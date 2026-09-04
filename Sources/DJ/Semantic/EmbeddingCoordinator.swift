import Foundation
import GRDB
import TonearmCore

/// The Stage-2 embedding lane (plan commit 2.2, §5): reconciles tracks whose
/// `embeddingVersion` is behind the constant and embeds them, one at a time,
/// through the encoder actor (concurrency-1 on the ANE), honoring the `.embeddings`
/// governor lane (§43.7) and the performance pin (FR-ANL-2). Absence is honest
/// (FR-SEM-6): no audio model → no embedding lane, never a lie and never an error.
public actor EmbeddingCoordinator {

    public let pool: DatabasePool
    private let embedder: CLAPEmbedder
    private let store: any VectorStore
    private let resource: ModelResourceService
    private let assetURL: @Sendable (Int64, Database) throws -> URL?
    private let onProgress: @Sendable (AnalysisProgress) -> Void
    /// `SemanticSearchService.indexDidChange(trackIDs:)` hook — stubbed for 2.4.
    private let onIndexChange: @Sendable ([Int64]) -> Void
    /// Injectable governor gate; defaults to the real `.embeddings` decision.
    private let governorAllowsRun: @Sendable () -> Bool

    /// A performance is live → the lane pauses (FR-ANL-2).
    public private(set) var isPerforming: Bool = false

    private var isRunning = false

    public init(pool: DatabasePool,
                embedder: CLAPEmbedder,
                store: any VectorStore,
                resource: ModelResourceService,
                assetURL: @escaping @Sendable (Int64, Database) throws -> URL? =
                    AnalysisCoordinator.defaultAssetURL,
                governorAllowsRun: @escaping @Sendable () -> Bool =
                    EmbeddingCoordinator.defaultGovernorGate,
                onProgress: @escaping @Sendable (AnalysisProgress) -> Void = { _ in },
                onIndexChange: @escaping @Sendable ([Int64]) -> Void = { _ in }) {
        self.pool = pool
        self.embedder = embedder
        self.store = store
        self.resource = resource
        self.assetURL = assetURL
        self.governorAllowsRun = governorAllowsRun
        self.onProgress = onProgress
        self.onIndexChange = onIndexChange
    }

    /// The real `.embeddings` lane gate: not paused by the current thermal state.
    public static func defaultGovernorGate() -> Bool {
        !ThermalGovernor.decision(for: .embeddings,
                                  thermalState: ProcessInfo.processInfo.thermalState).isPaused
    }

    /// Mark a performance as live/ended; while live, the lane is paused.
    public func setPerforming(_ performing: Bool) {
        isPerforming = performing
    }

    /// How many tracks are stale, counted only when the audio model is present
    /// (FR-SEM-6 availability gate). Enqueuing happens implicitly — the lane
    /// re-derives the set each run, so a crash mid-lane simply re-runs.
    public func reconcileEmbeddings() async throws -> Int {
        guard await resource.isAvailable(.clapAudio) else { return 0 }
        return try await pool.read { db in
            try DJTrack.filter(Column("embeddingVersion") < AnalysisVersions.embedding)
                .fetchCount(db)
        }
    }

    /// Embed every stale track sequentially. Returns early (doing nothing) when
    /// a performance is live, the model is absent, or the governor sheds the
    /// `.embeddings` lane.
    public func runEmbeddingLane() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        guard !isPerforming, await resource.isAvailable(.clapAudio), governorAllowsRun() else {
            return
        }

        let trackIDs: [Int64]
        do {
            trackIDs = try await pool.read { db in
                try DJTrack
                    .filter(Column("embeddingVersion") < AnalysisVersions.embedding)
                    .order(Column("sortKey"))
                    .fetchAll(db)
                    .compactMap(\.id)
            }
        } catch {
            return
        }
        guard !trackIDs.isEmpty else { return }

        let words = ThermalGovernor.words(lane: .embeddings,
                                          thermalState: ProcessInfo.processInfo.thermalState,
                                          batteryLevelPercent: 100, isCharging: true,
                                          userOverride: false, isPerforming: isPerforming)
        var done = 0
        for trackID in trackIDs {
            if isPerforming || !governorAllowsRun() { return }
            done += 1
            onProgress(AnalysisProgress(completed: done, total: trackIDs.count,
                                        currentTrackTitle: nil, governorWords: words))
            await embedOne(trackID)
        }
        onProgress(AnalysisProgress(completed: trackIDs.count, total: trackIDs.count,
                                    governorWords: words))
    }

    // MARK: - Per-track

    private func embedOne(_ trackID: Int64) async {
        let url: URL
        do {
            guard let resolved = try await pool.read({ try assetURL(trackID, $0) }) else {
                try? await pool.write { db in
                    try Self.markFailed(db, trackID: trackID,
                                        error: AnalysisCoordinatorError.noAssetForTrack(trackID))
                }
                return
            }
            url = resolved
        } catch {
            try? await pool.write { db in try Self.markFailed(db, trackID: trackID, error: error) }
            return
        }

        let result: AnalyzePipeline.PooledEmbedding
        do {
            result = try await AnalyzePipeline.embed(url: url, embedder: embedder)
        } catch {
            try? await pool.write { db in try Self.markFailed(db, trackID: trackID, error: error) }
            return
        }
        guard result.pooled.count == store.dims else {
            try? await pool.write { db in
                try Self.markFailed(db, trackID: trackID,
                                    error: SemanticModelError.inferenceFailed(
                                        "pooled vector has \(result.pooled.count) dims, "
                                            + "store expects \(store.dims)"))
            }
            return
        }

        let (int8, scale) = VectorQuantization.quantize(result.pooled)
        do {
            try await pool.write { db in
                let record = DJTrackEmbedding(trackID: trackID, int8Vector: int8,
                                              scale: Double(scale), matrixRow: nil,
                                              version: AnalysisVersions.embedding)
                // track_embedding + matrix append + meta in ONE transaction (§5 2.2).
                try store.upsert(record, db: db)
                try db.execute(sql: "UPDATE track SET embeddingVersion = ? WHERE id = ?",
                               arguments: [AnalysisVersions.embedding, trackID])
            }
            onIndexChange([trackID])
        } catch {
            try? await pool.write { db in try Self.markFailed(db, trackID: trackID, error: error) }
        }
    }

    /// Crash-safe failure bookkeeping; the track stays stale (`embeddingVersion`
    /// untouched) so reconcile re-enqueues it.
    private static func markFailed(_ db: Database, trackID: Int64, error: Error) throws {
        try db.execute(sql: """
            INSERT OR REPLACE INTO analysis_run
            (trackID, stage, version, state, attempts, lastError, startedAt,
             finishedAt, durationMS)
            VALUES (?, 'embeddings', ?, 'failed', 1, ?, NULL, NULL, 0)
            """, arguments: [trackID, AnalysisVersions.embedding, String(describing: error)])
    }
}
