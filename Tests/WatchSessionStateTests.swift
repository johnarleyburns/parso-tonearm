import Testing
@testable import TonearmCore

@Suite struct WatchSessionStateTests {
    @Test func testSessionSnapshotDefaults() {
        let snap = WatchSessionSnapshot(state: .notInstalled)
        #expect(snap.state == .notInstalled)
        #expect(snap.onWatchTrackCount == 0)
        #expect(snap.onWatchBytes == 0)
        #expect(snap.transferQueueCount == 0)
        #expect(snap.transferFailedCount == 0)
    }

    @Test func testSessionSnapshotWithManifestStats() {
        let snap = WatchSessionSnapshot(
            state: .reachable,
            onWatchTrackCount: 42,
            onWatchBytes: 1024 * 1024,
            transferQueueCount: 3,
            transferFailedCount: 1)
        #expect(snap.state == .reachable)
        #expect(snap.onWatchTrackCount == 42)
        #expect(snap.onWatchBytes == 1024 * 1024)
        #expect(snap.transferQueueCount == 3)
        #expect(snap.transferFailedCount == 1)
    }

    @Test func testAllDisplayStates() {
        let states: [WatchSessionDisplayState] = [
            .notInstalled, .installedNotReachable, .reachable, .unsupported
        ]
        for state in states {
            let snap = WatchSessionSnapshot(state: state)
            #expect(snap.state == state)
        }
    }
}
