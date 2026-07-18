import XCTest
@testable import TonearmCore

/// C7 — engine gating: no-ops without toggle / iCloud account; toggle-off
/// stops the engine but never deletes local data. Pure logic.
/// iCloud sync is free for all users.
final class SyncGatingTests: XCTestCase {

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "sync.icloud.enabled")
        super.tearDown()
    }

    func testRunsOnlyWithToggleAndAccount() {
        XCTAssertTrue(SyncGating.shouldRun(toggleOn: true, account: .available))
    }

    func testNoOpWithoutToggle() {
        XCTAssertFalse(SyncGating.shouldRun(toggleOn: false, account: .available))
        XCTAssertEqual(SyncGating.inactiveHint(toggleOn: false, account: .available),
                       "iCloud sync is off.")
    }

    func testNoOpWithoutAccount() {
        XCTAssertFalse(SyncGating.shouldRun(toggleOn: true, account: .noAccount))
        XCTAssertEqual(SyncGating.inactiveHint(toggleOn: true, account: .noAccount),
                       "Sign in to iCloud to sync.")
    }

    func testHintNilWhenRunning() {
        XCTAssertNil(SyncGating.inactiveHint(toggleOn: true, account: .available))
    }

    func testToggleOffStopsButKeepsData() {
        XCTAssertTrue(SyncGating.shouldStopButKeepData(toggleOn: false))
        XCTAssertFalse(SyncGating.shouldStopButKeepData(toggleOn: true))
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
