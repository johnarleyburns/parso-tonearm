#if !os(watchOS)
import Foundation
import GRDB
import os.log
import ParsoAudioAnalysis
import StarterGeneratorSupport
import TonearmCore

/// The musical-analysis implementation of `IndexJobExecuting`: bounded
/// windowed reads (`WindowedAudioReader`) and the shared BPM/key/energy
/// analyzers (`ParsoAudioAnalysis.LeanAnalysis`) over a bounded sample — never
/// a whole-file decode (plan §6). `LeanAnalysis` computes only what the
/// BPM/Camelot-compatible mix/queue logic needs, skipping `FullAnalysis`'s
/// loudness/phrase/waveform stages (all three unread downstream).
///
/// Only ONE analysis job executes at a time (the scheduler already only ever
/// has one worker/one claimed job in flight), and every heavy call here
/// (`readWindow`, `LeanAnalysis.run`) runs on the caller's (non-MainActor)
/// task, never main.
public actor BoundedIndexWorker: IndexJobExecuting {
    /// Musical analysis samples at most this many seconds from the track
    /// midpoint (plan §6: "up to 60 seconds from the track midpoint, shorter
    /// files in full").
    public static let musicalAnalysisMaxSeconds: Double = 60

    private let writer: any DatabaseWriter
    private let reader: WindowedAudioReader
    private let resolver: AnalysisAssetResolver
    private let clock: () -> Date
    /// Remote sparse indexing (docs/plans/remote-sparse-indexing.md) — a
    /// `.remote` asset's PCM comes from here instead of
    /// `resolver`/`reader`. See `remoteSession(jobId:asset:)` for lifecycle.
    private let remoteReader: AssetBackedWindowedAudioReader
    private let remoteLoaderQueue = DispatchQueue(label: "guru.parso.tonearm.discovery.remoteLoaders")
    /// One ephemeral `RemoteSparseAssetResolver.Session` per in-flight
    /// remote job, keyed by job id, reused across that job's analysis reads.
    private var remoteSessions: [String: RemoteSparseAssetResolver.Session] = [:]
    /// One `LocalAnalysisReaderSession` per in-flight local job, keyed by job id.
    private var localSessions: [String: LocalAnalysisReaderSession] = [:]

    public init(
        writer: any DatabaseWriter,
        reader: WindowedAudioReader = WindowedAudioReader(),
        resolver: AnalysisAssetResolver = AnalysisAssetResolver(),
        remoteReader: AssetBackedWindowedAudioReader = AssetBackedWindowedAudioReader(),
        clock: @escaping () -> Date = Date.init
    ) {
        self.writer = writer
        self.reader = reader
        self.resolver = resolver
        self.remoteReader = remoteReader
        self.clock = clock
    }

    public func processNextUnit(job: DiscoveryIndexJob, leaseToken: String) async -> IndexWorkOutcome {
        guard job.musicalAnalysisStageState == .pending || job.musicalAnalysisStageState == .running
        else {
            return .musicalAnalysisStageFinished(job.musicalAnalysisStageState)
        }
        return await processMusicalAnalysis(job: job)
    }

    // MARK: - Musical analysis stage

    /// Musical analysis is the last stage that ever needs the asset — the
    /// remote or local session (if any) is released here regardless of outcome.
    private func processMusicalAnalysis(job: DiscoveryIndexJob) async -> IndexWorkOutcome {
        let outcome = await processMusicalAnalysisOutcome(job: job)
        await releaseRemoteSession(jobId: job.id)
        releaseLocalSession(jobId: job.id)
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
                jobId: job.id, asset: asset, track: track)
        } catch let outcome as IndexWorkOutcome {
            return outcome
        } catch {
            return .transientFailure(code: "durationReadFailed", message: error.localizedDescription)
        }

        let scopeSeconds = min(Self.musicalAnalysisMaxSeconds, duration)
        let startSeconds = max(0, duration / 2 - scopeSeconds / 2)

        let midpointAudio: AnalysisAudio
        switch await readAnalysisWindow(
            job: job, asset: asset, selectedAssetId: selectedAssetId, startSeconds: startSeconds,
            windowSeconds: scopeSeconds)
        {
        case .success(let audio): midpointAudio = audio
        case .failure(let outcome): return outcome
        }

        let result = LeanAnalysis.run(midpointAudio)

        let trackId = job.trackId
        let assetRevision = job.assetRevision ?? 1
        let bpm = result.bpm
        // Store the Camelot code ("8A") rather than the human-readable
        // "A minor": BPM/Key filtering and the mix planner both work in
        // Camelot, so persisting the code keeps `discovery_track_analysis.key`
        // directly comparable without re-parsing a prose key name.
        let key = result.key?.camelot.code
        let energy = result.energy.map { Double($0.scalar) }
        let completedAt = clock()

        do {
            try commitAnalysis(
                trackId: trackId, assetId: selectedAssetId, assetRevision: assetRevision, bpm: bpm,
                key: key, energy: energy, phraseSummary: nil, scopeSeconds: scopeSeconds,
                completedAt: completedAt)
        } catch {
            return .transientFailure(code: "analysisCommitFailed", message: error.localizedDescription)
        }
        return .musicalAnalysisStageFinished(.complete)
    }

    /// One bounded PCM window as `AnalysisAudio`, local or remote, sharing the exact read/error
    /// handling the musical-analysis stage already used for its single midpoint window.
    private func readAnalysisWindow(
        job: DiscoveryIndexJob, asset: Asset, selectedAssetId: Int64, startSeconds: Double,
        windowSeconds: Double
    ) async -> Result<AnalysisAudio, IndexWorkOutcome> {
        let pcm: [Float]
        let sampleRate: Double
        if asset.kind == .remote {
            sampleRate = remoteReader.targetSampleRate
            switch await readRemoteWindow(
                jobId: job.id, asset: asset, startSeconds: startSeconds, windowSeconds: windowSeconds)
            {
            case .samples(let samples): pcm = samples
            case .waitingForAsset:
                return .failure(.waiting(reason: .waitingForAsset, retryAfterSeconds: 300))
            case .unsupported: return .failure(.musicalAnalysisStageFinished(.unsupported))
            case .transientFailure(let code, let message):
                return .failure(.transientFailure(code: code, message: message))
            }
        } else {
            sampleRate = reader.targetSampleRate
            let session: LocalAnalysisReaderSession
            do {
                guard let opened = try localSession(jobId: job.id, asset: asset) else {
                    return .failure(.waiting(reason: .waitingForAsset, retryAfterSeconds: 300))
                }
                session = opened
            } catch {
                return .failure(
                    mapLocalSessionError(error, terminal: .musicalAnalysisStageFinished(.unsupported)))
            }
            do {
                pcm = try session.readWindow(startSeconds: startSeconds, windowSeconds: windowSeconds)
                recordAssetState(assetId: selectedAssetId, revision: job.assetRevision ?? 1, url: session.url)
            } catch {
                return .failure(
                    mapLocalSessionError(error, terminal: .musicalAnalysisStageFinished(.unsupported)))
            }
        }
        guard !pcm.isEmpty else { return .failure(.musicalAnalysisStageFinished(.unsupported)) }
        return .success(AnalysisAudio(sampleRate: sampleRate, channels: [pcm]))
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

    /// Observed file size + modification time for change detection (plan §5).
    private nonisolated func statFile(_ url: URL) -> (size: Int64, mtime: Date)? {
        guard
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
            let size = values.fileSize, let mtime = values.contentModificationDate
        else { return nil }
        return (Int64(size), mtime)
    }

    /// Upsert `discovery_asset_state` with the observed validator for the
    /// asset currently being read. Best-effort: a stat failure leaves the row
    /// absent.
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
        jobId: String, asset: Asset, track: Track?
    ) async throws -> Double {
        let terminal: IndexWorkOutcome = .musicalAnalysisStageFinished(.unsupported)
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

    /// Returns the job's already-open local session, or resolves and opens a fresh one (see
    /// `localSessions`'s doc for the reuse-across-windows rationale — the same one
    /// `remoteSession(jobId:asset:)` follows for a remote asset). `nil` means nothing local/
    /// cached exists yet (maps to `.waiting`, same as `withResolvedURL`'s `.failure` used to);
    /// a thrown `WindowedAudioReaderError` means the file itself couldn't be opened/converted.
    private func localSession(jobId: String, asset: Asset) throws -> LocalAnalysisReaderSession? {
        if let existing = localSessions[jobId] { return existing }
        guard let (url, release) = resolver.resolveAndHold(for: asset) else { return nil }
        do {
            let session = try reader.openSession(url: url, release: release)
            localSessions[jobId] = session
            return session
        } catch {
            release()
            throw error
        }
    }

    /// Idempotent — a no-op when `jobId` has no open session (the common case for a purely
    /// remote job, and for a local job whose session creation itself failed).
    private func releaseLocalSession(jobId: String) {
        localSessions.removeValue(forKey: jobId)?.close()
    }

    /// Shared error mapping for both `localSession(jobId:asset:)` (opening the file) and a
    /// session's own `readWindow` (reading from it already open) — the same classification
    /// `WindowedAudioReaderError` always got at either call site before this session existed.
    private func mapLocalSessionError(_ error: Error, terminal: IndexWorkOutcome) -> IndexWorkOutcome {
        guard let readerError = error as? WindowedAudioReaderError else {
            return .transientFailure(code: "windowReadFailed", message: error.localizedDescription)
        }
        switch readerError.kind {
        case .cannotOpenFile, .unsupportedFormat:
            return terminal
        case .converterCreationFailed, .readFailed:
            return .transientFailure(code: "windowReadFailed", message: readerError.detail)
        }
    }

    private static let remoteIndexingLog = Logger(
        subsystem: "guru.parso.tonearm", category: "RemoteSparseIndexing")
}
#endif
