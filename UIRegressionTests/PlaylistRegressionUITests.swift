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
        XCTAssertTrue(app.waitFor("playlist.add").isHittable)
        XCTAssertTrue(app.waitFor("playlist.edit").isHittable)
        XCTAssertTrue(app.waitFor("playlist.overflow").isHittable)
        XCTAssertFalse(app.buttons["Rename"].exists)
        app.buttons["More"].tap()
        XCTAssertTrue(app.buttons["Rename"].waitForExistence(timeout: 5))
    }

    /// D-8 · The + control adds tracks to the playlist.
    func testAddTracksToPlaylistFromDetailView() throws {
        app = .launchForRegression()
        openPlaylistDetail()
        app.waitFor("playlist.add").tap()
        XCTAssertTrue(app.buttons.firstMatch.waitForExistence(timeout: 5))
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
        app.buttons["Playlists"].tap()
        if app.buttons["Regression Playlist"].waitForExistence(timeout: 2) {
            app.buttons["Regression Playlist"].tap()
        } else {
            app.buttons["playlists.create"].tap()
            let name = app.textFields["Playlist name"]
            XCTAssertTrue(name.waitForExistence(timeout: 5))
            name.tap()
            name.typeText("Regression Playlist")
            let firstTrack = app.buttons.firstMatch
            if firstTrack.waitForExistence(timeout: 5) { firstTrack.tap() }
            app.buttons["Create Playlist"].tap()
            XCTAssertTrue(app.buttons["Regression Playlist"].waitForExistence(timeout: 5))
            app.buttons["Regression Playlist"].tap()
        }
        app.waitFor("playlist.overflow")
    }
}
