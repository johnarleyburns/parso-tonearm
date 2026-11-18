import Testing
import Synchronization
import TonearmWatchCore
import TonearmWatchProtocol

@Suite struct WatchBackgroundDeliveryTrackerTests {
    @MainActor
    @Test func testLiveSyncWaitsForPhonePushAndDoesNotCallRequestAcceptanceAnUpdate() async {
        let suite = "phone-push-sync-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = WatchSyncStatusState(defaults: defaults)
        let request = state.requestedSync()
        state.completedSync(.sent, requestID: request)
        #expect(state.isSyncing)
        #expect(state.syncResult == .sent)
        await state.didReceiveDownloadStatus(.init(revision: 1))
        #expect(!state.isSyncing)
        #expect(state.syncResult == .confirmed)
        #expect(state.lastAudioInstalledAt == nil)
        state.completedSync(.sent, requestID: request)
        #expect(state.syncResult == .confirmed, "A late transport reply must not overwrite an applied push")
    }
    @MainActor
    @Test func testLateMetadataCheckCannotOverwriteANewerStartupOrManualCheck() {
        let suite = "metadata-sync-generation-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = WatchSyncStatusState(defaults: defaults)
        let old = state.requestedSync()
        state.completedSync(.failed(.requestTimedOut), requestID: old)
        #expect(!state.isSyncing)
        let current = state.requestedSync()
        state.completedSync(.confirmed, requestID: old)
        #expect(state.isSyncing)
        #expect(state.syncResult == nil)
        state.completedSync(.confirmed, requestID: current)
        #expect(!state.isSyncing)
        #expect(state.syncResult == .confirmed)
        #expect(state.lastAudioInstalledAt == nil)
    }
    @MainActor
    @Test func testMetadataSyncControlFinishesForQueuedFailureAndConfirmedResults() {
        let suite = "metadata-sync-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = WatchSyncStatusState(defaults: defaults)
        for result: WatchMetadataSyncResult in [.queued, .failed(.requestTimedOut), .confirmed] {
            state.requestedSync()
            #expect(state.isSyncing)
            state.completedSync(result)
            #expect(!state.isSyncing)
            #expect(state.syncResult == result)
            #expect(state.lastAudioInstalledAt == nil, "Metadata confirmation must never count as installed audio")
        }
    }
    @Test func testBackgroundLifetimeIncludesAsyncInstallationAndPendingSessionContent() async throws {
        let tracker = WatchBackgroundDeliveryTracker()
        let sessionPending = Mutex(true)
        let returned = Mutex(false)
        tracker.begin()
        let task = Task {
            await tracker.waitUntilDrained { sessionPending.withLock { $0 } }
            returned.withLock { $0 = true }
        }
        try await Task.sleep(for: .milliseconds(120))
        #expect(!returned.withLock { $0 })
        tracker.end()
        try await Task.sleep(for: .milliseconds(120))
        #expect(!returned.withLock { $0 }, "Session delivery is still pending")
        tracker.begin()
        sessionPending.withLock { $0 = false }
        try await Task.sleep(for: .milliseconds(120))
        #expect(!returned.withLock { $0 }, "Delegate finished, but installation has not")
        tracker.end()
        await task.value
        #expect(returned.withLock { $0 })
    }

    @Test func testCancelledBackgroundWaitExitsWithoutClaimingInstallationCompleted() async {
        let tracker = WatchBackgroundDeliveryTracker()
        tracker.begin()
        let task = Task { await tracker.waitUntilDrained { false } }
        task.cancel()
        await task.value
        #expect(tracker.hasPendingWork)
        tracker.end()
    }

    @MainActor
    @Test func testOldProgressIsMarkedStaleUntilANewPhoneReportArrives() async {
        let suite = "sync-staleness-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSince1970: 1000)
        let state = WatchSyncStatusState(defaults: defaults, now: { now })
        await state.didReceiveDownloadStatus(.init(revision: 1, activeCount: 1, generatedAt: now))
        #expect(!state.isDownloadStatusStale(at: now.addingTimeInterval(10)))
        #expect(state.isDownloadStatusStale(at: now.addingTimeInterval(31)))
        await state.didReceiveDownloadStatus(.init(revision: 2, activeCount: 1,
            generatedAt: now.addingTimeInterval(31)))
        #expect(!state.isDownloadStatusStale(at: now.addingTimeInterval(32)))
    }
}
