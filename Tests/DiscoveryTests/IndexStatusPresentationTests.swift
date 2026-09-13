#if !os(watchOS)
import XCTest

@testable import TonearmCore
@testable import TonearmDiscovery

/// C07 status-surface view-model mapping (IMPLEMENT_CLAP_PLAN.md §10): the
/// distinct response states must map to distinct display, and diagnostics
/// export must stay redacted (aggregate counts only, no track identity).
final class IndexStatusPresentationTests: XCTestCase {
    private func coverage(
        total: Int, complete: Int = 0, queuedOrRunning: Int = 0, waiting: Int = 0, failed: Int = 0
    ) -> IndexJobRepository.Coverage {
        IndexJobRepository.Coverage(
            total: total, complete: complete, queuedOrRunning: queuedOrRunning,
            waiting: waiting, failed: failed)
    }

    private func snapshot(
        _ coverage: IndexJobRepository.Coverage,
        paused: Bool = false, chargingOnly: Bool = false, modelAvailable: Bool = true,
        runtime: DiscoveryRuntime = DiscoveryRuntime(id: 1),
        blockReason: IndexBlockReason? = nil
    ) -> IndexStatusSnapshot {
        IndexStatusSnapshot(
            coverage: coverage, isPaused: paused, isChargingOnly: chargingOnly,
            modelResourceAvailable: modelAvailable, runtime: runtime,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            schedulerBlockReason: blockReason)
    }

    func testEmptyLibrary() {
        let p = IndexStatusPresentation.make(from: snapshot(coverage(total: 0)))
        XCTAssertEqual(p.phase, .emptyLibrary)
        XCTAssertEqual(p.headline, "Sound index: not started")
        XCTAssertFalse(p.showsBanner)
        XCTAssertFalse(p.canPause)
        XCTAssertFalse(p.canResume)
    }

    func testUpToDate() {
        let p = IndexStatusPresentation.make(from: snapshot(coverage(total: 1042, complete: 1042)))
        XCTAssertEqual(p.phase, .upToDate)
        XCTAssertEqual(p.headline, "Sound index: 1,042 / 1,042 tracks")
        XCTAssertEqual(p.fractionComplete, 1.0)
        XCTAssertTrue(p.showsBanner)
        XCTAssertFalse(p.canPause)
    }

    func testIndexingInProgress() {
        let p = IndexStatusPresentation.make(
            from: snapshot(coverage(total: 1042, complete: 238, queuedOrRunning: 804)))
        XCTAssertEqual(p.phase, .indexing)
        XCTAssertEqual(p.headline, "Sound index: 238 / 1,042 tracks")
        XCTAssertEqual(p.fractionComplete, 238.0 / 1042.0, accuracy: 0.0001)
        XCTAssertTrue(p.canPause)
        XCTAssertFalse(p.canResume)
    }

    func testPausedTakesPrecedenceOverQueuedWork() {
        let p = IndexStatusPresentation.make(
            from: snapshot(coverage(total: 100, complete: 10, queuedOrRunning: 90), paused: true))
        XCTAssertEqual(p.phase, .paused)
        XCTAssertTrue(p.canResume)
        XCTAssertFalse(p.canPause)
    }

    func testWaitingForModelWhenResourcesAbsent() {
        let p = IndexStatusPresentation.make(
            from: snapshot(
                coverage(total: 100, complete: 0, waiting: 100), modelAvailable: false))
        XCTAssertEqual(p.phase, .waitingForModel)
        XCTAssertTrue(p.detail.lowercased().contains("model"))
    }

    func testWaitingForPowerIsDistinctFromWaitingForModel() {
        let p = IndexStatusPresentation.make(
            from: snapshot(
                coverage(total: 100, complete: 40, waiting: 60),
                chargingOnly: true, modelAvailable: true))
        XCTAssertEqual(p.phase, .waiting)
        XCTAssertTrue(p.detail.lowercased().contains("power"))
    }

    func testNeedsAttentionWhenOnlyFailures() {
        let p = IndexStatusPresentation.make(
            from: snapshot(coverage(total: 100, complete: 95, failed: 5)))
        XCTAssertEqual(p.phase, .needsAttention)
        XCTAssertTrue(p.canRetryFailed)
        XCTAssertEqual(p.failedCount, 5)
    }

    func testRetryOfferedEvenWhileIndexingContinues() {
        let p = IndexStatusPresentation.make(
            from: snapshot(coverage(total: 100, complete: 50, queuedOrRunning: 45, failed: 5)))
        XCTAssertEqual(p.phase, .indexing)
        XCTAssertTrue(p.canRetryFailed)
    }

    /// The regression this fix is for: real user report was "Sound Index
    /// says 0/2364 tracks... after 5+ minutes, not a single track has been
    /// indexed... [status screen] just says indexing, nothing about
    /// downloading, waiting, no progress ever evident." Before the fix,
    /// `schedulerBlockReason` did not exist and this exact
    /// coverage (all jobs queued, zero complete) produced `.indexing` with a
    /// generic "Indexing N tracks…" detail no matter what was actually
    /// blocking the scheduler underneath.
    func testBlockedSchedulerNeverShownAsGenericIndexing() {
        let p = IndexStatusPresentation.make(
            from: snapshot(
                coverage(total: 2364, complete: 0, queuedOrRunning: 2364),
                blockReason: .thermalFair))
        XCTAssertEqual(p.phase, .blockedByPolicy)
        XCTAssertNotEqual(p.phase, .indexing)
        XCTAssertFalse(
            p.detail.lowercased().hasPrefix("indexing"),
            "must surface the real reason, not the generic indexing label")
        XCTAssertTrue(p.detail.lowercased().contains("cool down"))
        // The headline (raw counts) is unaffected — only `detail`/`phase`
        // change; "0 / 2,364" must still read exactly as reported.
        XCTAssertEqual(p.headline, "Sound index: 0 / 2,364 tracks")
    }

    func testEachPolicyBlockReasonHasADistinctNonGenericDetail() {
        let reasons: [IndexBlockReason] = [
            .playbackActive, .thermalFair, .thermalSerious, .thermalCritical,
            .memoryWarning, .lowBatteryOrLowPowerMode, .chargingOnlyRequired,
            .backgroundGrantMissing,
        ]
        var seenDetails = Set<String>()
        for reason in reasons {
            let p = IndexStatusPresentation.make(
                from: snapshot(
                    coverage(total: 10, complete: 0, queuedOrRunning: 10), blockReason: reason))
            XCTAssertEqual(p.phase, .blockedByPolicy, "\(reason)")
            XCTAssertFalse(p.detail.isEmpty, "\(reason)")
            seenDetails.insert(p.detail)
        }
        // Thermal variants intentionally share one user-facing message;
        // otherwise every reason should read distinctly.
        XCTAssertGreaterThanOrEqual(seenDetails.count, reasons.count - 2)
    }

    /// `userPaused` already has its own dedicated, higher-priority phase
    /// (`.paused`, checked via `snapshot.isPaused`) — a leftover
    /// `schedulerBlockReason == .userPaused` from a stale tick must not
    /// create a second, redundant "blocked" phase.
    func testStaleUserPausedBlockReasonDoesNotOverrideNormalIndexing() {
        let p = IndexStatusPresentation.make(
            from: snapshot(
                coverage(total: 10, complete: 2, queuedOrRunning: 8),
                blockReason: .userPaused))
        XCTAssertEqual(p.phase, .indexing)
    }

    func testDiagnosticsAreRedactedAggregatesOnly() {
        let runtime = DiscoveryRuntime(
            id: 1, lastRunAt: Date(timeIntervalSince1970: 1_700_000_100),
            lastStopReason: "background: 3 completed")
        let snap = snapshot(
            coverage(total: 10, complete: 4, waiting: 6), modelAvailable: false, runtime: runtime)
        let diag = DiscoveryDiagnostics.make(
            snapshot: snap, appVersion: "1.2.3", buildNumber: "456",
            osVersion: "iOS 18.5", deviceFamily: "iPhone")

        let json = diag.jsonString()
        XCTAssertTrue(json.contains("\"tracksTotal\" : 10"))
        XCTAssertTrue(json.contains("\"tracksFailed\" : 0"))
        XCTAssertTrue(json.contains("background: 3 completed"))
        // No identity leakage vectors.
        XCTAssertFalse(json.lowercased().contains("http"))
        XCTAssertFalse(json.lowercased().contains("file://"))
        XCTAssertFalse(json.lowercased().contains("token"))
        XCTAssertFalse(json.lowercased().contains("bookmark"))

        let text = diag.plainText()
        XCTAssertTrue(text.contains("10 total"))
        XCTAssertTrue(text.contains("1.2.3 (456)"))
    }
}
#endif
