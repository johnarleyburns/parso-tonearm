import XCTest
@testable import TonearmCore

final class WatchSessionStateTests: XCTestCase {
    func testSessionSnapshotDefaults() {
        let snap = WatchSessionSnapshot(state: .notInstalled)
        XCTAssertEqual(snap.state, .notInstalled)
        XCTAssertEqual(snap.onWatchTrackCount, 0)
        XCTAssertEqual(snap.onWatchBytes, 0)
        XCTAssertEqual(snap.transferQueueCount, 0)
        XCTAssertEqual(snap.transferFailedCount, 0)
    }

    func testSessionSnapshotWithManifestStats() {
        let snap = WatchSessionSnapshot(
            state: .reachable,
            onWatchTrackCount: 42,
            onWatchBytes: 1024 * 1024,
            transferQueueCount: 3,
            transferFailedCount: 1)
        XCTAssertEqual(snap.state, .reachable)
        XCTAssertEqual(snap.onWatchTrackCount, 42)
        XCTAssertEqual(snap.onWatchBytes, 1024 * 1024)
        XCTAssertEqual(snap.transferQueueCount, 3)
        XCTAssertEqual(snap.transferFailedCount, 1)
    }

    func testAllDisplayStates() {
        let states: [WatchSessionDisplayState] = [
            .notInstalled, .installedNotReachable, .reachable, .unsupported
        ]
        for state in states {
            let snap = WatchSessionSnapshot(state: state)
            XCTAssertEqual(snap.state, state)
        }
    }
}
