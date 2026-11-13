import XCTest
import TonearmWatchProtocol
@testable import TonearmWatchCore

/// Watch redesign §3's StatusChip was built (`WatchStatusChip`) but never wired into Home — the
/// connection/sync banner lived instead as a full-width, multi-line `Section` at the very top of
/// the list, pushing Now Playing below the fold. This policy is the pure title/tone mapping that
/// drives the chip that replaces it.
final class WatchHomeStatusPolicyTests: XCTestCase {
    func testConnectedAndIdleIsGood() {
        let status = WatchHomeStatusPolicy.status(banner: .connected, isSyncing: false, syncResult: nil)
        XCTAssertEqual(status.tone, .good)
        XCTAssertEqual(status.title, "iPhone connected")
    }

    func testConnectedAndSyncingIsGood() {
        let status = WatchHomeStatusPolicy.status(banner: .connected, isSyncing: true, syncResult: nil)
        XCTAssertEqual(status.tone, .good)
        XCTAssertEqual(status.title, "Syncing with iPhone…")
    }

    func testConnectedWithAConfirmedPastResultStaysGood() {
        let status = WatchHomeStatusPolicy.status(banner: .connected, isSyncing: false, syncResult: .confirmed)
        XCTAssertEqual(status.tone, .good)
        XCTAssertEqual(status.title, "iPhone connected")
    }

    func testConnectedWithAFailedPastResultIsAWarningNotAFailure() {
        let status = WatchHomeStatusPolicy.status(
            banner: .connected, isSyncing: false, syncResult: .failed(.phoneUnavailable))
        XCTAssertEqual(status.tone, .warning, "the link itself is fine — only the metadata sync failed")
        XCTAssertEqual(status.title, WatchMetadataSyncResult.failed(.phoneUnavailable).displayMessage)
    }

    func testTemporarilyUnavailableIsAWarning() {
        let status = WatchHomeStatusPolicy.status(banner: .temporarilyUnavailable, isSyncing: false, syncResult: nil)
        XCTAssertEqual(status.tone, .warning)
    }

    func testUnavailableIsAFailure() {
        let status = WatchHomeStatusPolicy.status(banner: .unavailable, isSyncing: false, syncResult: nil)
        XCTAssertEqual(status.tone, .failure)
        XCTAssertEqual(status.title, "iPhone not connected")
    }

    func testIncompatibleIsAFailureWithItsOwnMessage() {
        let status = WatchHomeStatusPolicy.status(banner: .incompatible, isSyncing: false, syncResult: nil)
        XCTAssertEqual(status.tone, .failure)
        XCTAssertEqual(status.title, "Update Platterhead on iPhone")
    }

    /// `.incompatible`/`.unavailable` must win over a stale `isSyncing`/`syncResult` from before the
    /// banner changed — the live reachability banner is always the truth (WatchConnectionChrome's
    /// own doc comment), never overridden by an older sync receipt.
    func testUnavailableWinsOverAStaleSyncingFlag() {
        let status = WatchHomeStatusPolicy.status(banner: .unavailable, isSyncing: true, syncResult: .confirmed)
        XCTAssertEqual(status.tone, .failure)
        XCTAssertEqual(status.title, "iPhone not connected")
    }
}
