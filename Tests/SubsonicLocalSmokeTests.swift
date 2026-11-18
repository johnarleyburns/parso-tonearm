import Testing
@testable import TonearmCore

@Suite struct SubsonicLocalSmokeTests {
    @Test func testLocalSubsonicBrowseResolveSmokeWhenConfigured() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let rawURL = env["TONEARM_SUBSONIC_TEST_URL"],
              let user = env["TONEARM_SUBSONIC_TEST_USER"],
              let password = env["TONEARM_SUBSONIC_TEST_PASSWORD"],
              !rawURL.isEmpty,
              !user.isEmpty,
              !password.isEmpty else {
            try Test.cancel("Set TONEARM_SUBSONIC_TEST_URL, TONEARM_SUBSONIC_TEST_USER, and TONEARM_SUBSONIC_TEST_PASSWORD")
        }

        let provider = SubsonicProvider(
            baseURL: try SubsonicAPI.normalizeBaseURL(rawURL),
            username: user,
            password: password
        )
        try await provider.refresh()

        let artists = try await provider.browse(path: "")
        let artist = try #require(artists.first, "Configured Subsonic server has no artists to browse")
        let albums = try await provider.browse(path: artist.path)
        let album = try #require(albums.first, "Configured Subsonic server has no albums to browse")
        let tracks = try await provider.browse(path: album.path)
        let track = try #require(tracks.first { $0.kind == .audio }, "Configured Subsonic server has no playable audio")
        let asset = try await provider.resolve(node: track)

        #expect(asset.url.absoluteString.contains("stream.view"))
        #expect(asset.metadata?.title == track.metadata?.title)
        #expect((track.metadata?.artist ?? track.metadata?.albumArtist) != nil)
    }
}
