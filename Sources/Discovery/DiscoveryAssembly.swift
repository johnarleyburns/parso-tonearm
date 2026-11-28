#if !os(watchOS)
import Foundation
import GRDB
import TonearmCore

/// The one application-owned discovery service graph (plan §3: "one
/// application-owned service graph, initialized without a visible view; no
/// per-screen worker/model instances").
///
/// Owns exactly one `IndexJobRepository`, `ImportJobRepository`,
/// `DiscoveryReconciler` and `IndexScheduler` over the single core
/// `DatabaseWriter`. The app creates this once at launch and drives it;
/// nothing here touches UIKit/BackgroundTasks (that is the iOS adapter,
/// `DiscoveryBackgroundController` — kept separate so this graph stays
/// portable and unit-testable).
public actor DiscoveryAssembly {
    public let jobs: IndexJobRepository
    public let importJobs: ImportJobRepository
    public let reconciler: DiscoveryReconciler
    public let scheduler: IndexScheduler
    public let settings: DiscoverySettingsStore

    private let snapshotProvider: @Sendable () -> DiscoverySchedulingSnapshot
    private var isDraining = false

    /// The reason the scheduler was last unable to make progress — a real
    /// `IndexPolicy` gate that tripped either before any job was claimed
    /// (`.blocked`) or mid-run (`.jobPreempted`). `nil` once a job actually
    /// completes or the queue is genuinely idle (nothing eligible, not a
    /// policy block), so a stale reason never lingers once real progress
    /// resumes.
    public private(set) var lastBlockReason: IndexBlockReason?
    /// Real thermal numbers behind `lastBlockReason` when it is a thermal reason — `nil`
    /// otherwise.
    public private(set) var lastThermalDiagnostic: ThermalDiagnostic?

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
    public init(
        writer: any DatabaseWriter,
        snapshotProvider: @escaping @Sendable () -> DiscoverySchedulingSnapshot
    ) {
        let jobs = IndexJobRepository(writer: writer)
        self.jobs = jobs
        self.importJobs = ImportJobRepository(writer: writer)
        let settings = DiscoverySettingsStore(writer: writer)
        self.settings = settings
        self.reconciler = DiscoveryReconciler(
            writer: writer, jobs: jobs,
            remoteIndexingEnabled: { (try? await settings.isRemoteIndexingEnabled()) ?? true })
        let worker = BoundedIndexWorker(writer: writer)
        self.scheduler = IndexScheduler(jobs: jobs, worker: worker)
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
        let remoteIndexingEnabled = (try? await settings.isRemoteIndexingEnabled()) ?? true
        let remoteIndexingWiFiOnly = (try? await settings.isRemoteIndexingWiFiOnly()) ?? true
        let runtime = (try? await settings.runtime()) ?? DiscoveryRuntime(id: 1)
        let currentlyIndexingTrack = try? await jobs.currentlyRunningTrack(
            pipelineVersion: DiscoveryPipelineVersion.pipeline)
        let recentCompletionRate = try? await jobs.recentCompletionRate(
            pipelineVersion: DiscoveryPipelineVersion.pipeline)
        return IndexStatusSnapshot(
            coverage: coverage,
            isPaused: paused,
            isChargingOnly: chargingOnly,
            isRemoteIndexingEnabled: remoteIndexingEnabled,
            isRemoteIndexingWiFiOnly: remoteIndexingWiFiOnly,
            runtime: runtime,
            schedulerBlockReason: lastBlockReason,
            // Recomputed fresh on every status read (not `lastThermalDiagnostic`,
            // which is only updated once per `drainQueue()` tick — up to 20s
            // apart) so the "Resuming in Ns" countdown actually counts down as
            // the status screen polls it, instead of freezing between ticks.
            thermalDiagnostic: lastBlockReason.flatMap {
                Self.thermalDiagnostic(for: $0, snapshotProvider: snapshotProvider)
            },
            currentlyIndexingTrack: currentlyIndexingTrack,
            recentCompletionRate: recentCompletionRate)
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
        // A crash/force-quit mid-job can leave a remote-sparse session's
        // ephemeral temp directory behind (its own `shutdown()` never ran)
        // — swept here so nothing from that path survives across launches.
        RemoteSparseAssetResolver.sweepStaleEphemeralDirectories()
        let staleLeases = try await jobs.recoverStaleLeasesAtLaunch()
        let interruptedImports = try await importJobs.recoverInterruptedAtLaunch()
        // Migrate pre-v22 remote assets before eligibility reconciliation. This
        // gives older/onboarded rows the provider node reference needed for
        // remote sampling and BPM/key analysis.
        _ = await reconciler.backfillRemoteNodeReferences()
        // Before creating any new jobs, drop existing ones for tracks that
        // are not (and were never) eligible under the "downloaded/on-device
        // only" rule below — otherwise an install from before this change
        // keeps every one of those jobs sitting in `waitingForAsset` forever.
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
                lastThermalDiagnostic = nil
                return completed
            case .blocked(let reason):
                lastBlockReason = reason
                lastThermalDiagnostic = Self.thermalDiagnostic(for: reason, snapshotProvider: snapshotProvider)
                return completed
            case .jobCompleted:
                lastBlockReason = nil
                lastThermalDiagnostic = nil
                completed += 1
            case .jobWaiting, .jobFailed:
                // A job was actually claimed and run this tick, so whatever
                // previously blocked the scheduler no longer applies — clear
                // it rather than leaving a stale reason from an earlier tick.
                lastBlockReason = nil
                lastThermalDiagnostic = nil
                // The repository moved the job to a future nextAttemptAt;
                // the next tick resolves to .idle/.blocked and we exit.
                continue
            case .jobPreempted(_, let reason):
                // A policy gate tripped mid-run; the job was released back to
                // `.queued` untouched. Record the reason — the next tick's
                // initial decision will very likely re-block on it too — but
                // keep draining in case a higher-priority job is unaffected.
                lastBlockReason = reason
                lastThermalDiagnostic = Self.thermalDiagnostic(for: reason, snapshotProvider: snapshotProvider)
                continue
            }
        }
        return completed
    }

    private static func thermalDiagnostic(
        for reason: IndexBlockReason, snapshotProvider: @Sendable () -> DiscoverySchedulingSnapshot
    ) -> ThermalDiagnostic? {
        guard reason == .thermalFair || reason == .thermalSerious || reason == .thermalCritical
        else { return nil }
        let s = snapshotProvider()
        return ThermalDiagnostic(state: s.thermalState, continuousNominalSeconds: s.continuousNominalSeconds)
    }
}
#endif
