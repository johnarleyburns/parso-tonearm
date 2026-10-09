import XCTest

final class TonearmSmokeUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        app = nil
    }

    func testSettingsCardsHaveEqualMarginsAndWatchSyncIsClear() throws {
        launch()
        openTab("Listen", anchor: "Listen")
        XCTAssertTrue(element("listen.settings").waitForExistence(timeout: 10))
        element("listen.settings").tap()
        let playback = element("settings.section.playback")
        XCTAssertTrue(playback.waitForExistence(timeout: 10))
        if element("settings.streamOnCellular").exists { playback.tap() }
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
        if element("settings.streamOnCellular").exists { playbackSection.tap() }
        XCTAssertFalse(element("settings.streamOnCellular").exists)
        playbackSection.tap()
        XCTAssertTrue(element("settings.streamOnCellular").waitForExistence(timeout: 5))
        playbackSection.tap()
        XCTAssertFalse(element("settings.streamOnCellular").exists)
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

    /// Build a Mix end to end on a fresh install: the Mood Starter library merges, Generate opens
    /// Mix for You with an enabled Play Mix, and playing it closes the sheet and starts the mix.
    func testBuildAMixAndPlayIt() throws {
        launch()
        openTab("Mood", anchor: "Mood")
        XCTAssertTrue(app.buttons["mood.play"].waitForExistence(timeout: 10), "Mood must expose a direct Play action")
        let card = app.buttons["mood.buildMix"]
        for _ in 0..<6 where !card.exists { app.swipeUp() }
        XCTAssertTrue(card.waitForExistence(timeout: 20), "Build a Mix belongs on Mood, not Listen")
        let ready = expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: card)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 60), .completed,
                       "The initial library load must finish before capturing mix candidates")

        // The first launch merges the Mood Starter library in the background; retry until the
        // builder has mixable tracks.
        let play = app.buttons["mix.preview.play"].firstMatch
        let deadline = Date().addingTimeInterval(90)
        while !play.exists, Date() < deadline {
            card.tap()
            let generate = app.buttons["Generate"].firstMatch
            XCTAssertTrue(generate.waitForExistence(timeout: 10))
            if generate.isEnabled { generate.tap() }
            for _ in 0..<60 where !play.exists { Thread.sleep(forTimeInterval: 0.5) }
            if !play.exists {
                app.buttons["Cancel"].firstMatch.tap()
                Thread.sleep(forTimeInterval: 3)
            }
        }
        XCTAssertTrue(play.exists, "Generate should open Mix for You")
        XCTAssertTrue(play.isEnabled, "Play Mix must be enabled for a generated mix")
        play.tap()

        let closed = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: play)
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 5), .completed,
                       "Playing a mix should close Build a Mix")
        let miniTitle = app.descendants(matching: .any)["mini.title"].firstMatch
        XCTAssertTrue(miniTitle.waitForExistence(timeout: 15), "The mix should be in the player")
        XCTAssertFalse(miniTitle.label.isEmpty)
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
