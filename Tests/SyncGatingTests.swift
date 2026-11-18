import Testing
@testable import TonearmCore

/// C7 — engine gating: no-ops without toggle / iCloud account; toggle-off
/// stops the engine but never deletes local data. Pure logic.
/// iCloud sync is free for all users.
@Suite final class SyncGatingTests {

    deinit {
        UserDefaults.standard.removeObject(forKey: "sync.icloud.enabled")
    }

    @Test func testRunsOnlyWithToggleAndAccount() {
        #expect(SyncGating.shouldRun(toggleOn: true, account: .available))
    }

    @Test func testNoOpWithoutToggle() {
        #expect(!SyncGating.shouldRun(toggleOn: false, account: .available))
        #expect(SyncGating.inactiveHint(toggleOn: false, account: .available) ==
                       "iCloud sync is off.")
    }

    @Test func testNoOpWithoutAccount() {
        #expect(!SyncGating.shouldRun(toggleOn: true, account: .noAccount))
        #expect(SyncGating.inactiveHint(toggleOn: true, account: .noAccount) ==
                       "Sign in to iCloud to sync.")
    }

    @Test func testHintNilWhenRunning() {
        #expect(SyncGating.inactiveHint(toggleOn: true, account: .available) == nil)
    }

    @Test func testToggleOffStopsButKeepsData() {
        #expect(SyncGating.shouldStopButKeepData(toggleOn: false))
        #expect(!SyncGating.shouldStopButKeepData(toggleOn: true))
    }

    @Test func testToggleDefaultsOff() {
        UserDefaults.standard.removeObject(forKey: "sync.icloud.enabled")
        #expect(!SyncGating.isEnabled, "iCloud sync must default OFF (privacy stance)")
    }

    @Test func testTogglePersists() {
        SyncGating.isEnabled = true
        #expect(SyncGating.isEnabled)
        SyncGating.isEnabled = false
        #expect(!SyncGating.isEnabled)
    }
}
