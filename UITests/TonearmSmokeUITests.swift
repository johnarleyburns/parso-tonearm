import XCTest

final class TonearmSmokeUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        app = nil
    }

    func testFindModesMatchBrowseChipHeightAndSettingsCanDismiss() throws {
        launch()
        app.buttons["Find"].tap()
        let all = app.buttons["All"]
        let mood = app.buttons["Find Mood"]
        let mix = app.buttons["Find Mix"]
        XCTAssertTrue(all.waitForExistence(timeout: 10))
        XCTAssertLessThan(all.frame.minX, mood.frame.minX)
        XCTAssertLessThan(mood.frame.minX, mix.frame.minX)
        XCTAssertEqual(all.frame.height, app.buttons["Artists"].frame.height, accuracy: 1)
        app.buttons["Listen"].tap()
        element("listen.settings").tap()
        let done = element("settings.done")
        XCTAssertTrue(done.waitForExistence(timeout: 10))
        done.tap()
        XCTAssertTrue(element("listen.settings").waitForExistence(timeout: 10))
        XCTAssertFalse(element("settings.section.playback").exists)
    }

    func testFindQueryFocusHidesTitleAndMiniPlayerThenRestores() throws {
        launch()
        app.buttons["My Music"].tap()
        app.buttons["mymusic.scope.playlists"].tap()
        element("playlist.ambient").tap()
        element("ambient.track.ambient-rain").coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertTrue(app.staticTexts["mini.title"].waitForExistence(timeout: 10))

        app.buttons["Find"].tap()
        XCTAssertTrue(app.staticTexts["mini.title"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.navigationBars["Find"].waitForExistence(timeout: 10))

        for mode in ["find.mode.all", "find.mode.mood"] {
            app.buttons[mode].tap()
            let field = app.textFields["mymusic.search.text"]
            XCTAssertTrue(field.waitForExistence(timeout: 10))
            field.tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
            XCTAssertTrue(waitForGone(app.navigationBars["Find"]), "Find nav chrome must hide on focus")
            XCTAssertTrue(waitForGone(app.staticTexts["mini.title"]), "Mini-player must hide on focus")
            XCTAssertTrue(element("find.awaitingQuery").isHittable)
            app.keyboards.buttons["return"].tap()
            XCTAssertTrue(app.navigationBars["Find"].waitForExistence(timeout: 10))
            XCTAssertTrue(app.staticTexts["mini.title"].waitForExistence(timeout: 10))
        }

        app.buttons["find.mode.mix"].tap()
        XCTAssertFalse(app.textFields["mymusic.search.text"].exists)
        XCTAssertTrue(app.navigationBars["Find"].exists)
        XCTAssertTrue(app.staticTexts["mini.title"].exists)
    }

    private func waitForGone(_ element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !element.exists || !element.isHittable { return true }
            usleep(200_000)
        }
        return false
    }

    func testSettingsCardsHaveEqualMarginsAndWatchSyncIsClear() throws {
        launch()
        openTab("Listen", anchor: "Listen")
        XCTAssertTrue(element("listen.settings").waitForExistence(timeout: 10))
        element("listen.settings").tap()
        let playback = element("settings.section.playback")
        XCTAssertTrue(playback.waitForExistence(timeout: 10))
        // Sections are flat/always-expanded now (no tap needed to reveal content).
        XCTAssertTrue(element("settings.streamOnCellular").exists)
        let watch = app.buttons["settings.watch"]
        XCTAssertTrue(watch.isHittable)
        XCTAssertEqual(watch.frame.minX, app.frame.maxX - watch.frame.maxX, accuracy: 1)
        XCTAssertEqual(playback.frame.minX, watch.frame.minX, accuracy: 1)
        XCTAssertEqual(playback.frame.maxX, watch.frame.maxX, accuracy: 1)
        XCTAssertTrue(element("settings.advanced").isHittable)
        watch.tap()
        XCTAssertTrue(app.staticTexts["Apple Watch & Sync"].waitForExistence(timeout: 10))
        XCTAssertTrue(element("settings.watch.syncNow").isHittable)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Watch-sync-settings"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testIPhoneSmokeOpensPlaylistPlaysAndSkips() throws {
        launch(arguments: ["UI_TEST_SLOW_LIBRARY_LOAD"])

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10),
                      "App should reach the foreground without crashing")

        openTab("Listen", anchor: "Listen")
        XCTAssertTrue(element("listen.loading").waitForExistence(timeout: 5))
        let recentHeightWhileLoading = element("listen.recent").frame.height
        let favoriteHeightWhileLoading = element("listen.favorites").frame.height
        XCTAssertGreaterThan(recentHeightWhileLoading, 180)
        XCTAssertGreaterThan(favoriteHeightWhileLoading, 180)
        XCTAssertFalse(app.buttons["listen.buildMix"].exists)
        XCTAssertFalse(app.staticTexts["Favorite a track and it will show up here."].exists)
        app.buttons["My Music"].tap()
        XCTAssertTrue(element("mymusic.loading").waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Your music is empty"].exists)
        XCTAssertFalse(app.staticTexts["Create a playlist"].exists)
        app.buttons["Listen"].tap()
        let loaded = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element("listen.loading"))
        XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 20), .completed)
        XCTAssertEqual(element("listen.recent").frame.height, recentHeightWhileLoading, accuracy: 1)
        XCTAssertEqual(element("listen.favorites").frame.height, favoriteHeightWhileLoading, accuracy: 1)
        XCTAssertTrue(app.buttons["Mood"].waitForExistence(timeout: 5),
                      "Mood should be a first-class root tab")
        XCTAssertTrue(app.buttons["Find"].waitForExistence(timeout: 5),
                      "Find should be a first-class root tab")
        app.buttons["Find"].tap()
        XCTAssertTrue(element("find.awaitingQuery").waitForExistence(timeout: 5))
        XCTAssertFalse(element("find.results").exists,
                       "Find must not browse the whole library before a query")
        XCTAssertTrue(element("mymusic.search.text").isHittable)
        XCTAssertTrue(element("find.scope").isHittable,
                       "Find controls must not be clipped by a fixed-height header")
        app.buttons["Listen"].tap()
        XCTAssertTrue(element("listen.settings").waitForExistence(timeout: 5),
                      "Settings should be available from Listen's upper-right action")

        element("listen.settings").tap()
        let playbackSection = element("settings.section.playback")
        XCTAssertTrue(playbackSection.waitForExistence(timeout: 10))
        // Sections are flat/always-expanded now — no tap needed to reveal content.
        XCTAssertTrue(element("settings.streamOnCellular").waitForExistence(timeout: 5),
                      "Playback settings should be visible without expanding a section")
        let watchSettings = app.buttons["settings.watch"]
        XCTAssertTrue(watchSettings.isHittable, "Apple Watch must be reachable without pages of scrolling")
        XCTAssertTrue(watchSettings.waitForExistence(timeout: 10))
        watchSettings.tap()
        XCTAssertTrue(element("settings.watch.syncStatus").waitForExistence(timeout: 10),
                      "Phone Watch settings must expose sync receipts, not only pairing and installed count")
        XCTAssertTrue(app.staticTexts["Last watch report received"].exists)
        XCTAssertTrue(app.staticTexts["Catalog received by watch"].exists)
        let syncScreenshot = XCTAttachment(screenshot: app.screenshot())
        syncScreenshot.name = "Phone-watch-sync-status"
        syncScreenshot.lifetime = .keepAlways
        add(syncScreenshot)
        app.buttons["Done"].firstMatch.tap()
        let sheetTop = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08))
        sheetTop.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)))

        // Playlists is a scope within My Music now, not its own root tab
        // (docs/plans/UNIFIED_TONEARM_MY_MUSIC_TRANSITION_LAB_HANDOFF.md §4).
        app.buttons["My Music"].tap()
        XCTAssertTrue(element("mymusic.scope").waitForExistence(timeout: 10),
                      "My Music tab should show the unified scope bar")
        let scopeBar = element("mymusic.scope")
        let onWatch = app.buttons["mymusic.scope.onmywatch"]
        for _ in 0..<5 where !onWatch.isHittable { scopeBar.swipeLeft() }
        XCTAssertTrue(onWatch.isHittable, "My Music must expose On My Watch")
        onWatch.tap()
        XCTAssertTrue(element("mymusic.content.watch").waitForExistence(timeout: 10))
        app.terminate()
        app.launch()
        XCTAssertTrue(element("mymusic.content.watch").waitForExistence(timeout: 15),
                      "Relaunch must restore both My Music and its On My Watch scope")
        for _ in 0..<5 where !app.buttons["mymusic.scope.playlists"].isHittable { element("mymusic.scope").swipeRight() }
        app.buttons["mymusic.scope.playlists"].tap()
        XCTAssertTrue(app.staticTexts["Playlists"].waitForExistence(timeout: 10),
                      "Selecting the Playlists scope chip should render Playlists")

        let ambientPlaylist = element("playlist.ambient")
        XCTAssertTrue(ambientPlaylist.waitForExistence(timeout: 10),
                      "Built-in Ambient playlist should be visible")
        ambientPlaylist.tap()

        let rain = element("ambient.track.ambient-rain")
        XCTAssertTrue(rain.waitForExistence(timeout: 10),
                      "Built-in Rainy Day track should be visible")
        // Hit the visible play affordance, not the looping video preview inside the tile.
        rain.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let playbackScreenshot = XCTAttachment(screenshot: app.screenshot())
        playbackScreenshot.name = "Ambient-playback-after-watch-settings"
        playbackScreenshot.lifetime = .keepAlways
        add(playbackScreenshot)

        let miniTitle = app.staticTexts["mini.title"]
        XCTAssertTrue(miniTitle.waitForExistence(timeout: 10),
                      "Mini player title should appear after starting playback")
        XCTAssertTrue(waitForLabel(miniTitle, equals: "Rainy Day", timeout: 10), "Actual mini-player title: \(miniTitle.label)")

        miniTitle.tap()
        let playPause = app.buttons["np.playpause"]
        XCTAssertTrue(playPause.waitForExistence(timeout: 10),
                      "Now Playing play/pause control should appear")
        XCTAssertTrue(waitForValue(playPause, equals: "playing", timeout: 5),
                      "Starting the built-in track should enter playing state")

        playPause.tap()
        XCTAssertTrue(waitForValue(playPause, equals: "paused", timeout: 5),
                      "Play/pause should pause playback")
        playPause.tap()
        XCTAssertTrue(waitForValue(playPause, equals: "playing", timeout: 5),
                      "Play/pause should resume playback")

        let nextButton = app.buttons["np.next"]
        XCTAssertTrue(nextButton.waitForExistence(timeout: 5),
                      "Now Playing next control should exist")
        nextButton.tap()
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(waitForLabel(miniTitle, equals: "Ocean Waves", timeout: 5),
                      "Skipping forward should advance to the next built-in track")

    }

    private func launch(arguments: [String] = []) {
        app = XCUIApplication()
        app.launchArguments = ["UI_TESTING", "-uiRegression", "-resetLibrary"] + arguments
        app.launch()
    }

    private func openTab(_ tab: String,
                         anchor: String,
                         file: StaticString = #filePath,
                         line: UInt = #line) {
        let button = app.buttons[tab]
        XCTAssertTrue(button.waitForExistence(timeout: 15),
                      "\(tab) tab button should be visible",
                      file: file,
                      line: line)
        button.tap()

        let title = app.staticTexts[anchor]
        XCTAssertTrue(title.waitForExistence(timeout: 10),
                      "\(anchor) should render after opening \(tab)",
                      file: file,
                      line: line)
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func waitForValue(_ element: XCUIElement,
                              equals expected: String,
                              timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (element.value as? String)?.caseInsensitiveCompare(expected) == .orderedSame { return true }
            usleep(200_000)
        }
        return (element.value as? String)?.caseInsensitiveCompare(expected) == .orderedSame
    }

    private func waitForLabel(_ element: XCUIElement,
                              equals expected: String,
                              timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.label == expected { return true }
            usleep(200_000)
        }
        return element.label == expected
    }
}
