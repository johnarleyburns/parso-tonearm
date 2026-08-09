import XCTest

/// Playlist lanes of the UI regression suite (spec §53.3).
///
/// STATUS: scaffolded. See the header of `RemoteLibraryRegressionUITests` for the
/// skip-vs-fail contract.
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
        // TODO(D-8): assert, left to right, playlist.add ▸ playlist.edit ▸
        // playlist.overflow; and that Rename is inside the overflow menu, not on
        // the bar.
        throw XCTSkip("scaffolded — body pending; see spec §51 D-8")
    }

    /// D-8 · The + control adds tracks to the playlist.
    func testAddTracksToPlaylistFromDetailView() throws {
        app = .launchForRegression()
        throw XCTSkip("scaffolded — body pending; see spec §51 D-8")
    }

    /// D-8 · Rename lives under the overflow and persists.
    func testRenamePlaylistFromOverflowMenu() throws {
        app = .launchForRegression()
        throw XCTSkip("scaffolded — body pending; see spec §51 D-8")
    }
}
