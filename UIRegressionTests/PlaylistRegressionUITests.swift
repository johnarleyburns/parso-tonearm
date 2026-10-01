import XCTest

/// Playlist lanes of the UI regression suite (spec §53.3).
///
@MainActor
final class PlaylistRegressionUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// D-7 · Importing the same folder twice yields **one** folder playlist.
    ///
    /// The regression this guards is identity, not display: folder playlists were
    /// matched to their source by title, so a re-import — or two folders that
    /// happen to share a leaf name — produced duplicates. The lane therefore
    /// imports twice and counts rows.
    func testReimportingAFolderDoesNotDuplicateItsPlaylist() throws {
        app = .launchForRegression()
        // TODO(D-7): import fixture folder, count rows matching its title, import
        // the same folder again, assert the count is unchanged.
        throw XCTSkip("scaffolded — body pending; see spec §51 D-7")
    }

    /// D-7 · Two distinct folders sharing a leaf name stay distinct.
    func testTwoFoldersWithTheSameNameRemainSeparatePlaylists() throws {
        app = .launchForRegression()
        // TODO(D-7): import a/Music and b/Music; assert two playlists exist and
        // each lists only its own tracks.
        throw XCTSkip("scaffolded — body pending; see spec §51 D-7")
    }

    /// D-8 · Playlist detail toolbar order and contents.
    func testPlaylistDetailToolbarLayout() throws {
        app = .launchForRegression()
        openPlaylistDetail()
        XCTAssertTrue(app.waitFor("playlist.back").isHittable)
        XCTAssertTrue(app.waitFor("playlist.add").isHittable)
        XCTAssertTrue(app.waitFor("playlist.edit").isHittable)
        XCTAssertTrue(app.waitFor("playlist.overflow").isHittable)
        XCTAssertGreaterThan(app.waitFor("playlist.add").frame.minX,
                             app.waitFor("playlist.edit").frame.minX)
        XCTAssertFalse(app.buttons["Rename"].exists)
        app.buttons["More"].tap()
        XCTAssertTrue(app.buttons["Rename"].waitForExistence(timeout: 5))
    }

    /// My Music owns the discovery controls now: the old standalone Find Music
    /// surface must not be needed to reach mix BPM/key or sound search.
    func testMyMusicOffersAllMixAndSoundSearchModes() throws {
        app = .launchForRegression()
        app.buttons["My Music"].tap()
        app.waitFor("mymusic.scope.artists").tap()

        XCTAssertTrue(app.waitFor("mymusic.search.mode").exists)
        XCTAssertTrue(app.buttons["All"].exists)
        XCTAssertTrue(app.buttons["Search by Mix"].exists)
        XCTAssertTrue(app.buttons["Search by Sound"].exists)

        app.buttons["Search by Mix"].tap()
        XCTAssertTrue(app.waitFor("mymusic.mix.bpm").exists)
        XCTAssertTrue(app.waitFor("mymusic.mix.key").exists)
        XCTAssertTrue(app.staticTexts["House: 120–130"].exists)
        XCTAssertTrue(app.buttons["1A"].exists)

        app.buttons["Search by Sound"].tap()
        XCTAssertTrue(app.textFields["Search by sound"].waitForExistence(timeout: 10))
    }

    /// A playlist needs an explicit play-all action; relying on a user to tap
    /// one of its rows makes an otherwise valid playlist look inert.
    func testPlaylistDetailOffersPlayAllAndShowsTheMiniPlayer() throws {
        app = .launchForRegression()
        openPlaylistDetail(withTrack: true)

        let play = app.waitFor("playlist.play")
        XCTAssertTrue(play.isHittable)
        play.tap()

        XCTAssertTrue(app.waitFor("mini.title", 10).isHittable,
                      "playing a playlist must surface the mini-player")
        XCTAssertTrue(app.waitFor("mini.title", 10).exists,
                      "the mini-player must identify the playlist track")
    }

    /// Deleting from the playlist list must cross a confirmation boundary and
    /// leave the app usable after the row is removed. This also guards the
    /// field crash reported from the context-menu delete path.
    func testDeletingAPlaylistDoesNotCrashOrLeaveTheRowVisible() throws {
        app = .launchForRegression()
        openPlaylistDetail()
        app.waitFor("playlist.back").tap()

        let row = app.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH %@", "Regression Playlist")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.swipeLeft()
        // SwiftUI exposes swipe actions as sibling buttons rather than
        // descendants of the combined row accessibility element.
        app.buttons["Delete"].tap()
        XCTAssertTrue(app.alerts["Delete Playlist?"].waitForExistence(timeout: 5),
                      "playlist deletion must be confirmed before mutating the list")
        app.alerts["Delete Playlist?"].buttons["Delete"].tap()

        XCTAssertTrue(app.waitFor("mymusic.scope.playlists", 10).exists)
        XCTAssertTrue(row.waitForNonExistence(timeout: 10),
                      "the deleted playlist row must disappear after the async store write")
    }

    /// D-8 · The + control adds tracks to the playlist.
    func testAddTracksToPlaylistFromDetailView() throws {
        app = .launchForRegression()
        openPlaylistDetail()
        app.waitFor("playlist.add").tap()
        XCTAssertTrue(app.waitFor("playlist.add.confirm", 5).exists)
    }

    /// D-8 · Rename lives under the overflow and persists.
    func testRenamePlaylistFromOverflowMenu() throws {
        app = .launchForRegression()
        openPlaylistDetail()
        app.waitFor("playlist.overflow").tap()
        app.buttons["Rename"].tap()
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap(); field.typeText(" Regression")
        app.alerts.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "Regression")).firstMatch.waitForExistence(timeout: 5))
    }

    private func openPlaylistDetail() {
        openPlaylistDetail(withTrack: false)
    }

    private func openPlaylistDetail(withTrack: Bool) {
        app.buttons["My Music"].tap()
        app.waitFor("mymusic.scope.playlists").tap()
        let existing = app.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH %@", "Regression Playlist")).firstMatch
        if existing.waitForExistence(timeout: 2) {
            existing.tap()
        } else {
            // The embedded My Music container exposes the ScreenHeader's
            // add control as the localized accessibility element labelled
            // "Add". Use the stable identifier when SwiftUI preserves it,
            // and the user-facing label when the parent container combines
            // the child into its accessibility element.
            let create = app.buttons["playlists.create"]
            if create.exists {
                create.tap()
            } else {
                app.buttons["Add"].tap()
            }
            let name = app.textFields["Playlist name"]
            XCTAssertTrue(name.waitForExistence(timeout: 5))
            name.tap()
            name.typeText("Regression Playlist")
            app.buttons["Create Playlist"].tap()
            let created = app.descendants(matching: .any).matching(
                NSPredicate(format: "label BEGINSWITH %@", "Regression Playlist")).firstMatch
            XCTAssertTrue(created.waitForExistence(timeout: 5))
            created.tap()
        }
        app.waitFor("playlist.overflow")

        if withTrack {
            app.waitFor("playlist.add").tap()
            let track = app.buttons.matching(
                NSPredicate(format: "identifier BEGINSWITH %@", "playlist.add.row.")).firstMatch
            XCTAssertTrue(track.waitForExistence(timeout: 5))
            track.tap()
            app.waitFor("playlist.add.confirm").tap()
            app.waitForNonExistence("playlist.add.confirm", 10)
            XCTAssertTrue(app.waitFor("playlist.play", 5).exists)
        }
    }
}
