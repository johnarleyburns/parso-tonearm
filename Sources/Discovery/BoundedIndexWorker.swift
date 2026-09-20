#if !os(watchOS)
import Foundation
import GRDB
import os.log
import ParsoAudioAnalysis
import ParsoAudioNeural
import TonearmCore

/// The real C04 `IndexJobExecuting` implementation: bounded windowed reads
/// (`WindowedAudioReader`), the shared CLAP encoder (`ModelManager`), and the
/// shared BPM/key/energy analyzers (`ParsoAudioAnalysis.FullAnalysis`) over a
/// bounded sample — never a whole-file decode (plan §6).
///
/// Only ONE analysis job executes at a time (plan §6): this type does not
/// itself enforce that (the scheduler already only ever has one worker/one
/// claimed job in flight — plan §7, "only one scheduler exists per
/// process"), but every heavy call here (`readWindow`, `logMel`,
/// `embedAudio`, `FullAnalysis.run`) runs on the caller's (non-MainActor)
/// task, never main.
public actor BoundedIndexWorker: IndexJobExecuting {
    /// A window read and preprocessed to 48 kHz mono covers this many
    /// seconds (matches the CLAP encoder's `clipSamples` of 10 s at 48 kHz —
    /// plan §6's fixed v1 window length).
    public static let embeddingWindowSeconds: Double = 10
    /// Musical analysis samples at most this many seconds from the track
    /// midpoint (plan §6: "up to 60 seconds from the track midpoint, shorter
    /// files in full").
    public static let musicalAnalysisMaxSeconds: Double = 60

    private let writer: any DatabaseWriter
    private let jobs: IndexJobRepository
    private let models: ModelManager
    private let reader: WindowedAudioReader
    private let resolver: AnalysisAssetResolver
    private let executionContext: @Sendable () -> ModelManager.ExecutionContext
    private let clock: () -> Date
    /// docs/plans/macos-app-cloud-sync-plan.md §4.4 — the push half of
    /// syncing indexing outcomes. Called with the track id right after a
    /// local embedding commits. An injected closure (same cross-module-
    /// boundary pattern as `executionContext`/`modelResourceProvider`
    /// elsewhere in this file) because `CloudSyncEngine` lives in
    /// `Sources/Sync/`, part of the `TonearmCore` product this
    /// `TonearmDiscovery` product depends on — not the other way around.
    private let onEmbeddingCompleted: @Sendable (Int64) -> Void
    /// Remote sparse indexing (docs/plans/remote-sparse-indexing.md) — a
    /// `.remote` asset's PCM comes from here instead of
    /// `resolver`/`reader`. See `remoteSession(jobId:asset:)` for lifecycle.
    private let remoteReader: AssetBackedWindowedAudioReader
    private let remoteLoaderQueue = DispatchQueue(label: "guru.parso.tonearm.discovery.remoteLoaders")
    /// One ephemeral `RemoteSparseAssetResolver.Session` per in-flight
    /// remote job, keyed by job id, reused across that job's ~13 embedding/
    /// analysis window reads (per the plan's design — re-authenticating and
    /// rebuilding the `AVAssetReader`/resource-loader stack per window would
    /// multiply both the re-auth round trips and any per-request fetch
    /// overhead by ~13x for no benefit). Only ever holds 0–1 entries in
    /// practice (plan §6: "Only ONE analysis job executes at a time"), but
    /// keyed by job id rather than a single optional so a job that finishes
    /// while an unrelated stale entry hasn't been cleaned up yet can never
    /// clobber the wrong session.
    private var remoteSessions: [String: RemoteSparseAssetResolver.Session] = [:]

    public init(
        writer: any DatabaseWriter,
        jobs: IndexJobRepository,
        models: ModelManager,
        reader: WindowedAudioReader = WindowedAudioReader(),
        resolver: AnalysisAssetResolver = AnalysisAssetResolver(),
        remoteReader: AssetBackedWindowedAudioReader = AssetBackedWindowedAudioReader(),
        executionContext: @escaping @Sendable () -> ModelManager.ExecutionContext = { .foreground },
        clock: @escaping () -> Date = Date.init,
        onEmbeddingCompleted: @escaping @Sendable (Int64) -> Void = { _ in }
    ) {
        self.writer = writer
        self.jobs = jobs
        self.models = models
        self.reader = reader
        self.resolver = resolver
        self.remoteReader = remoteReader
        self.executionContext = executionContext
        self.clock = clock
        self.onEmbeddingCompleted = onEmbeddingCompleted
    }

    public func processNextUnit(job: DiscoveryIndexJob, leaseToken: String) async -> IndexWorkOutcome {
        guard job.embeddingStageState == .pending || job.embeddingStageState == .running else {
            return await processMusicalAnalysis(job: job)
        }
        return await processEmbeddingWindow(job: job, leaseToken: leaseToken)
    }

    // MARK: - Embedding stage

    private func processEmbeddingWindow(
        job: DiscoveryIndexJob, leaseToken: String
    ) async -> IndexWorkOutcome {
        guard let selectedAssetId = job.selectedAssetId, let asset = fetchAsset(id: selectedAssetId)
        else {
            return .waiting(reason: .waitingForAsset, retryAfterSeconds: nil)
        }

        let encoder: any SemanticModel
        do {
            encoder = try await models.audioEncoder(context: executionContext())
        } catch {
            return .waiting(reason: .waitingForModel, retryAfterSeconds: nil)
        }

        let duration: Double
        do {
            duration = try await resolvedDuration(
                jobId: job.id, asset: asset, track: fetchTrack(id: job.trackId), stage: .embedding)
        } catch let outcome as IndexWorkOutcome {
            return outcome
        } catch {
            return .transientFailure(code: "durationReadFailed", message: error.localizedDescription)
        }

        let windowStarts = DiscoverySamplingPolicy.windowStarts(durationSeconds: duration)
        let completed = (try? await jobs.completedWindowIndices(jobId: job.id)) ?? []
        guard let nextIndex = (0..<windowStarts.count).first(where: { !completed.contains($0) }) else {
            return await finalizeEmbedding(job: job, encoder: encoder)
        }
        let startSeconds = windowStarts[nextIndex]

        let pcm: [Float]
        if asset.kind == .remote {
            switch await readRemoteWindow(
                jobId: job.id, asset: asset, startSeconds: startSeconds,
                windowSeconds: Self.embeddingWindowSeconds)
            {
            case .samples(let samples): pcm = samples
            case .waitingForAsset: return .waiting(reason: .waitingForAsset, retryAfterSeconds: 300)
            case .unsupported:
                await releaseRemoteSession(jobId: job.id)
                return .embeddingStageFinished(.unsupported)
            case .transientFailure(let code, let message):
                return .transientFailure(code: code, message: message)
            }
        } else {
            do {
                let outcome = try resolver.withResolvedURL(for: asset) { url -> [Float] in
                    let samples = try reader.readWindow(
                        url: url, startSeconds: startSeconds,
                        windowSeconds: Self.embeddingWindowSeconds)
                    self.recordAssetState(
                        assetId: selectedAssetId, revision: job.assetRevision ?? 1, url: url)
                    return samples
                }
                switch outcome {
                case .success(let samples): pcm = samples
                case .failure: return .waiting(reason: .waitingForAsset, retryAfterSeconds: 300)
                }
            } catch let readerError as WindowedAudioReaderError {
                switch readerError.kind {
                case .cannotOpenFile, .unsupportedFormat:
                    return .embeddingStageFinished(.unsupported)
                case .converterCreationFailed, .readFailed:
                    return .transientFailure(code: "windowReadFailed", message: readerError.detail)
                }
            } catch {
                return .transientFailure(code: "windowReadFailed", message: error.localizedDescription)
            }
        }

        let logMel: [Float]
        do {
            logMel = try SemanticPreprocess.logMel(clip: pcm, spec: encoder.spec)
        } catch {
            return .transientFailure(code: "preprocessFailed", message: error.localizedDescription)
        }

        let embedding: [Float]
        do {
            embedding = try await encoder.embedAudio(logMel: logMel)
        } catch let semanticError as SemanticModelError {
            switch semanticError {
            case .modelUnavailable:
                return .waiting(reason: .waitingForModel, retryAfterSeconds: nil)
            case .modelLoadFailed, .inferenceFailed, .tokenizerUnavailable:
                return .transientFailure(code: "embedFailed", message: semanticError.errorDescription)
            }
        } catch {
            return .transientFailure(code: "embedFailed", message: error.localizedDescription)
        }
        guard embedding.allSatisfy({ $0.isFinite }) else {
            return .transientFailure(code: "embedNonFinite", message: nil)
        }

        let vectorData = embedding.withUnsafeBufferPointer { Data(buffer: $0) }
        let checkpoint = DiscoveryWindowCheckpoint(
            jobId: job.id,
            revisionSignature: "\(job.assetRevision ?? 0)",
            windowIndex: nextIndex,
            startSeconds: startSeconds,
            embeddingVector: vectorData,
            poolingWeight: 1.0,
            completedAt: clock())

        do {
            try await jobs.recordWindowCompletion(
                jobId: job.id, leaseToken: leaseToken, checkpoint: checkpoint,
                totalWindows: windowStarts.count)
        } catch {
            return .transientFailure(code: "checkpointWriteFailed", message: error.localizedDescription)
        }
        return .windowCompleted
    }

    /// Pool every completed window's raw embedding into the final track
    /// vector, quantize it, and commit `discovery_embedding` (plan §6:
    /// "quantize only the final normalized pooled vector"). Known gap
    /// (documented in IMPLEMENTATION_STATUS.md): this commit and the job's
    /// own `.complete` flip (via `IndexJobRepository.completeStage`, called
    /// by the scheduler right after this returns) are two separate
    /// transactions rather than one atomic commit — a crash between them
    /// just leaves the job re-processed (idempotent overwrite) on retry,
    /// never a lost or duplicated embedding.
    /// The embedding stage's window reads are done either way (success or
    /// failure below) — the remote session (if any) has nothing left to
    /// serve until musical analysis starts its own, so it's released here
    /// regardless of `finalizeEmbeddingOutcome`'s result.
    private func finalizeEmbedding(
        job: DiscoveryIndexJob, encoder: any SemanticModel
    ) async -> IndexWorkOutcome {
        let outcome = finalizeEmbeddingOutcome(job: job, encoder: encoder)
        await releaseRemoteSession(jobId: job.id)
        return outcome
    }

    private func finalizeEmbeddingOutcome(
        job: DiscoveryIndexJob, encoder: any SemanticModel
    ) -> IndexWorkOutcome {
        guard let assetId = job.selectedAssetId else {
            return .waiting(reason: .waitingForAsset, retryAfterSeconds: nil)
        }
        let vectors: [[Float]]
        do {
            vectors = try writer.read { db in
                try DiscoveryWindowCheckpoint
                    .filter(Column("jobId") == job.id)
                    .order(Column("windowIndex"))
                    .fetchAll(db)
                    .map { checkpoint in
                        checkpoint.embeddingVector.withUnsafeBytes { raw in
                            Array(raw.bindMemory(to: Float.self))
                        }
                    }
            }
        } catch {
            return .transientFailure(code: "checkpointReadFailed", message: error.localizedDescription)
        }
        guard !vectors.isEmpty else {
            return .transientFailure(code: "noCheckpoints", message: nil)
        }

        // Plan §5: compare observed size/mtime before and after processing;
        // invalidate if the underlying file changed while we were reading it.
        // Remote assets have no stable local mtime/size to compare (no
        // `recordAssetState` call is ever made for them — see
        // `readRemoteWindow`), so this simply never trips for them.
        if let asset = fetchAsset(id: assetId),
            let recorded = fetchAssetState(assetId: assetId),
            let current = currentStat(asset: asset),
            current.size != recorded.observedSizeBytes
                || !Self.sameInstant(current.mtime, recorded.observedMTime)
        {
            return .transientFailure(
                code: "assetChangedDuringProcessing",
                message: "selected asset changed while indexing; will restart")
        }

        let pooled = SemanticPooling.pool(vectors, strategy: encoder.spec.pooling)
        guard !pooled.isEmpty, pooled.allSatisfy({ $0.isFinite }) else {
            return .embeddingStageFinished(.failed)
        }
        let (int8, scale) = VectorQuantization.quantize(pooled)

        let trackId = job.trackId
        let assetRevision = job.assetRevision ?? 1
        let dimensions = pooled.count
        let quantizedVector = VectorQuantization.data(int8)
        let scaleValue = Double(scale)
        let completedAt = clock()
        let jobId = job.id

        do {
            try writer.write { db in
                var embeddingRow = DiscoveryEmbedding(
                    trackId: trackId,
                    assetId: assetId,
                    assetRevision: assetRevision,
                    modelVersion: DiscoveryPipelineVersion.model,
                    preprocessingVersion: DiscoveryPipelineVersion.preprocessing,
                    samplingVersion: DiscoveryPipelineVersion.sampling,
                    dimensions: dimensions,
                    quantizedVector: quantizedVector,
                    scale: scaleValue,
                    completedAt: completedAt)
                try embeddingRow.upsert(db)
                try DiscoveryWindowCheckpoint.filter(Column("jobId") == jobId).deleteAll(db)
            }
        } catch {
            return .transientFailure(code: "embeddingCommitFailed", message: error.localizedDescription)
        }
        onEmbeddingCompleted(trackId)
        return .embeddingStageFinished(.complete)
    }

    // MARK: - Musical analysis stage

    /// Musical analysis is the last stage that ever needs the remote asset
    /// — the session (if any) is released here regardless of outcome.
    private func processMusicalAnalysis(job: DiscoveryIndexJob) async -> IndexWorkOutcome {
        let outcome = await processMusicalAnalysisOutcome(job: job)
        await releaseRemoteSession(jobId: job.id)
        return outcome
    }

    private func processMusicalAnalysisOutcome(job: DiscoveryIndexJob) async -> IndexWorkOutcome {
        guard let selectedAssetId = job.selectedAssetId, let asset = fetchAsset(id: selectedAssetId)
        else {
            return .waiting(reason: .waitingForAsset, retryAfterSeconds: nil)
        }
        let track = fetchTrack(id: job.trackId)

        let duration: Double
        do {
            duration = try await resolvedDuration(
                jobId: job.id, asset: asset, track: track, stage: .musicalAnalysis)
        } catch let outcome as IndexWorkOutcome {
            return outcome
        } catch {
            return .transientFailure(code: "durationReadFailed", message: error.localizedDescription)
        }

        let scopeSeconds = min(Self.musicalAnalysisMaxSeconds, duration)
        let startSeconds = max(0, duration / 2 - scopeSeconds / 2)

        let pcm: [Float]
        let sampleRate: Double
        if asset.kind == .remote {
            sampleRate = remoteReader.targetSampleRate
            switch await readRemoteWindow(
                jobId: job.id, asset: asset, startSeconds: startSeconds, windowSeconds: scopeSeconds)
            {
            case .samples(let samples): pcm = samples
            case .waitingForAsset: return .waiting(reason: .waitingForAsset, retryAfterSeconds: 300)
            case .unsupported: return .musicalAnalysisStageFinished(.unsupported)
            case .transientFailure(let code, let message):
                return .transientFailure(code: code, message: message)
            }
        } else {
            sampleRate = reader.targetSampleRate
            do {
                let outcome = try resolver.withResolvedURL(for: asset) { url -> [Float] in
                    let samples = try reader.readWindow(
                        url: url, startSeconds: startSeconds, windowSeconds: scopeSeconds)
                    self.recordAssetState(
                        assetId: selectedAssetId, revision: job.assetRevision ?? 1, url: url)
                    return samples
                }
                switch outcome {
                case .success(let samples): pcm = samples
                case .failure: return .waiting(reason: .waitingForAsset, retryAfterSeconds: 300)
                }
            } catch let readerError as WindowedAudioReaderError {
                switch readerError.kind {
                case .cannotOpenFile, .unsupportedFormat:
                    return .musicalAnalysisStageFinished(.unsupported)
                case .converterCreationFailed, .readFailed:
                    return .transientFailure(code: "windowReadFailed", message: readerError.detail)
                }
            } catch {
                return .transientFailure(code: "windowReadFailed", message: error.localizedDescription)
            }
        }
        guard !pcm.isEmpty else {
            return .musicalAnalysisStageFinished(.unsupported)
        }

        let analysisAudio = AnalysisAudio(sampleRate: sampleRate, channels: [pcm])
        let result = FullAnalysis.run(analysisAudio)

        let trackId = job.trackId
        let assetRevision = job.assetRevision ?? 1
        let bpm = result.bpm
        // Store the Camelot code ("8A") rather than the human-readable
        // "A minor": the C06 retrieval engine's hard key filter and the
        // shared `HybridRanker.keyFit` both work in Camelot, so persisting
        // the code keeps `discovery_track_analysis.key` directly comparable
        // without re-parsing a prose key name.
        let key = result.key?.camelot.code
        let energy = result.energy.map { Double($0.scalar) }
        let phraseSummary = result.phraseCount > 0 ? "\(result.phraseCount) phrases" : nil
        let completedAt = clock()

        do {
            try commitAnalysis(
                trackId: trackId, assetId: selectedAssetId, assetRevision: assetRevision, bpm: bpm,
                key: key, energy: energy, phraseSummary: phraseSummary, scopeSeconds: scopeSeconds,
                completedAt: completedAt)
        } catch {
            return .transientFailure(code: "analysisCommitFailed", message: error.localizedDescription)
        }
        return .musicalAnalysisStageFinished(.complete)
    }

    /// Plain (non-async) helper so the call to `writer.write` resolves to
    /// GRDB's synchronous overload rather than its `async` one — from
    /// directly inside an `async` function, Swift's overload resolution
    /// prefers the `async` `write<T: Sendable>` overload even though the
    /// closure here needs none of its actor-hopping (a known GRDB/Swift
    /// ambiguity, referenced in `DatabaseWriter`'s own `@_disfavoredOverload`
    /// comments for the sibling `writeWithoutTransaction`).
    private nonisolated func commitAnalysis(
        trackId: Int64, assetId: Int64, assetRevision: Int64, bpm: Double?, key: String?,
        energy: Double?, phraseSummary: String?, scopeSeconds: Double, completedAt: Date
    ) throws {
        try writer.write { db in
            var analysisRow = DiscoveryTrackAnalysis(
                trackId: trackId,
                assetId: assetId,
                assetRevision: assetRevision,
                analysisVersion: DiscoveryPipelineVersion.musicalAnalysis,
                bpm: bpm,
                key: key,
                energy: energy,
                phraseSummary: phraseSummary,
                analysisScopeSeconds: scopeSeconds,
                completedAt: completedAt)
            try analysisRow.upsert(db)
        }
    }

    // MARK: - Shared lookups

    private func fetchAsset(id: Int64) -> Asset? {
        try? writer.read { db in try Asset.fetchOne(db, key: id) }
    }

    private func fetchAssetState(assetId: Int64) -> DiscoveryAssetState? {
        try? writer.read { db in try DiscoveryAssetState.fetchOne(db, key: assetId) }
    }

    /// Whether two optional file-modification instants are the same to
    /// within a second (filesystem mtime granularity varies).
    private static func sameInstant(_ lhs: Date, _ rhs: Date?) -> Bool {
        guard let rhs else { return false }
        return abs(lhs.timeIntervalSince(rhs)) < 1.0
    }

    private func currentStat(asset: Asset) -> (size: Int64, mtime: Date)? {
        let resolved = try? resolver.withResolvedURL(for: asset) { url in self.statFile(url) }
        switch resolved {
        case .success(let stat): return stat
        case .failure, .none: return nil
        }
    }

    /// Observed file size + modification time for change detection (plan §5).
    private nonisolated func statFile(_ url: URL) -> (size: Int64, mtime: Date)? {
        guard
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
            let size = values.fileSize, let mtime = values.contentModificationDate
        else { return nil }
        return (Int64(size), mtime)
    }

    /// Upsert `discovery_asset_state` with the observed validator for the
    /// asset currently being read (plan §4/§5). Best-effort: a stat failure
    /// leaves the row absent, which just disables before/after comparison.
    private nonisolated func recordAssetState(assetId: Int64, revision: Int64, url: URL) {
        guard let stat = statFile(url) else { return }
        try? writer.write { db in
            var row = DiscoveryAssetState(
                assetId: assetId,
                contentRevision: max(1, revision),
                observedSizeBytes: stat.size,
                observedMTime: stat.mtime,
                observedProviderValidator: nil,
                canonicalRevisionSignature: "\(max(1, revision))",
                lastValidatedAt: Date())
            try row.upsert(db)
        }
    }

    private func fetchTrack(id: Int64) -> Track? {
        try? writer.read { db in try Track.fetchOne(db, key: id) }
    }

    /// Real duration when present in core metadata; otherwise read from the
    /// actual media (plan §6: "Determine duration from actual readable
    /// media when metadata is absent"). Throws an `IndexWorkOutcome`
    /// sentinel for a genuinely unreadable asset (mapped to `.unsupported`)
    /// or a transient read problem, so callers reuse the same
    /// terminal/transient classification as every other step.
    /// Duration is normally already known from core metadata for a remote
    /// track (provider-reported at browse/import time — see the plan's
    /// "Duration source" section), so the remote fetch branch below is a
    /// rarely-hit fallback, not the common path.
    private func resolvedDuration(
        jobId: String, asset: Asset, track: Track?, stage: IndexJobRepository.Stage
    ) async throws -> Double {
        let terminal: IndexWorkOutcome =
            stage == .embedding
            ? .embeddingStageFinished(.unsupported)
            : .musicalAnalysisStageFinished(.unsupported)
        if let known = track?.durationSec, known.isFinite, known > 0 { return known }

        if asset.kind == .remote {
            // Reuses the same session `readRemoteWindow` will use for this
            // job's actual window reads right after — never released here,
            // so a (rare) network duration fetch doesn't pay the
            // re-authentication cost twice in one `processNextUnit` call.
            switch await remoteSession(jobId: jobId, asset: asset) {
            case .failure(.reAuthenticationFailed):
                throw IndexWorkOutcome.waiting(reason: .waitingForAsset, retryAfterSeconds: 300)
            case .failure(.unsupportedProvider), .failure(.rangesUnsupported):
                throw terminal
            case .success(let session):
                do {
                    let measured = try await remoteReader.duration(asset: session.avAsset)
                    guard measured.isFinite, measured > 0 else { throw terminal }
                    return measured
                } catch let readerError as WindowedAudioReaderError {
                    switch readerError.kind {
                    case .cannotOpenFile, .unsupportedFormat:
                        throw terminal
                    case .converterCreationFailed, .readFailed:
                        throw IndexWorkOutcome.transientFailure(
                            code: "durationReadFailed", message: readerError.detail)
                    }
                }
            }
        }

        do {
            var measured: Double = 0
            let outcome = try resolver.withResolvedURL(for: asset) { url in
                measured = try reader.duration(url: url)
            }
            guard case .success = outcome else {
                throw IndexWorkOutcome.waiting(reason: .waitingForAsset, retryAfterSeconds: 300)
            }
            guard measured.isFinite, measured > 0 else {
                throw terminal
            }
            return measured
        } catch let readerError as WindowedAudioReaderError {
            switch readerError.kind {
            case .cannotOpenFile, .unsupportedFormat:
                throw terminal
            case .converterCreationFailed, .readFailed:
                throw IndexWorkOutcome.transientFailure(
                    code: "durationReadFailed", message: readerError.detail)
            }
        }
    }

    // MARK: - Remote sparse indexing (docs/plans/remote-sparse-indexing.md)

    private enum RemoteWindowReadOutcome {
        case samples([Float])
        case waitingForAsset
        case unsupported
        case transientFailure(code: String, message: String?)
    }

    /// Reads one window's PCM from `asset` via the job's cached (or freshly
    /// created) `RemoteSparseAssetResolver.Session` — the remote-sparse
    /// counterpart of the local branch's `resolver.withResolvedURL` +
    /// `reader.readWindow`. Never calls `recordAssetState` (no stable local
    /// mtime/size exists for a remote asset to compare against later).
    private func readRemoteWindow(
        jobId: String, asset: Asset, startSeconds: Double, windowSeconds: Double
    ) async -> RemoteWindowReadOutcome {
        switch await remoteSession(jobId: jobId, asset: asset) {
        case .failure(.reAuthenticationFailed):
            return .waitingForAsset
        case .failure(.unsupportedProvider), .failure(.rangesUnsupported):
            return .unsupported
        case .success(let session):
            do {
                let samples = try await remoteReader.readWindow(
                    asset: session.avAsset, startSeconds: startSeconds, windowSeconds: windowSeconds)
                return .samples(samples)
            } catch let readerError as WindowedAudioReaderError {
                switch readerError.kind {
                case .cannotOpenFile, .unsupportedFormat:
                    return .unsupported
                case .converterCreationFailed, .readFailed:
                    return .transientFailure(code: "windowReadFailed", message: readerError.detail)
                }
            } catch {
                return .transientFailure(
                    code: "windowReadFailed", message: error.localizedDescription)
            }
        }
    }

    /// Returns the job's already-open session, or re-authenticates and
    /// opens a fresh one (see `remoteSessions`'s doc for the reuse-across-
    /// windows rationale).
    private func remoteSession(
        jobId: String, asset: Asset
    ) async -> Result<RemoteSparseAssetResolver.Session, RemoteSparseAssetResolver.ResolutionFailure> {
        if let existing = remoteSessions[jobId] { return .success(existing) }
        let result = await RemoteSparseAssetResolver.makeSession(
            for: asset, writer: writer, loaderQueue: remoteLoaderQueue)
        if case .success(let session) = result {
            remoteSessions[jobId] = session
        }
        return result
    }

    /// Idempotent — a no-op when `jobId` has no open session (the common
    /// case for a purely local job, and for a remote job whose session
    /// creation itself failed).
    private func releaseRemoteSession(jobId: String) async {
        guard let session = remoteSessions.removeValue(forKey: jobId) else { return }
        // Real instrumentation for the live-device over-fetch measurement
        // this plan's own validation step calls for (never run this session
        // — see docs/plans/remote-sparse-indexing.md, "Specific risks and
        // the validation step"): compare actual bytes fetched for this
        // track's windows against the theoretical minimum. Grep the device
        // console/Console.app for "RemoteSparseIndexing" (subsystem
        // "guru.parso.tonearm", category "RemoteSparseIndexing") to see the
        // real ratio from actual usage instead.
        let fetched = await session.fetchedBytes()
        let estimated = RemoteIndexingByteEstimate.perTrackBytes
        Self.remoteIndexingLog.info(
            "job=\(jobId, privacy: .public) fetchedBytes=\(fetched, privacy: .public) estimatedBytes=\(estimated, privacy: .public)"
        )
        await session.shutdown()
    }

    private static let remoteIndexingLog = Logger(
        subsystem: "guru.parso.tonearm", category: "RemoteSparseIndexing")
}
#endif
