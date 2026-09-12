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
        runtime: DiscoveryRuntime = DiscoveryRuntime(id: 1)
    ) -> IndexStatusSnapshot {
        IndexStatusSnapshot(
            coverage: coverage, isPaused: paused, isChargingOnly: chargingOnly,
            modelResourceAvailable: modelAvailable, runtime: runtime,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000))
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
