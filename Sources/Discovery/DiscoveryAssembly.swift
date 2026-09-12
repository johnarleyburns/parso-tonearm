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
    private var isDraining = false

    public struct LaunchRecovery: Equatable, Sendable {
        public let resetIndexLeases: Int
        public let resetImportJobs: Int
        public let bootstrappedTracks: Int
        public let drainedOutbox: Int
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
        executionContext: @escaping @Sendable () -> ModelManager.ExecutionContext = { .foreground }
    ) {
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
            runtime: runtime)
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
        let bootstrapped = try await reconciler.bootstrapAllTracks()
        let outbox = try await reconciler.processOutbox()
        return LaunchRecovery(
            resetIndexLeases: staleLeases.resetJobCount,
            resetImportJobs: interruptedImports,
            bootstrappedTracks: bootstrapped,
            drainedOutbox: outbox)
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
            case .idle, .blocked:
                return completed
            case .jobCompleted:
                completed += 1
            case .jobWaiting, .jobFailed, .jobPreempted:
                // The repository moved the job to a future nextAttemptAt (or
                // back to queued for a preempt with a policy gate that will
                // also block the next initial decision); either way the next
                // tick resolves to .idle/.blocked and we exit.
                continue
            }
        }
        return completed
    }
}
#endif
