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

        // Verify that bad auth is rejected for non-cloud backends.
        let badSubsonic = SubsonicProvider(
            baseURL: baseURL.appendingPathComponent("subsonic"),
            username: "evil",
            password: "wrong"
        )
        do {
            _ = try await badSubsonic.refresh()
            XCTFail("Bad subsonic credentials should be rejected")
        } catch {
            XCTAssertNotNil(error as? URLError)
        }

        let badWebDAV = WebDAVProvider(
            baseURL: baseURL.appendingPathComponent("webdav"),
            username: "evil",
            password: "wrong"
        )
        do {
            _ = try await badWebDAV.refresh()
            XCTFail("Bad webdav credentials should be rejected")
        } catch {
            XCTAssertNotNil(error as? URLError)
        }

        let badJellyfin = JellyfinProvider(
            baseURL: baseURL.appendingPathComponent("jellyfin"),
            userID: "user-1",
            accessToken: "wrong-token"
        )
        do {
            _ = try await badJellyfin.refresh()
            XCTFail("Bad jellyfin token should be rejected")
        } catch {
            XCTAssertNotNil(error as? URLError)
        }

        let badPlex = PlexProvider(
            baseURL: baseURL.appendingPathComponent("plex"),
            token: "wrong-plex-token"
        )
        do {
            _ = try await badPlex.refresh()
            XCTFail("Bad plex token should be rejected")
        } catch {
            XCTAssertNotNil(error as? URLError)
        }

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
        XCTAssertEqual(subsonicTrack.metadata?.artist, "Artist")
        XCTAssertEqual(subsonicTrack.metadata?.album, "Album")
        XCTAssertEqual(subsonicTrack.metadata?.trackNumber, 1)
        XCTAssertEqual(subsonicTrack.metadata?.codec, "FLAC")
        XCTAssertEqual(subsonicTrack.metadata?.sampleRate, 44_100)
        XCTAssertEqual(subsonicTrack.metadata?.bitRateKbps, 900)
        XCTAssertTrue(subsonicTrack.metadata?.artwork?.url?.absoluteString.contains("getCoverArt.view") == true)
        let subsonicAsset = try await subsonic.resolve(node: subsonicTrack)
        XCTAssertTrue(subsonicAsset.url.absoluteString.contains("stream.view"))
        try await assertAudioRequest(subsonicAsset, expectedStatus: 206)
        try await assertArtworkRequest(subsonicTrack.metadata?.artwork)

        let subsonicNonRange = SubsonicProvider(
            baseURL: baseURL.appendingPathComponent("subsonic-nonrange"),
            username: "alice",
            password: "secret"
        )
        try await subsonicNonRange.refresh()
        let nonRangeArtists = try await subsonicNonRange.browse(path: "")
        let nonRangeArtist = try XCTUnwrap(nonRangeArtists.first)
        let nonRangeAlbums = try await subsonicNonRange.browse(path: nonRangeArtist.path)
        let nonRangeAlbum = try XCTUnwrap(nonRangeAlbums.first)
        let nonRangeTracks = try await subsonicNonRange.browse(path: nonRangeAlbum.path)
        let nonRangeTrack = try XCTUnwrap(nonRangeTracks.first)
        let nonRangeAsset = try await subsonicNonRange.resolve(node: nonRangeTrack)
        try await assertAudioRequest(nonRangeAsset, expectedStatus: 200)

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
        XCTAssertEqual(jellyfinTrack.metadata?.artist, "Artist")
        XCTAssertEqual(jellyfinTrack.metadata?.album, "Album")
        XCTAssertEqual(jellyfinTrack.metadata?.trackNumber, 1)
        XCTAssertEqual(jellyfinTrack.metadata?.codec, "FLAC")
        XCTAssertEqual(jellyfinTrack.metadata?.sampleRate, 44_100)
        XCTAssertEqual(jellyfinTrack.metadata?.bitRateKbps, 900)
        let jellyfinAsset = try await jellyfin.resolve(node: jellyfinTrack)
        XCTAssertTrue(jellyfinAsset.url.absoluteString.contains("/Audio/track-1/stream"))
        XCTAssertNotNil(jellyfinAsset.headers["X-Emby-Authorization"])
        try await assertAudioRequest(jellyfinAsset, expectedStatus: 206)
        try await assertArtworkRequest(jellyfinTrack.metadata?.artwork)

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
        XCTAssertEqual(plexTrack.metadata?.artist, "Artist")
        XCTAssertEqual(plexTrack.metadata?.album, "Album")
        XCTAssertEqual(plexTrack.metadata?.trackNumber, 1)
        XCTAssertEqual(plexTrack.metadata?.codec, "FLAC")
        let plexAsset = try await plex.resolve(node: plexTrack)
        XCTAssertTrue(plexAsset.url.absoluteString.contains("/plex/audio/test.flac"))
        XCTAssertNotNil(plexAsset.headers["X-Plex-Token"])
        try await assertAudioRequest(plexAsset, expectedStatus: 206)
        try await assertArtworkRequest(plexAsset.metadata?.artwork)
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

    func testCloudOAuthReconnectRequiredOnInvalidRefreshToken() async throws {
        let baseURL = try integrationBaseURL()
        let provider = CloudDriveAPI.Provider.dropbox
        let token = OAuthToken(
            provider: provider,
            accessToken: "stale",
            refreshToken: "bogus-refresh",
            issuedAt: Date(timeIntervalSince1970: 1),
            expiresAt: Date(timeIntervalSince1970: 2),
            accountLabel: nil,
            clientID: "client-\(provider.rawValue)",
            tokenEndpoint: url(baseURL, "oauth", provider.rawValue, "token"),
            apiEnvironment: CloudDriveAPI.Environment(baseURL: baseURL.appendingPathComponent(provider.rawValue))
        )
        let accessProvider = OAuthCloudDriveAccessProvider(token: token)
        do {
            _ = try await accessProvider.access()
            XCTFail("Refresh with bogus token should throw")
        } catch let error as OAuthError {
            XCTAssertEqual(error, .refreshRequired)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCloudOAuthReconnectRequiredWithoutRefreshToken() async throws {
        let baseURL = try integrationBaseURL()
        let provider = CloudDriveAPI.Provider.googleDrive
        let token = OAuthToken(
            provider: provider,
            accessToken: "stale",
            refreshToken: nil,
            issuedAt: Date(timeIntervalSince1970: 1),
            expiresAt: Date(timeIntervalSince1970: 2),
            accountLabel: nil,
            clientID: "client-\(provider.rawValue)",
            tokenEndpoint: url(baseURL, "oauth", provider.rawValue, "token"),
            apiEnvironment: CloudDriveAPI.Environment(baseURL: baseURL.appendingPathComponent(provider.rawValue))
        )
        let accessProvider = OAuthCloudDriveAccessProvider(token: token)
        do {
            _ = try await accessProvider.access()
            XCTFail("Refresh without refresh token should throw")
        } catch let error as OAuthError {
            XCTAssertEqual(error, .refreshRequired)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCloudDriveBrowseRejectedWithBadAccessToken() async throws {
        let baseURL = try integrationBaseURL()
        let provider = CloudDriveAPI.Provider.oneDrive
        let remote = CloudDriveProvider(
            provider: provider,
            accessToken: "bad-access-token",
            session: .shared,
            environment: CloudDriveAPI.Environment(baseURL: baseURL.appendingPathComponent(provider.rawValue))
        )
        do {
            _ = try await remote.browse(path: "")
            XCTFail("Browse with bad token should throw")
        } catch {
            XCTAssertNotNil(error as? URLError)
        }
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

    private func assertAudioRequest(_ asset: ResolvedAsset, expectedStatus: Int) async throws {
        var request = URLRequest(url: asset.url)
        for (field, value) in asset.headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")

        let (_, response) = try await URLSession.shared.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, expectedStatus)
        if expectedStatus == 206 {
            XCTAssertEqual(
                RemoteStreamingResponsePolicy.probeResult(
                    statusCode: http.statusCode,
                    contentRange: http.value(forHTTPHeaderField: "Content-Range"),
                    expectedContentLength: http.expectedContentLength
                ),
                .ranged(totalBytes: Int64("tonearm-remote-test-audio".utf8.count))
            )
        } else if expectedStatus == 200 {
            XCTAssertEqual(
                RemoteStreamingResponsePolicy.probeResult(
                    statusCode: http.statusCode,
                    contentRange: nil,
                    expectedContentLength: http.expectedContentLength
                ),
                .fullBody(totalBytes: Int64("tonearm-remote-test-audio".utf8.count))
            )
        }
    }

    private func assertArtworkRequest(_ artwork: RemoteArtwork?) async throws {
        let artwork = try XCTUnwrap(artwork)
        let url = try XCTUnwrap(artwork.url)
        var request = URLRequest(url: url)
        for (field, value) in artwork.headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)
        XCTAssertFalse(data.isEmpty)
    }
}
