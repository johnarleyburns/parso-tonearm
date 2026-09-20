import XCTest

/// Settings lanes of the UI regression suite (spec §53.3).
///
/// Covers the report "clicking on Settings -> Music Libraries does nothing" and,
/// more broadly, every Settings row that opens a sheet — each of these previously
/// had no accessibility identifier, so a regression that silently no-ops the
/// button's action (as opposed to removing the button) would pass a purely visual
/// check but fail here, since the lane asserts the *destination* actually appears.
@MainActor
final class SettingsRegressionUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = .launchForRegression()
        app.buttons["Settings"].tap()
    }

    /// The reported symptom verbatim: tapping Music Libraries did nothing.
    /// SourcesView uses its own in-content `ScreenHeader`, not a native
    /// navigation bar (same as `LibraryView`), so the check is for that
    /// header's title rather than `app.navigationBars`.
    func testMusicLibrariesOpensSourcesSheet() throws {
        app.waitFor("settings.musicLibraries").tap()
        XCTAssertTrue(app.staticTexts["Libraries"].waitForExistence(timeout: 5),
                      "Music Libraries did not open a sheet")
    }

    func testStreamingCacheOpensManagementSheet() throws {
        app.waitFor("settings.cache").tap()
        XCTAssertTrue(app.staticTexts["Streaming Cache"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
    }

    func testEQOpensSheet() throws {
        app.waitFor("settings.eq").tap()
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 5))
    }

    func testWatchCardOpensSheet() throws {
        app.waitFor("settings.watch").tap()
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 5))
    }

    func testPrivacyOpensSheet() throws {
        app.waitFor("settings.privacy").tap()
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 5))
    }

    func testICloudSyncToggleFlips() throws {
        let toggle = app.waitFor("settings.icloudSync")
        let before = toggle.value as? String
        toggle.tap()
        XCTAssertNotEqual(toggle.value as? String, before,
                          "iCloud Sync toggle did not change state after a tap")
    }

    func testAdvancedSectionExpandsToolsJamendoAndClearCache() throws {
        app.waitFor("settings.advanced").tap()
        XCTAssertTrue(app.waitFor("settings.tools").isHittable)
        XCTAssertTrue(app.waitFor("settings.jamendo.key").isHittable)
        XCTAssertTrue(app.waitFor("settings.clearCache").isHittable)

        app.buttons["settings.tools"].tap()
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 5))
    }

    func testKeepPlayingToggleFlips() throws {
        let toggle = app.waitFor("settings.keepPlaying")
        let before = toggle.value as? String
        toggle.tap()
        XCTAssertNotEqual(toggle.value as? String, before,
                          "Keep Playing toggle did not change state after a tap")
    }

    func testThirdPartyNoticesOpensFromAbout() throws {
        app.waitFor("settings.thirdPartyNotices").tap()
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 5))
    }
}
