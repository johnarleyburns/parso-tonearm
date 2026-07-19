import XCTest
@testable import TonearmCore

final class SubsonicLocalSmokeTests: XCTestCase {
    func testLocalSubsonicBrowseResolveSmokeWhenConfigured() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let rawURL = env["TONEARM_SUBSONIC_TEST_URL"],
              let user = env["TONEARM_SUBSONIC_TEST_USER"],
              let password = env["TONEARM_SUBSONIC_TEST_PASSWORD"],
              !rawURL.isEmpty,
              !user.isEmpty,
              !password.isEmpty else {
            throw XCTSkip("Set TONEARM_SUBSONIC_TEST_URL, TONEARM_SUBSONIC_TEST_USER, and TONEARM_SUBSONIC_TEST_PASSWORD")
        }

        let provider = SubsonicProvider(
            baseURL: try SubsonicAPI.normalizeBaseURL(rawURL),
            username: user,
            password: password
        )
        try await provider.refresh()

        let artists = try await provider.browse(path: "")
        let artist = try XCTUnwrap(artists.first, "Configured Subsonic server has no artists to browse")
        let albums = try await provider.browse(path: artist.path)
        let album = try XCTUnwrap(albums.first, "Configured Subsonic server has no albums to browse")
        let tracks = try await provider.browse(path: album.path)
        let track = try XCTUnwrap(tracks.first { $0.kind == .audio }, "Configured Subsonic server has no playable audio")
        let asset = try await provider.resolve(node: track)

        XCTAssertTrue(asset.url.absoluteString.contains("stream.view"))
        XCTAssertEqual(asset.metadata?.title, track.metadata?.title)
        XCTAssertNotNil(track.metadata?.artist ?? track.metadata?.albumArtist)
    }
}
