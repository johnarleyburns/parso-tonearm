import Testing
import TonearmWatchProtocol
@testable import TonearmWatchCore

/// Watch redesign §3's StatusChip was built (`WatchStatusChip`) but never wired into Home — the
/// connection/sync banner lived instead as a full-width, multi-line `Section` at the very top of
/// the list, pushing Now Playing below the fold. This policy is the pure title/tone mapping that
/// drives the chip that replaces it.
@Suite struct WatchHomeStatusPolicyTests {
    @Test func testConnectedAndIdleIsGood() {
        let status = WatchHomeStatusPolicy.status(banner: .connected, isSyncing: false, syncResult: nil)
        #expect(status.tone == .good)
        #expect(status.title == "iPhone connected")
    }

    @Test func testConnectedAndSyncingIsGood() {
        let status = WatchHomeStatusPolicy.status(banner: .connected, isSyncing: true, syncResult: nil)
        #expect(status.tone == .good)
        #expect(status.title == "Syncing with iPhone…")
    }

    @Test func testConnectedWithAConfirmedPastResultStaysGood() {
        let status = WatchHomeStatusPolicy.status(banner: .connected, isSyncing: false, syncResult: .confirmed)
        #expect(status.tone == .good)
        #expect(status.title == "iPhone connected")
    }

    @Test func testConnectedWithAFailedPastResultIsAWarningNotAFailure() {
        let status = WatchHomeStatusPolicy.status(
            banner: .connected, isSyncing: false, syncResult: .failed(.phoneUnavailable))
        #expect(status.tone == .warning, "the link itself is fine — only the metadata sync failed")
        #expect(status.title == WatchMetadataSyncResult.failed(.phoneUnavailable).displayMessage)
    }

    @Test func testTemporarilyUnavailableIsAWarning() {
        let status = WatchHomeStatusPolicy.status(banner: .temporarilyUnavailable, isSyncing: false, syncResult: nil)
        #expect(status.tone == .warning)
    }

    @Test func testUnavailableIsAFailure() {
        let status = WatchHomeStatusPolicy.status(banner: .unavailable, isSyncing: false, syncResult: nil)
        #expect(status.tone == .failure)
        #expect(status.title == "iPhone not connected")
    }

    @Test func testIncompatibleIsAFailureWithItsOwnMessage() {
        let status = WatchHomeStatusPolicy.status(banner: .incompatible, isSyncing: false, syncResult: nil)
        #expect(status.tone == .failure)
        #expect(status.title == "Update Platterhead on iPhone")
    }

    /// `.incompatible`/`.unavailable` must win over a stale `isSyncing`/`syncResult` from before the
    /// banner changed — the live reachability banner is always the truth (WatchConnectionChrome's
    /// own doc comment), never overridden by an older sync receipt.
    @Test func testUnavailableWinsOverAStaleSyncingFlag() {
        let status = WatchHomeStatusPolicy.status(banner: .unavailable, isSyncing: true, syncResult: .confirmed)
        #expect(status.tone == .failure)
        #expect(status.title == "iPhone not connected")
    }
}
