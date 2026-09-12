#if !os(watchOS)
import Foundation

/// A `BGProcessingTaskRequest` reduced to the fields the discovery subsystem
/// actually sets (IMPLEMENT_CLAP_PLAN.md §7). The iOS adapter maps this to a
/// real `BGProcessingTaskRequest`; tests capture it directly.
public struct BackgroundProcessingRequest: Equatable, Sendable {
    public var identifier: String
    public var requiresExternalPower: Bool
    public var requiresNetworkConnectivity: Bool
    public var earliestBeginDate: Date?

    public init(
        identifier: String,
        requiresExternalPower: Bool = true,
        requiresNetworkConnectivity: Bool = false,
        earliestBeginDate: Date? = nil
    ) {
        self.identifier = identifier
        self.requiresExternalPower = requiresExternalPower
        self.requiresNetworkConnectivity = requiresNetworkConnectivity
        self.earliestBeginDate = earliestBeginDate
    }
}

/// One granted background execution slot (a real `BGProcessingTask` in the
/// app; a fake in tests). The controller registers an expiration handler and
/// completes it exactly once (plan §7: "completes the BG task exactly once").
public protocol BackgroundTaskInvocation: AnyObject, Sendable {
    var identifier: String { get }
    func setExpirationHandler(_ handler: @escaping @Sendable () -> Void)
    func complete(success: Bool)
}

/// The `BGTaskScheduler` seam (plan §11 C05: "Use injectable
/// BackgroundTaskScheduling ... to test registration, request coalescing,
/// expiration during window/commit, completion exactly once"). The iOS
/// adapter wraps `BGTaskScheduler.shared`; tests inject a fake that records
/// submitted requests and can invoke the launch handler on demand.
public protocol BackgroundTaskScheduling: Sendable {
    /// Register a launch handler for `identifier`. Returns whether the
    /// system accepted the registration.
    func register(
        identifier: String,
        launchHandler: @escaping @Sendable (any BackgroundTaskInvocation) -> Void
    ) -> Bool

    /// Submit (and coalesce by identifier — the system replaces a pending
    /// request for the same identifier) a processing request.
    func submit(_ request: BackgroundProcessingRequest) throws

    /// Cancel any pending request for `identifier`.
    func cancel(identifier: String)
}

/// Owns the iOS BackgroundTasks lifecycle for discovery indexing: it
/// registers the processing-task handler, submits/coalesces
/// `BGProcessingTaskRequest`s when pending local work exists, and — under a
/// granted task — drives one bounded `DiscoveryAssembly.drainQueue()` pass,
/// honours expiration by dropping the background grant so the shared
/// scheduler checkpoints and stops, then completes the task exactly once and
/// resubmits any remaining work (plan §7).
///
/// This type owns NO UIKit/BackgroundTasks symbols — everything platform
/// lives behind `BackgroundTaskScheduling` / `BackgroundTaskInvocation`, so
/// the full C05 fault-injection matrix runs in `swift test` against the real
/// `IndexJobRepository`/`BoundedIndexWorker` with a deterministic fake
/// encoder (plan §3: "Keep BackgroundTasks/UIKit behind platform fences and
/// out of portable persistence tests").
///
/// `DiscoveryRuntimeController` (the app adapter) retains only launch
/// sequencing + the foreground tick loop and delegates every background
/// concern here.
public actor DiscoveryBackgroundController {
    public let identifier: String

    private let assembly: DiscoveryAssembly
    private let settings: DiscoverySettingsStore
    private let scheduler: any BackgroundTaskScheduling
    private let pipelineVersion: Int
    private let earliestBeginInterval: TimeInterval
    private let now: @Sendable () -> Date

    /// Called immediately before a granted background drain begins — the app
    /// flips its scheduling sampler to `appState = .background` +
    /// `hasBackgroundProcessingGrant = true` here (never fabricated: this IS
    /// a real granted task). Called again (idempotent) when the drain ends or
    /// the task expires, dropping the grant so the shared `IndexPolicy` gate
    /// stops the worker at the next window boundary.
    private let onBackgroundGrantChanged: @Sendable (_ granted: Bool) -> Void

    private var didRegister = false
    private var activeDrain: Task<Int, Never>?

    public init(
        assembly: DiscoveryAssembly,
        settings: DiscoverySettingsStore,
        scheduler: any BackgroundTaskScheduling,
        identifier: String = "guru.parso.tonearm.discovery-index",
        pipelineVersion: Int = DiscoveryPipelineVersion.pipeline,
        earliestBeginInterval: TimeInterval = 15 * 60,
        now: @escaping @Sendable () -> Date = { Date() },
        onBackgroundGrantChanged: @escaping @Sendable (_ granted: Bool) -> Void = { _ in }
    ) {
        self.assembly = assembly
        self.settings = settings
        self.scheduler = scheduler
        self.identifier = identifier
        self.pipelineVersion = pipelineVersion
        self.earliestBeginInterval = earliestBeginInterval
        self.now = now
        self.onBackgroundGrantChanged = onBackgroundGrantChanged
    }

    // MARK: - Registration (call once, before launch completes)

    @discardableResult
    public func register() -> Bool {
        guard !didRegister else { return true }
        let this = self
        didRegister = scheduler.register(identifier: identifier) { invocation in
            Task { await this.run(invocation) }
        }
        return didRegister
    }

    // MARK: - Request submission / coalescing

    /// Submit a `BGProcessingTaskRequest` iff pending local work exists
    /// (plan §7). Submitting the same identifier coalesces with / replaces
    /// any prior pending request, so repeated calls never leave two requests
    /// outstanding. Records the submission result + next-scheduled time in
    /// `discovery_runtime` without losing jobs on failure.
    public func submitPendingWorkRequestIfNeeded() async {
        let pending = (try? await assembly.pendingWorkExists()) ?? false
        guard pending else { return }

        let earliest = now().addingTimeInterval(earliestBeginInterval)
        let request = BackgroundProcessingRequest(
            identifier: identifier,
            requiresExternalPower: true,
            requiresNetworkConnectivity: false,
            earliestBeginDate: earliest)

        let result: String
        do {
            try scheduler.submit(request)
            result = "submitted"
        } catch {
            result = "error: \(error.localizedDescription)"
        }
        try? await settings.updateRuntime(
            lastBackgroundSubmissionResult: result,
            lastBackgroundSubmissionAt: now(),
            nextScheduledAt: earliest)
    }

    public func cancelPendingRequest() {
        scheduler.cancel(identifier: identifier)
    }

    // MARK: - Granted-task execution

    /// Run one bounded drain under a granted processing task. Registers the
    /// expiration handler first (plan §7: "Register an expiration handler
    /// immediately"), drains, persists telemetry, resubmits remaining work,
    /// and completes the task exactly once.
    public func run(_ invocation: any BackgroundTaskInvocation) async {
        let latch = CompletionLatch()
        let this = self
        invocation.setExpirationHandler {
            Task { await this.handleExpiration() }
        }

        onBackgroundGrantChanged(true)

        let capturedAssembly = assembly
        let drain = Task<Int, Never> {
            (try? await capturedAssembly.drainQueue()) ?? 0
        }
        activeDrain = drain
        let completed = await drain.value
        let expired = drain.isCancelled
        activeDrain = nil

        onBackgroundGrantChanged(false)

        let coverage = try? await assembly.jobs.coverage(pipelineVersion: pipelineVersion)
        try? await settings.updateRuntime(
            lastRunAt: now(),
            lastStopReason: expired
                ? "background: expired mid-drain, \(completed) completed (progress saved)"
                : "background: \(completed) completed",
            lastSuccessfulWorkAt: completed > 0 ? now() : nil,
            lastError: .some(nil),
            coverageSnapshot: coverage.map { "\($0.complete) / \($0.total)" })

        await submitPendingWorkRequestIfNeeded()

        if latch.claim() {
            invocation.complete(success: !expired)
        }
    }

    /// Expiration: drop the background grant so the shared `IndexPolicy`
    /// blocks the next window, and cancel the drain task. Durable window
    /// checkpoints are owned by `BoundedIndexWorker` and already persisted —
    /// the job returns to `queued` and resumes next launch/grant (plan §7).
    private func handleExpiration() {
        onBackgroundGrantChanged(false)
        activeDrain?.cancel()
    }
}

/// Guarantees the BG task is completed at most once even if the normal
/// finish and an expiration race.
final class CompletionLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
#endif
