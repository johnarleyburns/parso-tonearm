import XCTest

/// Remote-library lanes of the UI regression suite (spec §53.3).
///
/// Each lane adds a library through the real Add-Library UI and then plays **at
/// least one track**, because "the library appeared" has never been the thing that
/// breaks — D-10 is precisely a library that adds cleanly and plays nothing.
///
/// STATUS: scaffolded. Bodies marked `TODO(D-n)` assert the intended behaviour and
/// are expected to fail until the matching defect is fixed; that is the point of a
/// regression suite written before the fixes (§53.5).
@MainActor
final class RemoteLibraryRegressionUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - archive.org

    /// D-9 · archive.org collections and lists resolve instead of failing -1002.
    /// D-15 · "The Vapor Vault" collection plays at least one track.
    func testArchiveOrgPublicCollectionAddsAndPlays() throws {
        app = .launchForRegression()
        // TODO(D-9, D-15): add the collection by URL, assert no NSURLErrorDomain
        // -1002 alert appears, open the first item, play, assertPlaybackAdvances().
        throw XCTSkip("scaffolded — body pending; see spec §51 D-9, D-15")
    }

    /// D-16 · archive.org private list, credentials from `.test-credentials`.
    func testArchiveOrgPrivateListAddsAndPlays() throws {
        let creds = try RegressionEnv.require(
            "PH_TEST_ARCHIVE_ORG_USERNAME",
            "PH_TEST_ARCHIVE_ORG_PASSWORD",
            "PH_TEST_ARCHIVE_ORG_LIST_URL",
            lane: "archive.org private list (D-16)")
        XCTAssertFalse(creds.isEmpty)
        app = .launchForRegression()
        // TODO(D-16): drive Add Library ▸ archive.org (Private List) with the
        // supplied URL/username/password, then play one track.
        throw XCTSkip("scaffolded — body pending; see spec §51 D-16")
    }

    // MARK: - Subsonic

    /// D-10 · Navidrome demo adds a library AND plays. The public demo is the
    /// fixture; credentials are published, so they are not secrets (§54.2).
    func testSubsonicNavidromeDemoAddsAndPlays() throws {
        let creds = try RegressionEnv.require(
            "PH_TEST_SUBSONIC_DEMO_URL",
            "PH_TEST_SUBSONIC_DEMO_USERNAME",
            "PH_TEST_SUBSONIC_DEMO_PASSWORD",
            lane: "Subsonic demo (D-10)")
        XCTAssertEqual(creds["PH_TEST_SUBSONIC_DEMO_URL"], "https://demo.navidrome.org")
        app = .launchForRegression()
        // TODO(D-10): add the library, browse to a track, play,
        // assertPlaybackAdvances(). This lane is the one that must not regress.
        throw XCTSkip("scaffolded — body pending; see spec §51 D-10")
    }

    // MARK: - WebDAV / SMB (local servers)

    /// D-11 · WebDAV against the local container.
    func testWebDAVLocalServerAddsAndPlays() throws {
        _ = try RegressionEnv.require(
            "PH_TEST_WEBDAV_URL", "PH_TEST_WEBDAV_USERNAME", "PH_TEST_WEBDAV_PASSWORD",
            lane: "WebDAV (D-11)")
        app = .launchForRegression()
        throw XCTSkip("scaffolded — body pending; see spec §51 D-11")
    }

    /// D-12 · SMB against the local Samba container.
    func testSMBLocalServerAddsAndPlays() throws {
        _ = try RegressionEnv.require(
            "PH_TEST_SMB_HOST", "PH_TEST_SMB_SHARE", "PH_TEST_SMB_USERNAME", "PH_TEST_SMB_PASSWORD",
            lane: "SMB (D-12)")
        app = .launchForRegression()
        throw XCTSkip("scaffolded — body pending; see spec §51 D-12")
    }

    // MARK: - Jellyfin / Plex

    /// D-13 · Jellyfin demo, user "demo" with an **empty** password. The lane
    /// exists as much to prove the UI accepts a blank password as to prove
    /// playback works.
    func testJellyfinDemoAcceptsEmptyPasswordAndPlays() throws {
        guard let url = RegressionEnv.value("PH_TEST_JELLYFIN_DEMO_URL"),
              let user = RegressionEnv.value("PH_TEST_JELLYFIN_DEMO_USERNAME"),
              let password = RegressionEnv.valueAllowingEmpty("PH_TEST_JELLYFIN_DEMO_PASSWORD")
        else { throw XCTSkip("Jellyfin demo fixture not configured (D-13)") }
        XCTAssertTrue(password.isEmpty, "the demo account's password is empty by design")
        XCTAssertFalse(url.isEmpty); XCTAssertFalse(user.isEmpty)
        app = .launchForRegression()
        // TODO(D-13): assert the Add-Library form's Connect action is ENABLED with
        // the password field left blank, then connect and play one track.
        throw XCTSkip("scaffolded — body pending; see spec §51 D-13")
    }

    /// D-14 · Plex against a locally claimed server.
    func testPlexLocalServerAddsAndPlays() throws {
        _ = try RegressionEnv.require("PH_TEST_PLEX_CLAIM_TOKEN", lane: "Plex (D-14)")
        app = .launchForRegression()
        throw XCTSkip("scaffolded — body pending; see spec §51 D-14")
    }

    // MARK: - Cloud drives

    /// D-17 · Dropbox, Google Drive, OneDrive, pCloud. The connectors are already
    /// registered in `RemoteConnectorCatalog`; this lane proves they work
    /// end-to-end. Blocked on app registrations only the account owner can create.
    func testCloudDriveConnectorsAddAndPlay() throws {
        _ = try RegressionEnv.require("PH_TEST_CLOUD_OAUTH_DROPBOX_APP_KEY",
                                      lane: "cloud drives (D-17)")
        app = .launchForRegression()
        throw XCTSkip("scaffolded — body pending; see spec §51 D-17")
    }
}
