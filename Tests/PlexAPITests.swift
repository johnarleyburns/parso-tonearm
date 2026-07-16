import XCTest

@testable import TonearmCore

final class PlexAPITests: XCTestCase {

    func testSectionsRequestAddsPlexHeaders() throws {
        let request = try PlexAPI.request(
            baseURL: try PlexAPI.normalizeBaseURL("localhost:32400"),
            endpoint: .sections,
            token: "plex-token",
            client: PlexAPI.Client(product: "TonearmTests", version: "0.1", platform: "iOS", clientIdentifier: "client-1")
        )

        XCTAssertEqual(request.url?.absoluteString, "http://localhost:32400/library/sections")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/xml")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Plex-Token"), "plex-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Plex-Product"), "TonearmTests")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Plex-Pms-Api-Version"), "1.0")
    }

    func testArtistAndChildrenRequestsUseStableMusicEndpoints() throws {
        let artistRequest = try PlexAPI.request(
            baseURL: try PlexAPI.normalizeBaseURL("https://plex.example.com"),
            endpoint: .artists(sectionKey: "3"),
            token: "token"
        )
        let artistComponents = try XCTUnwrap(URLComponents(url: try XCTUnwrap(artistRequest.url), resolvingAgainstBaseURL: false))
        let artistQuery = Dictionary(uniqueKeysWithValues: (artistComponents.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        XCTAssertEqual(artistComponents.path, "/library/sections/3/all")
        XCTAssertEqual(artistQuery["type"], "8")
        XCTAssertEqual(artistQuery["includeFields"], "title,type,ratingKey,key")

        let childrenRequest = try PlexAPI.request(
            baseURL: try PlexAPI.normalizeBaseURL("https://plex.example.com"),
            endpoint: .children(ratingKey: "44"),
            token: "token"
        )
        XCTAssertEqual(childrenRequest.url?.path, "/library/metadata/44/children")
    }

    func testDecodesLibrarySections() throws {
        let sections = try PlexAPI.decodeSections(data("""
        <MediaContainer size="2">
          <Directory key="1" title="Music" type="artist" />
          <Directory key="2" title="Movies" type="movie" />
        </MediaContainer>
        """))

        XCTAssertEqual(sections, [
            PlexItem(ratingKey: nil, key: "1", title: "Music", kind: .section,
                     durationSec: nil, sizeBytes: nil, partKey: nil),
        ])
    }

    func testDecodesArtistsAndAlbumsWithEscapedTitles() throws {
        let items = try PlexAPI.decodeItems(data("""
        <MediaContainer size="2">
          <Directory ratingKey="100" key="/library/metadata/100/children"
                     title="A Winged Victory &amp; Dustin O'Halloran" type="artist" />
          <Directory ratingKey="200" key="/library/metadata/200/children"
                     title="The Undivided Five" type="album" duration="2850000" />
        </MediaContainer>
        """))

        XCTAssertEqual(items[0].kind, .artist)
        XCTAssertEqual(items[0].title, "A Winged Victory & Dustin O'Halloran")
        XCTAssertEqual(items[1].kind, .album)
        XCTAssertEqual(items[1].durationSec, 2_850)
    }

    func testDecodesTrackPartMetadata() throws {
        let track = try PlexAPI.decodeTrackMetadata(data("""
        <MediaContainer size="1">
          <Track ratingKey="300" key="/library/metadata/300" title="Poa Alpina"
                 type="track" duration="282000">
            <Media id="400" duration="282000">
              <Part id="500" key="/library/parts/500/1700000000/file.flac"
                    size="98765" container="flac" />
            </Media>
          </Track>
        </MediaContainer>
        """))

        XCTAssertEqual(track.ratingKey, "300")
        XCTAssertEqual(track.kind, .track)
        XCTAssertEqual(track.durationSec, 282)
        XCTAssertEqual(track.partKey, "/library/parts/500/1700000000/file.flac")
        XCTAssertEqual(track.sizeBytes, 98_765)
    }

    func testMalformedAndIncompleteResponsesThrow() {
        XCTAssertThrowsError(try PlexAPI.decodeItems(data("<not-plex />"))) { error in
            XCTAssertEqual(error as? PlexAPI.Error, .malformedResponse)
        }
        XCTAssertThrowsError(try PlexAPI.decodeTrackMetadata(data("""
        <MediaContainer size="1">
          <Track ratingKey="300" key="/library/metadata/300" title="Poa Alpina" type="track" />
        </MediaContainer>
        """))) { error in
            XCTAssertEqual(error as? PlexAPI.Error, .missingField("Track.Part.key"))
        }
    }

    func testServerFormPolicy() throws {
        let url = try PlexServerPolicy.normalizeBaseURL("plex.example.com:32400")

        XCTAssertEqual(url.absoluteString, "http://plex.example.com:32400")
        XCTAssertTrue(PlexServerPolicy.canSubmit(url: "https://plex.example.com", token: "token"))
        XCTAssertFalse(PlexServerPolicy.canSubmit(url: "ftp://plex.example.com", token: "token"))
        XCTAssertFalse(PlexServerPolicy.canSubmit(url: "https://plex.example.com", token: " "))
    }

    private func data(_ string: String) -> Data {
        Data(string.utf8)
    }
}
