import XCTest

@testable import TonearmCore

final class RemoteIntegrationTests: XCTestCase {
    func testCloudOAuthExchangeBrowseResolveAndRefreshAgainstLocalServer() async throws {
        let baseURL = try integrationBaseURL()

        for provider in CloudDriveAPI.Provider.allCases {
            let config = localOAuthConfig(provider: provider, baseURL: baseURL)
            let authSession = try OAuthAuthorizationSession(
                config: config,
                state: "state-\(provider.rawValue)",
                pkce: OAuthPKCE(verifier: "verifier-1234567890123456789012345678901234567890")
            )
            let callbackURL = URL(string: "tonearm://oauth/\(provider.rawValue)?code=code-1&state=state-\(provider.rawValue)")!
            let token = try await OAuthTokenClient().exchange(session: authSession, callbackURL: callbackURL)

            XCTAssertEqual(token.provider, provider)
            XCTAssertEqual(token.accessToken, "\(provider.rawValue)-access-initial")
            XCTAssertEqual(token.refreshToken, "\(provider.rawValue)-refresh")

            let remote = CloudDriveProvider(
                provider: provider,
                accessProvider: OAuthCloudDriveAccessProvider(token: token)
            )
            let nodes = try await remote.browse(path: "")
            let audio = try XCTUnwrap(nodes.first { $0.kind == .audio }, "\(provider) should expose one audio node")
            let resolved = try await remote.resolve(node: audio)
            XCTAssertFalse(resolved.url.absoluteString.isEmpty)

            let expired = OAuthToken(
                provider: provider,
                accessToken: "expired",
                refreshToken: "\(provider.rawValue)-refresh",
                issuedAt: Date(timeIntervalSince1970: 1),
                expiresAt: Date(timeIntervalSince1970: 2),
                accountLabel: nil,
                clientID: "client-\(provider.rawValue)",
                tokenEndpoint: url(baseURL, "oauth", provider.rawValue, "token"),
                apiEnvironment: CloudDriveAPI.Environment(baseURL: baseURL.appendingPathComponent(provider.rawValue))
            )
            let accessProvider = OAuthCloudDriveAccessProvider(token: expired)
            let refreshed = try await accessProvider.access()
            XCTAssertEqual(refreshed.accessToken, "\(provider.rawValue)-access-refreshed")
        }
    }

    func testServerBackendsBrowseAndResolveAgainstLocalServer() async throws {
        let baseURL = try integrationBaseURL()

        let subsonic = SubsonicProvider(
            baseURL: baseURL.appendingPathComponent("subsonic"),
            username: "alice",
            password: "secret"
        )
        try await subsonic.refresh()
        let subsonicArtists = try await subsonic.browse(path: "")
        let subsonicArtist = try XCTUnwrap(subsonicArtists.first)
        let subsonicAlbums = try await subsonic.browse(path: subsonicArtist.path)
        let subsonicAlbum = try XCTUnwrap(subsonicAlbums.first)
        let subsonicTracks = try await subsonic.browse(path: subsonicAlbum.path)
        let subsonicTrack = try XCTUnwrap(subsonicTracks.first)
        let subsonicAsset = try await subsonic.resolve(node: subsonicTrack)
        XCTAssertTrue(subsonicAsset.url.absoluteString.contains("stream.view"))

        let webDAV = WebDAVProvider(
            baseURL: baseURL.appendingPathComponent("webdav"),
            username: "alice",
            password: "secret"
        )
        try await webDAV.refresh()
        let webDAVNodes = try await webDAV.browse(path: "")
        let webDAVTrack = try XCTUnwrap(webDAVNodes.first { $0.kind == .audio })
        let webDAVAsset = try await webDAV.resolve(node: webDAVTrack)
        XCTAssertTrue(webDAVAsset.url.absoluteString.contains("Track.flac"))

        let jellyfin = JellyfinProvider(
            baseURL: baseURL.appendingPathComponent("jellyfin"),
            userID: "user-1",
            accessToken: "jellyfin-token"
        )
        try await jellyfin.refresh()
        let jellyfinArtists = try await jellyfin.browse(path: "")
        let jellyfinArtist = try XCTUnwrap(jellyfinArtists.first)
        let jellyfinAlbums = try await jellyfin.browse(path: jellyfinArtist.path)
        let jellyfinAlbum = try XCTUnwrap(jellyfinAlbums.first)
        let jellyfinTracks = try await jellyfin.browse(path: jellyfinAlbum.path)
        let jellyfinTrack = try XCTUnwrap(jellyfinTracks.first)
        let jellyfinAsset = try await jellyfin.resolve(node: jellyfinTrack)
        XCTAssertTrue(jellyfinAsset.url.absoluteString.contains("/Audio/track-1/stream"))

        let plex = PlexProvider(
            baseURL: baseURL.appendingPathComponent("plex"),
            token: "plex-token"
        )
        try await plex.refresh()
        let plexSections = try await plex.browse(path: "")
        let plexSection = try XCTUnwrap(plexSections.first)
        let plexArtists = try await plex.browse(path: plexSection.path)
        let plexArtist = try XCTUnwrap(plexArtists.first)
        let plexAlbums = try await plex.browse(path: plexArtist.path)
        let plexAlbum = try XCTUnwrap(plexAlbums.first)
        let plexTracks = try await plex.browse(path: plexAlbum.path)
        let plexTrack = try XCTUnwrap(plexTracks.first)
        let plexAsset = try await plex.resolve(node: plexTrack)
        XCTAssertTrue(plexAsset.url.absoluteString.contains("/plex/audio/test.flac"))
    }

    func testSMBFixtureBrowseAndResolveWithoutNetwork() async throws {
        _ = try integrationBaseURL()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tonearm-smb-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let trackURL = root.appendingPathComponent("Track.flac")
        try Data("audio".utf8).write(to: trackURL)

        let bookmark = try XCTUnwrap(BookmarkVault.makeBookmark(for: root))
        let smb = SMBProvider(rootBookmark: bookmark)
        let nodes = try await smb.browse(path: "")
        let track = try XCTUnwrap(nodes.first { $0.kind == .audio })
        let resolved = try await smb.resolve(node: track)

        XCTAssertEqual(resolved.url.lastPathComponent, "Track.flac")
        XCTAssertFalse(resolved.supportsByteRanges)
    }

    private func integrationBaseURL() throws -> URL {
        guard let raw = ProcessInfo.processInfo.environment["TONEARM_REMOTE_INTEGRATION_BASE_URL"],
              let url = URL(string: raw), url.scheme?.hasPrefix("http") == true else {
            throw XCTSkip("Set TONEARM_REMOTE_INTEGRATION_BASE_URL to run remote integration tests")
        }
        return url
    }

    private func localOAuthConfig(provider: CloudDriveAPI.Provider, baseURL: URL) -> OAuthProviderConfig {
        OAuthProviderConfig(
            provider: provider,
            clientID: "client-\(provider.rawValue)",
            authorizationEndpoint: url(baseURL, "oauth", provider.rawValue, "authorize"),
            tokenEndpoint: url(baseURL, "oauth", provider.rawValue, "token"),
            redirectURI: URL(string: "tonearm://oauth/\(provider.rawValue)")!,
            scopes: ["read"],
            apiEnvironment: CloudDriveAPI.Environment(baseURL: baseURL.appendingPathComponent(provider.rawValue))
        )
    }

    private func url(_ baseURL: URL, _ components: String...) -> URL {
        components.reduce(baseURL) { partial, component in
            partial.appendingPathComponent(component)
        }
    }
}
