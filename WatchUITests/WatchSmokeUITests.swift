import XCTest

final class WatchSmokeUITests: XCTestCase {

    func testWatchAppBootsPlaysAndBrowses() throws {
        let app = XCUIApplication()
        app.launchArguments = ["UI_TESTING", "SEED_WATCH_FIXTURES"]
        app.launch()

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

        let rootPlaylists = app.buttons["root.playlists"]
        XCTAssertTrue(rootPlaylists.waitForExistence(timeout: 5))
        rootPlaylists.tap()

        let playlistRow = app.staticTexts["Built-in Playlist"]
        XCTAssertTrue(playlistRow.waitForExistence(timeout: 5))
        playlistRow.tap()

        let firstTrack = app.buttons.firstMatch
        XCTAssertTrue(firstTrack.waitForExistence(timeout: 5))
        firstTrack.tap()

        let playPause = app.buttons["np.playpause"]
        XCTAssertTrue(playPause.waitForExistence(timeout: 5))
        playPause.tap()
        playPause.tap()

        let nextButton = app.buttons["np.next"]
        XCTAssertTrue(nextButton.exists)
        nextButton.tap()

        let prevButton = app.buttons["np.prev"]
        XCTAssertTrue(prevButton.exists)
        prevButton.tap()

        app.navigationBars.buttons.firstMatch.tap()
        app.navigationBars.buttons.firstMatch.tap()

        let rootSongs = app.buttons["root.songs"]
        XCTAssertTrue(rootSongs.waitForExistence(timeout: 5))
        rootSongs.tap()

        let rootStorage = app.buttons["root.storage"]
        _ = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(rootStorage.waitForExistence(timeout: 5))
        rootStorage.tap()

        let storageText = app.staticTexts.firstMatch
        XCTAssertTrue(storageText.exists)
    }
}
