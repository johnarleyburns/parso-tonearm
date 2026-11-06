import XCTest

@testable import TonearmCore

final class SubsonicAPITests: XCTestCase {

    func testSaltedTokenKnownVector() {
        XCTAssertEqual(
            SubsonicAPI.token(password: "password", salt: "salt"),
            "b305cadbb3bce54f3aa59c64fec00dea"
        )
    }

    func testURLConstructionNormalizesBaseAndAddsTokenAuth() throws {
        let baseURL = try SubsonicAPI.normalizeBaseURL("music.example.com/navidrome/")
        let auth = SubsonicAPI.Auth(
            username: "alice",
            password: "password",
            salt: "salt",
            apiVersion: "1.16.1",
            client: "TonearmTests"
        )

        let url = try SubsonicAPI.url(
            baseURL: baseURL,
            endpoint: .stream(id: "song 1"),
            auth: auth,
            format: .json
        )
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "music.example.com")
        XCTAssertEqual(components.path, "/navidrome/rest/stream.view")
        XCTAssertEqual(query["u"], "alice")
        XCTAssertEqual(query["t"], "b305cadbb3bce54f3aa59c64fec00dea")
        XCTAssertEqual(query["s"], "salt")
        XCTAssertEqual(query["v"], "1.16.1")
        XCTAssertEqual(query["c"], "TonearmTests")
        XCTAssertEqual(query["f"], "json")
        XCTAssertEqual(query["id"], "song 1")
    }

    func testServerFormPolicy() throws {
        let url = try SubsonicServerPolicy.normalizeBaseURL("http://localhost:4533/")

        XCTAssertEqual(url.absoluteString, "http://localhost:4533/")
        XCTAssertTrue(SubsonicServerPolicy.canSubmit(
            url: "http://localhost:4533",
            username: "user",
            password: "secret"
        ))
        XCTAssertFalse(SubsonicServerPolicy.canSubmit(
            url: "ftp://localhost",
            username: "user",
            password: "secret"
        ))
    }

    func testDecodesNavidromeJSONArtists() throws {
        let artists = try SubsonicAPI.decodeArtists(data("""
        {
          "subsonic-response": {
            "status": "ok",
            "version": "1.16.1",
            "type": "navidrome",
            "serverVersion": "0.53.3",
            "artists": {
              "ignoredArticles": "The",
              "index": [
                { "name": "A", "artist": [
                  { "id": "artist-1", "name": "A Winged Victory", "albumCount": 2 }
                ] }
              ]
            }
          }
        }
        """), format: .json)

        XCTAssertEqual(artists, [
            SubsonicArtist(id: "artist-1", name: "A Winged Victory", albumCount: 2)
        ])
    }

    func testDecodesSubsonicXMLIndexes() throws {
        let artists = try SubsonicAPI.decodeArtists(data("""
        <subsonic-response status="ok" version="1.16.1">
          <indexes ignoredArticles="The">
            <index name="B">
              <artist id="artist-2" name="Biosphere" albumCount="4" />
            </index>
          </indexes>
        </subsonic-response>
        """), format: .xml)

        XCTAssertEqual(artists, [
            SubsonicArtist(id: "artist-2", name: "Biosphere", albumCount: 4)
        ])
    }

    func testDecodesArtistCoverArtJSONAndXML() throws {
        let jsonArtists = try SubsonicAPI.decodeArtists(data("""
        {
          "subsonic-response": {
            "status": "ok",
            "version": "1.16.1",
            "artists": {
              "index": [
                { "name": "A", "artist": [
                  { "id": "artist-1", "name": "A Winged Victory", "albumCount": 2, "coverArt": "ar-artist-1_0" }
                ] }
              ]
            }
          }
        }
        """), format: .json)
        XCTAssertEqual(jsonArtists, [
            SubsonicArtist(id: "artist-1", name: "A Winged Victory", albumCount: 2, coverArt: "ar-artist-1_0")
        ])

        let xmlArtists = try SubsonicAPI.decodeArtists(data("""
        <subsonic-response status="ok" version="1.16.1">
          <indexes ignoredArticles="The">
            <index name="B">
              <artist id="artist-2" name="Biosphere" albumCount="4" coverArt="ar-artist-2_0" />
            </index>
          </indexes>
        </subsonic-response>
        """), format: .xml)
        XCTAssertEqual(xmlArtists, [
            SubsonicArtist(id: "artist-2", name: "Biosphere", albumCount: 4, coverArt: "ar-artist-2_0")
        ])
    }

    func testDecodesJSONArtistDetailAlbums() throws {
        let artist = try SubsonicAPI.decodeArtist(data("""
        {
          "subsonic-response": {
            "status": "ok",
            "artist": {
              "id": "artist-1",
              "name": "A Winged Victory",
              "album": [
                { "id": "album-1", "name": "The Undivided Five", "artist": "A Winged Victory",
                  "songCount": 9, "year": 2019, "genre": "Classical" }
              ]
            }
          }
        }
        """), format: .json)

        XCTAssertEqual(artist.id, "artist-1")
        XCTAssertEqual(artist.albums.first?.id, "album-1")
        XCTAssertEqual(artist.albums.first?.songCount, 9)
    }

    func testDecodesXMLArtistDetailAlbums() throws {
        let artist = try SubsonicAPI.decodeArtist(data("""
        <subsonic-response status="ok" version="1.16.1">
          <artist id="artist-3" name="Loscil">
            <album id="album-3" name="Clara" artist="Loscil" songCount="11" year="2021" genre="Ambient" />
          </artist>
        </subsonic-response>
        """), format: .xml)

        XCTAssertEqual(artist.name, "Loscil")
        XCTAssertEqual(artist.albums, [
            SubsonicAlbumSummary(id: "album-3", name: "Clara", artist: "Loscil",
                                 artistId: nil, songCount: 11, year: 2021, genre: "Ambient")
        ])
    }

    func testDecodesJSONAlbumSongs() throws {
        let album = try SubsonicAPI.decodeAlbum(data("""
        {
          "subsonic-response": {
            "status": "ok",
            "album": {
              "id": "album-1",
              "name": "The Undivided Five",
              "artist": "A Winged Victory",
              "artistId": "artist-1",
              "year": 2019,
              "genre": "Classical",
              "song": [
                { "id": "song-1", "title": "Our Lord Debussy", "album": "The Undivided Five",
                  "albumId": "album-1", "artist": "A Winged Victory", "track": 1,
                  "discNumber": 1, "duration": 312, "suffix": "flac",
                  "contentType": "audio/flac", "size": 123456, "bitRate": 879,
                  "samplingRate": 44100, "coverArt": "cover-1" }
              ]
            }
          }
        }
        """), format: .json)

        XCTAssertEqual(album.id, "album-1")
        XCTAssertEqual(album.songs.first?.title, "Our Lord Debussy")
        XCTAssertEqual(album.songs.first?.duration, 312)
        XCTAssertEqual(album.songs.first?.size, 123_456)
        XCTAssertEqual(album.songs.first?.coverArt, "cover-1")
    }

    func testCoverArtURLConstructionUsesAuthenticatedEndpoint() throws {
        let baseURL = try SubsonicAPI.normalizeBaseURL("https://music.example.com")
        let auth = SubsonicAPI.Auth(
            username: "alice",
            password: "password",
            salt: "salt",
            apiVersion: "1.16.1",
            client: "TonearmTests"
        )

        let url = try SubsonicAPI.url(
            baseURL: baseURL,
            endpoint: .coverArt(id: "cover 1"),
            auth: auth,
            format: .json
        )
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        XCTAssertEqual(components.path, "/rest/getCoverArt.view")
        XCTAssertEqual(query["id"], "cover 1")
        XCTAssertEqual(query["u"], "alice")
        XCTAssertEqual(query["t"], "b305cadbb3bce54f3aa59c64fec00dea")
    }

    func testDecodesXMLAlbumSongs() throws {
        let album = try SubsonicAPI.decodeAlbum(data("""
        <subsonic-response status="ok" version="1.16.1">
          <album id="album-4" name="Substrata" artist="Biosphere" year="1997" genre="Ambient">
            <song id="song-4" title="Poa Alpina" album="Substrata" albumId="album-4"
                  artist="Biosphere" track="4" duration="282" suffix="mp3"
                  contentType="audio/mpeg" size="98765" bitRate="320" samplingRate="44100" />
          </album>
        </subsonic-response>
        """), format: .xml)

        XCTAssertEqual(album.name, "Substrata")
        XCTAssertEqual(album.songs, [
            SubsonicSong(id: "song-4", title: "Poa Alpina", album: "Substrata",
                         albumId: "album-4", artist: "Biosphere", artistId: nil,
                         track: 4, discNumber: nil, duration: 282, suffix: "mp3",
                         contentType: "audio/mpeg", size: 98_765, bitRate: 320,
                         samplingRate: 44_100)
        ])
    }

    func testRemoteErrorCodes() {
        let fixtures: [(Int, String)] = [
            (40, "Wrong username or password"),
            (60, "Trial period expired"),
            (70, "Requested data was not found"),
        ]

        for (code, message) in fixtures {
            XCTAssertThrowsError(try SubsonicAPI.decodePing(data("""
            { "subsonic-response": {
                "status": "failed",
                "error": { "code": \(code), "message": "\(message)" }
            } }
            """), format: .json)) { error in
                XCTAssertEqual(error as? SubsonicAPI.Error, .remote(code: code, message: message))
            }
        }
    }

    func testEmptyLibraryDecodesToNoArtists() throws {
        let artists = try SubsonicAPI.decodeArtists(data("""
        { "subsonic-response": {
            "status": "ok",
            "artists": { "ignoredArticles": "The", "index": [] }
        } }
        """), format: .json)

        XCTAssertEqual(artists, [])
    }

    func testMalformedResponsesThrow() {
        XCTAssertThrowsError(try SubsonicAPI.decodeArtists(data("{}"), format: .json)) { error in
            XCTAssertEqual(error as? SubsonicAPI.Error, .malformedResponse)
        }
        XCTAssertThrowsError(try SubsonicAPI.decodeArtists(data("<not-subsonic />"), format: .xml)) { error in
            XCTAssertEqual(error as? SubsonicAPI.Error, .malformedResponse)
        }
    }

    private func data(_ string: String) -> Data {
        Data(string.utf8)
    }
}

// MARK: - Partial Subsonic implementations (Ampache/Funkwhale hardening)

/// Always answers with a server-error status, regardless of which Subsonic endpoint was
/// requested — enough to simulate a server (e.g. a Funkwhale pod with Subsonic access disabled,
/// per Funkwhale's own docs) where neither getArtists nor getIndexes is reachable.
private final class AlwaysFailingSubsonicStub: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: "1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class SubsonicProviderPartialImplementationTests: XCTestCase {
    private func makeProvider() -> SubsonicProvider {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AlwaysFailingSubsonicStub.self]
        return SubsonicProvider(
            baseURL: URL(string: "https://pod.example.test")!,
            username: "alice",
            password: "password",
            session: URLSession(configuration: config)
        )
    }

    func testRootBrowseReturnsAnEmptyLibraryRatherThanThrowingWhenNeitherArtistEndpointIsReachable() async throws {
        // Real gap this hardens: Funkwhale's own docs say it implements only "a subset" of the
        // Subsonic API, and a pod admin can disable Subsonic access entirely server-wide — once
        // AppState.addSubsonicServer's own ping has already validated the connection/credentials
        // at add time, a later failure here reads as "nothing reachable through this API," which
        // the existing "No music found" empty-browse state already represents honestly, not as a
        // hard error that blocks the whole library from opening.
        let nodes = try await makeProvider().browse(path: "")
        XCTAssertEqual(nodes, [])
    }
}
