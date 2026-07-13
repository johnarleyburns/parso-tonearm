import XCTest

@testable import Tonearm

final class JellyfinAPITests: XCTestCase {

    func testAuthenticateRequestAddsDeviceHeaderAndJSONBody() throws {
        let baseURL = try JellyfinAPI.normalizeBaseURL("media.example.com/jellyfin/")
        let client = JellyfinAPI.Client(name: "TonearmTests", device: "iPhone", deviceID: "device-1", version: "0.1")
        let request = try JellyfinAPI.request(
            baseURL: baseURL,
            endpoint: .authenticate(username: "alice", password: "secret"),
            client: client
        )
        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])

        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/jellyfin/Users/AuthenticateByName")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "X-Emby-Authorization"),
            #"MediaBrowser Client="TonearmTests", Device="iPhone", DeviceId="device-1", Version="0.1""#
        )
        XCTAssertEqual(object["Username"], "alice")
        XCTAssertEqual(object["Pw"], "secret")
    }

    func testAuthenticatedBrowseRequestBuildsExpectedQuery() throws {
        let request = try JellyfinAPI.request(
            baseURL: try JellyfinAPI.normalizeBaseURL("https://media.example.com"),
            endpoint: .albums(userID: "user-1", artistID: "artist 1"),
            token: "token-1"
        )
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        XCTAssertEqual(components.path, "/Users/user-1/Items")
        XCTAssertEqual(query["Recursive"], "true")
        XCTAssertEqual(query["IncludeItemTypes"], "MusicAlbum")
        XCTAssertEqual(query["AlbumArtistIds"], "artist 1")
        XCTAssertEqual(query["SortBy"], "ProductionYear,SortName")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Emby-Token"), "token-1")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "X-Emby-Authorization"),
            #"MediaBrowser Client="Tonearm", Device="iPhone", DeviceId="tonearm-ios", Version="1.0", Token="token-1""#
        )
    }

    func testStreamRequestUsesAudioEndpointWithoutQueryToken() throws {
        let request = try JellyfinAPI.request(
            baseURL: try JellyfinAPI.normalizeBaseURL("http://localhost:8096"),
            endpoint: .stream(itemID: "song 1"),
            token: "token-1"
        )

        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))

        XCTAssertEqual(components.percentEncodedPath, "/Audio/song%201/stream")
        XCTAssertNil(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.query)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Emby-Token"), "token-1")
    }

    func testAuthenticationResponseDecodesTokenAndUser() throws {
        let auth = try JellyfinAPI.decodeAuthentication(data("""
        {
          "User": { "Id": "user-1", "Name": "alice" },
          "AccessToken": "access-token",
          "ServerId": "server-1"
        }
        """))

        XCTAssertEqual(auth, JellyfinAuthentication(
            accessToken: "access-token",
            userID: "user-1",
            username: "alice",
            serverID: "server-1"
        ))
    }

    func testItemPageDecodesArtistsAlbumsAndTracks() throws {
        let page = try JellyfinAPI.decodeItems(data("""
        {
          "Items": [
            { "Id": "artist-1", "Name": "Biosphere", "Type": "MusicArtist" },
            { "Id": "album-1", "Name": "Substrata", "Type": "MusicAlbum",
              "AlbumArtist": "Biosphere", "ProductionYear": 1997 },
            { "Id": "track-1", "Name": "Poa Alpina", "Type": "Audio",
              "Album": "Substrata", "Artists": ["Biosphere"], "IndexNumber": 4,
              "ParentIndexNumber": 1, "RunTimeTicks": 2820000000,
              "MediaSources": [{ "Size": 98765, "Container": "flac" }] }
          ],
          "TotalRecordCount": 3,
          "StartIndex": 0
        }
        """))

        XCTAssertEqual(page.totalRecordCount, 3)
        XCTAssertEqual(page.items[0].type, .artist)
        XCTAssertEqual(page.items[1].productionYear, 1997)
        XCTAssertEqual(page.items[2].durationSec, 282)
        XCTAssertEqual(page.items[2].sizeBytes, 98_765)
        XCTAssertEqual(page.items[2].container, "flac")
    }

    func testEmptyLibraryDecodesToEmptyPage() throws {
        let page = try JellyfinAPI.decodeItems(data("""
        { "Items": [], "TotalRecordCount": 0, "StartIndex": 0 }
        """))

        XCTAssertEqual(page, JellyfinItemPage(items: [], totalRecordCount: 0, startIndex: 0))
    }

    func testUnknownItemTypesArePreserved() throws {
        let page = try JellyfinAPI.decodeItems(data("""
        { "Items": [{ "Id": "box-1", "Name": "Box", "Type": "BoxSet" }] }
        """))

        XCTAssertEqual(page.items.first?.type, .unknown("BoxSet"))
    }

    func testMalformedResponsesThrow() {
        XCTAssertThrowsError(try JellyfinAPI.decodeAuthentication(data("{}"))) { error in
            XCTAssertEqual(error as? JellyfinAPI.Error, .missingField("AccessToken"))
        }
        XCTAssertThrowsError(try JellyfinAPI.decodeItems(data("{}"))) { error in
            XCTAssertEqual(error as? JellyfinAPI.Error, .missingField("Items"))
        }
        XCTAssertThrowsError(try JellyfinAPI.decodeItems(data("not-json"))) { error in
            XCTAssertEqual(error as? JellyfinAPI.Error, .malformedResponse)
        }
    }

    func testServerFormPolicy() throws {
        let url = try JellyfinServerPolicy.normalizeBaseURL("localhost:8096")

        XCTAssertEqual(url.absoluteString, "https://localhost:8096")
        XCTAssertTrue(JellyfinServerPolicy.canSubmit(url: "http://localhost:8096", username: "alice", password: "secret"))
        XCTAssertFalse(JellyfinServerPolicy.canSubmit(url: "ftp://localhost", username: "alice", password: "secret"))
        XCTAssertFalse(JellyfinServerPolicy.canSubmit(url: "http://localhost", username: "", password: "secret"))
    }

    private func data(_ string: String) -> Data {
        Data(string.utf8)
    }
}
