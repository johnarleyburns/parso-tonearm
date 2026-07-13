import XCTest
@testable import Tonearm

/// C7 — engine gating: no-ops without Pro / toggle / iCloud account; downgrade
/// or toggle-off stops the engine but never deletes local data. Pure logic.
final class SyncGatingTests: XCTestCase {

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "sync.icloud.enabled")
        super.tearDown()
    }

    func testRunsOnlyWithProToggleAndAccount() {
        XCTAssertTrue(SyncGating.shouldRun(isPro: true, toggleOn: true, account: .available))
    }

    func testNoOpWithoutPro() {
        XCTAssertFalse(SyncGating.shouldRun(isPro: false, toggleOn: true, account: .available))
        XCTAssertEqual(SyncGating.inactiveHint(isPro: false, toggleOn: true, account: .available),
                       "iCloud sync is a Pro feature.")
    }

    func testNoOpWithoutToggle() {
        XCTAssertFalse(SyncGating.shouldRun(isPro: true, toggleOn: false, account: .available))
        XCTAssertEqual(SyncGating.inactiveHint(isPro: true, toggleOn: false, account: .available),
                       "iCloud sync is off.")
    }

    func testNoOpWithoutAccount() {
        XCTAssertFalse(SyncGating.shouldRun(isPro: true, toggleOn: true, account: .noAccount))
        XCTAssertEqual(SyncGating.inactiveHint(isPro: true, toggleOn: true, account: .noAccount),
                       "Sign in to iCloud to sync.")
    }

    func testHintNilWhenRunning() {
        XCTAssertNil(SyncGating.inactiveHint(isPro: true, toggleOn: true, account: .available))
    }

    func testDowngradeStopsButKeepsData() {
        XCTAssertTrue(SyncGating.shouldStopButKeepData(isPro: false, toggleOn: true))
        XCTAssertTrue(SyncGating.shouldStopButKeepData(isPro: true, toggleOn: false))
        XCTAssertFalse(SyncGating.shouldStopButKeepData(isPro: true, toggleOn: true))
    }

    func testToggleDefaultsOff() {
        UserDefaults.standard.removeObject(forKey: "sync.icloud.enabled")
        XCTAssertFalse(SyncGating.isEnabled, "iCloud sync must default OFF (privacy stance)")
    }

    func testTogglePersists() {
        SyncGating.isEnabled = true
        XCTAssertTrue(SyncGating.isEnabled)
        SyncGating.isEnabled = false
        XCTAssertFalse(SyncGating.isEnabled)
    }
}
