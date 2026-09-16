#if !os(watchOS)
import Foundation
import GRDB
import TonearmCore

/// The one application-owned discovery service graph (plan §3: "one
/// application-owned service graph, initialized without a visible view; no
/// per-screen worker/model instances").
///
/// Owns exactly one `IndexJobRepository`, `ImportJobRepository`,
/// `DiscoveryReconciler`, `ModelManager` and `IndexScheduler` over the single
/// core `DatabaseWriter`. The app creates this once at launch and drives it;
/// nothing here touches UIKit/BackgroundTasks (that is the iOS adapter,
/// `DiscoveryBackgroundController`, C05 — kept separate so this graph stays
/// portable and unit-testable).
public actor DiscoveryAssembly {
    public let jobs: IndexJobRepository
    public let importJobs: ImportJobRepository
    public let reconciler: DiscoveryReconciler
    public let models: ModelManager
    public let scheduler: IndexScheduler
    public let settings: DiscoverySettingsStore
    /// The C06 unified-retrieval derived vector cache (rebuildable from
    /// `discovery_embedding` rows).
    public let vectorIndex: VectorIndex
    /// The one retrieval engine shared by search, similar-track search, saved
    /// searches and auto-playlist candidate retrieval (plan §9).
    public let search: SearchService

    private let snapshotProvider: @Sendable () -> DiscoverySchedulingSnapshot
    private let modelDownloadProgressProvider: @Sendable () -> ModelDownloadProgress?
    private let modelDownloadErrorProvider: @Sendable () -> String?
    private let modelDownloadTagDebugProvider: @Sendable () -> String?
    /// Unlike the other model-download providers above, this one is NOT
    /// gated on `!modelAvailable` — the Sound Index screen's "Models"
    /// section is meant to stay useful even once everything resolves (so a
    /// debugging session can confirm "yes, both artifacts are now found"),
    /// not disappear the moment the problem it was added to diagnose goes
    /// away.
    private let modelDiagnosticsProvider: @Sendable () -> ModelDiagnosticsDetail?
    private var isDraining = false

    /// The reason the scheduler was last unable to make progress — a real
    /// `IndexPolicy` gate that tripped either before any job was claimed
    /// (`.blocked`) or mid-run (`.jobPreempted`), as reported by the most
    /// recent `drainQueue()` tick. `nil` once a job actually completes or the
    /// queue is genuinely idle (nothing eligible, not a policy block), so a
    /// stale reason never lingers once real progress resumes.
    ///
    /// This exists so the status surface can tell "stuck on thermal/battery/
    /// playback/background-grant" apart from "stuck on nothing in
    /// particular" — a job blocked before being claimed stays `.queued`
    /// forever (plan §6: most policy gates are scheduler-level, not a
    /// persisted per-job state), so `IndexJobRepository.coverage` alone
    /// cannot distinguish real progress from a queue that is silently wedged.
    public private(set) var lastBlockReason: IndexBlockReason?

    public struct LaunchRecovery: Equatable, Sendable {
        public let resetIndexLeases: Int
        public let resetImportJobs: Int
        public let bootstrappedTracks: Int
        public let drainedOutbox: Int
        /// Pre-existing `waitingForAsset` jobs removed because every asset
        /// on that track is remote/cloud and was never downloaded — see
        /// `DiscoveryReconciler.pruneJobsForUndownloadedTracks()`.
        public let prunedUndownloadedTracks: Int
    }

    /// - Parameters:
    ///   - writer: the single core DB writer (`LibraryStore.dbQueue`).
    ///   - snapshotProvider: gathers live power/thermal/app-state for the
    ///     scheduler policy. Supplied by the iOS adapter in production; a
    ///     deterministic fake in tests. No default — the caller must decide
    ///     (plan §6 forbids fabricated battery/thermal values).
    ///   - modelResourceProvider: resolves the CLAP encoder/mel-filterbank
    ///     URLs once acquired (ODR/bundle). Defaults to "unavailable", so
    ///     indexing parks in `waitingForModel` until real resources resolve.
    ///   - executionContext: `.foreground` / `.background` for compute-unit
    ///     selection (plan §7).
    public init(
        writer: any DatabaseWriter,
        snapshotProvider: @escaping @Sendable () -> DiscoverySchedulingSnapshot,
        modelResourceProvider: @escaping @Sendable () -> ModelManager.Resources = { .unavailable },
        executionContext: @escaping @Sendable () -> ModelManager.ExecutionContext = { .foreground },
        modelDownloadProgressProvider: @escaping @Sendable () -> ModelDownloadProgress? = { nil },
        modelDownloadErrorProvider: @escaping @Sendable () -> String? = { nil },
        modelDownloadTagDebugProvider: @escaping @Sendable () -> String? = { nil },
        modelDiagnosticsProvider: @escaping @Sendable () -> ModelDiagnosticsDetail? = { nil }
    ) {
        self.modelDownloadProgressProvider = modelDownloadProgressProvider
        self.modelDownloadErrorProvider = modelDownloadErrorProvider
        self.modelDownloadTagDebugProvider = modelDownloadTagDebugProvider
        self.modelDiagnosticsProvider = modelDiagnosticsProvider
        let jobs = IndexJobRepository(writer: writer)
        self.jobs = jobs
        self.importJobs = ImportJobRepository(writer: writer)
        self.reconciler = DiscoveryReconciler(writer: writer, jobs: jobs)
        let models = ModelManager(resourceProvider: modelResourceProvider)
        self.models = models
        let worker = BoundedIndexWorker(
            writer: writer, jobs: jobs, models: models, executionContext: executionContext)
        self.scheduler = IndexScheduler(jobs: jobs, worker: worker)
        self.settings = DiscoverySettingsStore(writer: writer)
        let vectorIndex = VectorIndex(writer: writer)
        self.vectorIndex = vectorIndex
        self.search = SearchService(
            writer: writer, index: vectorIndex, models: models,
            executionContext: { executionContext() })
        self.snapshotProvider = snapshotProvider
    }

    /// True when at least one job is queued/running or parked in a waiting
    /// state — i.e. iOS background processing time could still make progress
    /// (plan §7: "Submit a BGProcessingTaskRequest when pending local work
    /// exists").
    public func pendingWorkExists() async throws -> Bool {
        let coverage = try await jobs.coverage(pipelineVersion: DiscoveryPipelineVersion.pipeline)
        return coverage.queuedOrRunning + coverage.waiting > 0
    }

    /// A consistent snapshot of the persisted indexing state for the status
    /// surface (plan §10). Gathered off the main actor.
    public func statusSnapshot() async throws -> IndexStatusSnapshot {
        let coverage = try await jobs.coverage(pipelineVersion: DiscoveryPipelineVersion.pipeline)
        let paused = (try? await settings.isPaused()) ?? false
        let chargingOnly = (try? await settings.isChargingOnly()) ?? false
        let modelAvailable = await models.isModelResourceAvailable()
        let runtime = (try? await settings.runtime()) ?? DiscoveryRuntime(id: 1)
        return IndexStatusSnapshot(
            coverage: coverage,
            isPaused: paused,
            isChargingOnly: chargingOnly,
            modelResourceAvailable: modelAvailable,
            modelDownloadProgress: modelAvailable ? nil : modelDownloadProgressProvider(),
            modelDownloadError: modelAvailable ? nil : modelDownloadErrorProvider(),
            modelDownloadTagDebug: modelAvailable ? nil : modelDownloadTagDebugProvider(),
            modelDiagnostics: modelDiagnosticsProvider(),
            runtime: runtime,
            schedulerBlockReason: lastBlockReason)
    }

    /// "Retry failed" status action (plan §10 action 4). Returns the count of
    /// re-queued jobs; kicks a drain so they start immediately if policy allows.
    @discardableResult
    public func retryFailedJobs() async throws -> Int {
        let count = try await jobs.retryAllFailed(pipelineVersion: DiscoveryPipelineVersion.pipeline)
        if count > 0 { _ = try? await drainQueue() }
        return count
    }

    /// Run once per process launch, BEFORE the scheduler starts claiming
    /// (plan §7: "At process launch, reset stale running leases from the
    /// prior process to queued"). Also recovers interrupted import jobs,
    /// bootstraps every pre-existing core track and drains the outbox.
    @discardableResult
    public func recoverAndReconcileAtLaunch() async throws -> LaunchRecovery {
        let staleLeases = try await jobs.recoverStaleLeasesAtLaunch()
        let interruptedImports = try await importJobs.recoverInterruptedAtLaunch()
        // Before creating any new jobs, drop existing ones for tracks that
        // are not (and were never) eligible under the "downloaded/on-device
        // only" rule below — otherwise an install from before this change
        // keeps every one of those jobs sitting in `waitingForAsset` forever
        // (real report: "2631 tracks waiting on their audio file").
        let pruned = try await reconciler.pruneJobsForUndownloadedTracks()
        let bootstrapped = try await reconciler.bootstrapAllTracks()
        let outbox = try await reconciler.processOutbox()
        return LaunchRecovery(
            resetIndexLeases: staleLeases.resetJobCount,
            resetImportJobs: interruptedImports,
            bootstrappedTracks: bootstrapped,
            drainedOutbox: outbox,
            prunedUndownloadedTracks: pruned)
    }

    /// Drain the outbox, then run scheduler ticks until the queue is idle or
    /// policy blocks further work (or `maxTicks` is hit — a safety bound, not
    /// an expected stop). Re-entrant calls are coalesced: a second concurrent
    /// `drainQueue` returns immediately while the first is running, so
    /// competing foreground/background wake-ups never spawn a duplicate
    /// drain (plan §7: "Background and foreground callbacks share the same
    /// scheduler, preventing duplicate workers").
    @discardableResult
    public func drainQueue(maxTicks: Int = 1_000) async throws -> Int {
        guard !isDraining else { return 0 }
        isDraining = true
        defer { isDraining = false }

        try await reconciler.processOutbox()

        var completed = 0
        for _ in 0..<maxTicks {
            let outcome = try await scheduler.tick(snapshotProvider: snapshotProvider)
            switch outcome {
            case .idle:
                // Genuinely nothing eligible right now (not a policy block) —
                // clear any stale reason so the status surface does not keep
                // blaming a condition that no longer applies.
                lastBlockReason = nil
                return completed
            case .blocked(let reason):
                lastBlockReason = reason
                return completed
            case .jobCompleted:
                lastBlockReason = nil
                completed += 1
            case .jobWaiting, .jobFailed:
                // A job was actually claimed and run this tick, so whatever
                // previously blocked the scheduler no longer applies — clear
                // it rather than leaving a stale reason from an earlier tick.
                lastBlockReason = nil
                // The repository moved the job to a future nextAttemptAt;
                // the next tick resolves to .idle/.blocked and we exit.
                continue
            case .jobPreempted(_, let reason):
                // A policy gate tripped mid-run; the job was released back to
                // `.queued` untouched. Record the reason — the next tick's
                // initial decision will very likely re-block on it too — but
                // keep draining in case a higher-priority job is unaffected.
                lastBlockReason = reason
                continue
            }
        }
        return completed
    }
}
#endif
