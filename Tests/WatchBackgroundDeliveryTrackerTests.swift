import XCTest
import Synchronization
import TonearmWatchCore
import TonearmWatchProtocol

final class WatchBackgroundDeliveryTrackerTests: XCTestCase {
    @MainActor
    func testMetadataSyncControlFinishesForQueuedFailureAndConfirmedResults() {
        let suite = "metadata-sync-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = WatchSyncStatusState(defaults: defaults)
        for result: WatchMetadataSyncResult in [.queued, .failed(.requestTimedOut), .confirmed] {
            state.requestedSync()
            XCTAssertTrue(state.isSyncing)
            state.completedSync(result)
            XCTAssertFalse(state.isSyncing)
            XCTAssertEqual(state.syncResult, result)
            XCTAssertNil(state.lastAudioInstalledAt, "Metadata confirmation must never count as installed audio")
        }
    }
    func testBackgroundLifetimeIncludesAsyncInstallationAndPendingSessionContent() async throws {
        let tracker = WatchBackgroundDeliveryTracker()
        let sessionPending = Mutex(true)
        let returned = Mutex(false)
        tracker.begin()
        let task = Task {
            await tracker.waitUntilDrained { sessionPending.withLock { $0 } }
            returned.withLock { $0 = true }
        }
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertFalse(returned.withLock { $0 })
        tracker.end()
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertFalse(returned.withLock { $0 }, "Session delivery is still pending")
        tracker.begin()
        sessionPending.withLock { $0 = false }
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertFalse(returned.withLock { $0 }, "Delegate finished, but installation has not")
        tracker.end()
        await task.value
        XCTAssertTrue(returned.withLock { $0 })
    }

    func testCancelledBackgroundWaitExitsWithoutClaimingInstallationCompleted() async {
        let tracker = WatchBackgroundDeliveryTracker()
        tracker.begin()
        let task = Task { await tracker.waitUntilDrained { false } }
        task.cancel()
        await task.value
        XCTAssertTrue(tracker.hasPendingWork)
        tracker.end()
    }

    @MainActor
    func testOldProgressIsMarkedStaleUntilANewPhoneReportArrives() async {
        let suite = "sync-staleness-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSince1970: 1000)
        let state = WatchSyncStatusState(defaults: defaults, now: { now })
        await state.didReceiveDownloadStatus(.init(revision: 1, activeCount: 1, generatedAt: now))
        XCTAssertFalse(state.isDownloadStatusStale(at: now.addingTimeInterval(10)))
        XCTAssertTrue(state.isDownloadStatusStale(at: now.addingTimeInterval(31)))
        await state.didReceiveDownloadStatus(.init(revision: 2, activeCount: 1,
            generatedAt: now.addingTimeInterval(31)))
        XCTAssertFalse(state.isDownloadStatusStale(at: now.addingTimeInterval(32)))
    }
}
