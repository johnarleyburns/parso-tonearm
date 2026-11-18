import Testing

@testable import TonearmCore

@Suite struct EmbyAPITests {

    @Test func testAuthenticateRequestAddsDeviceHeaderAndJSONBody() throws {
        let baseURL = try EmbyAPI.normalizeBaseURL("media.example.com/emby/")
        let client = EmbyAPI.Client(name: "TonearmTests", device: "iPhone", deviceID: "device-1", version: "0.1")
        let request = try EmbyAPI.request(
            baseURL: baseURL,
            endpoint: .authenticate(username: "alice", password: "secret"),
            client: client
        )
        let body = try #require(request.httpBody)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])

        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/emby/Users/AuthenticateByName")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(
            request.value(forHTTPHeaderField: "X-Emby-Authorization") ==
            #"MediaBrowser Client="TonearmTests", Device="iPhone", DeviceId="device-1", Version="0.1""#
        )
        #expect(object["Username"] == "alice")
        #expect(object["Pw"] == "secret")
    }

    @Test func testAuthenticatedBrowseRequestBuildsExpectedQuery() throws {
        let request = try EmbyAPI.request(
            baseURL: try EmbyAPI.normalizeBaseURL("https://media.example.com"),
            endpoint: .albums(userID: "user-1", artistID: "artist 1"),
            token: "token-1"
        )
        let components = try #require(URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        #expect(components.path == "/Users/user-1/Items")
        #expect(query["Recursive"] == "true")
        #expect(query["IncludeItemTypes"] == "MusicAlbum")
        #expect(query["AlbumArtistIds"] == "artist 1")
        #expect(query["SortBy"] == "ProductionYear,SortName")
        #expect(request.value(forHTTPHeaderField: "X-Emby-Token") == "token-1")
        #expect(
            request.value(forHTTPHeaderField: "X-Emby-Authorization") ==
            #"MediaBrowser Client="Tonearm", Device="iPhone", DeviceId="tonearm-ios-emby", Version="1.0", Token="token-1""#
        )
    }

    @Test func testStreamRequestUsesAudioEndpointWithoutQueryToken() throws {
        let request = try EmbyAPI.request(
            baseURL: try EmbyAPI.normalizeBaseURL("http://localhost:8096"),
            endpoint: .stream(itemID: "song 1"),
            token: "token-1"
        )

        let components = try #require(URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false))

        #expect(components.percentEncodedPath == "/Audio/song%201/stream")
        #expect(URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?.query == nil)
        #expect(request.value(forHTTPHeaderField: "X-Emby-Token") == "token-1")
    }

    @Test func testAuthenticationResponseDecodesTokenAndUser() throws {
        let auth = try EmbyAPI.decodeAuthentication(data("""
        {
          "User": { "Id": "user-1", "Name": "alice" },
          "AccessToken": "access-token",
          "ServerId": "server-1"
        }
        """))

        #expect(auth == EmbyAuthentication(
            accessToken: "access-token",
            userID: "user-1",
            username: "alice",
            serverID: "server-1"
        ))
    }

    @Test func testItemPageDecodesArtistsAlbumsAndTracks() throws {
        let page = try EmbyAPI.decodeItems(data("""
        {
          "Items": [
            { "Id": "artist-1", "Name": "Biosphere", "Type": "MusicArtist" },
            { "Id": "album-1", "Name": "Substrata", "Type": "MusicAlbum",
              "AlbumArtist": "Biosphere", "ProductionYear": 1997,
              "ImageTags": { "Primary": "album-tag" } },
            { "Id": "track-1", "Name": "Poa Alpina", "Type": "Audio",
              "AlbumId": "album-1", "Album": "Substrata", "AlbumArtist": "Biosphere",
              "Artists": ["Biosphere"], "IndexNumber": 4,
              "AlbumPrimaryImageTag": "album-tag",
              "ParentIndexNumber": 1, "RunTimeTicks": 2820000000,
              "MediaSources": [{ "Size": 98765, "Container": "flac",
                "MediaStreams": [{ "Type": "Audio", "Codec": "flac", "SampleRate": 44100, "BitRate": 879000 }] }] }
          ],
          "TotalRecordCount": 3,
          "StartIndex": 0
        }
        """))

        #expect(page.totalRecordCount == 3)
        #expect(page.items[0].type == .artist)
        #expect(page.items[1].productionYear == 1997)
        #expect(page.items[2].durationSec == 282)
        #expect(page.items[2].sizeBytes == 98_765)
        #expect(page.items[2].container == "flac")
        #expect(page.items[2].albumID == "album-1")
        #expect(page.items[2].albumArtist == "Biosphere")
        #expect(page.items[2].codec == "flac")
        #expect(page.items[2].sampleRate == 44_100)
        #expect(page.items[2].bitRate == 879_000)
        #expect(page.items[2].albumPrimaryImageTag == "album-tag")
    }

    @Test func testImageURLUsesPrimaryImageEndpoint() throws {
        let url = try EmbyAPI.imageURL(
            baseURL: try EmbyAPI.normalizeBaseURL("https://media.example.com/emby"),
            itemID: "album-1",
            tag: "tag-1"
        )
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        #expect(components.path == "/emby/Items/album-1/Images/Primary")
        #expect(query["tag"] == "tag-1")
    }

    @Test func testEmptyLibraryDecodesToEmptyPage() throws {
        let page = try EmbyAPI.decodeItems(data("""
        { "Items": [], "TotalRecordCount": 0, "StartIndex": 0 }
        """))

        #expect(page == EmbyItemPage(items: [], totalRecordCount: 0, startIndex: 0))
    }

    @Test func testUnknownItemTypesArePreserved() throws {
        let page = try EmbyAPI.decodeItems(data("""
        { "Items": [{ "Id": "box-1", "Name": "Box", "Type": "BoxSet" }] }
        """))

        #expect(page.items.first?.type == .unknown("BoxSet"))
    }

    @Test func testMalformedResponsesThrow() {
        do {
            _ = try EmbyAPI.decodeAuthentication(data("{}"))
            Issue.record("expected decodeAuthentication(data(\"{}\")) to throw")
        } catch {
            #expect(error as? EmbyAPI.Error == .missingField("AccessToken"))
        }
        do {
            _ = try EmbyAPI.decodeItems(data("{}"))
            Issue.record("expected decodeItems(data(\"{}\")) to throw")
        } catch {
            #expect(error as? EmbyAPI.Error == .missingField("Items"))
        }
        do {
            _ = try EmbyAPI.decodeItems(data("not-json"))
            Issue.record("expected decodeItems(data(\"not-json\")) to throw")
        } catch {
            #expect(error as? EmbyAPI.Error == .malformedResponse)
        }
    }

    @Test func testServerFormPolicy() throws {
        let url = try EmbyServerPolicy.normalizeBaseURL("localhost:8096")

        #expect(url.absoluteString == "https://localhost:8096")
        #expect(EmbyServerPolicy.canSubmit(url: "http://localhost:8096", username: "alice", password: "secret"))
        #expect(EmbyServerPolicy.canSubmit(url: "http://localhost:8096", username: "demo", password: ""))
        #expect(!EmbyServerPolicy.canSubmit(url: "ftp://localhost", username: "alice", password: "secret"))
        #expect(!EmbyServerPolicy.canSubmit(url: "http://localhost", username: "", password: "secret"))
    }

    private func data(_ string: String) -> Data {
        Data(string.utf8)
    }
}
