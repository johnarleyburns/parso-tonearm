import Foundation
import Testing

@testable import TonearmCore

@Suite struct PlexAPITests {

    @Test func testSectionsRequestAddsPlexHeaders() throws {
        let request = try PlexAPI.request(
            baseURL: try PlexAPI.normalizeBaseURL("localhost:32400"),
            endpoint: .sections,
            token: "plex-token",
            client: PlexAPI.Client(product: "TonearmTests", version: "0.1", platform: "iOS", clientIdentifier: "client-1")
        )

        #expect(request.url?.absoluteString == "http://localhost:32400/library/sections")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/xml")
        #expect(request.value(forHTTPHeaderField: "X-Plex-Token") == "plex-token")
        #expect(request.value(forHTTPHeaderField: "X-Plex-Product") == "TonearmTests")
        #expect(request.value(forHTTPHeaderField: "X-Plex-Pms-Api-Version") == "1.0")
    }

    @Test func testArtistAndChildrenRequestsUseStableMusicEndpoints() throws {
        let artistRequest = try PlexAPI.request(
            baseURL: try PlexAPI.normalizeBaseURL("https://plex.example.com"),
            endpoint: .artists(sectionKey: "3"),
            token: "token"
        )
        let artistComponents = try #require(URLComponents(url: try #require(artistRequest.url), resolvingAgainstBaseURL: false))
        let artistQuery = Dictionary(uniqueKeysWithValues: (artistComponents.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        #expect(artistComponents.path == "/library/sections/3/all")
        #expect(artistQuery["type"] == "8")
        #expect(artistQuery["includeFields"] == "title,type,ratingKey,key")

        let childrenRequest = try PlexAPI.request(
            baseURL: try PlexAPI.normalizeBaseURL("https://plex.example.com"),
            endpoint: .children(ratingKey: "44"),
            token: "token"
        )
        #expect(childrenRequest.url?.path == "/library/metadata/44/children")
    }

    @Test func testDecodesLibrarySections() throws {
        let sections = try PlexAPI.decodeSections(data("""
        <MediaContainer size="2">
          <Directory key="1" title="Music" type="artist" />
          <Directory key="2" title="Movies" type="movie" />
        </MediaContainer>
        """))

        #expect(sections == [
            PlexItem(ratingKey: nil, key: "1", title: "Music", kind: .section,
                     durationSec: nil, sizeBytes: nil, partKey: nil),
        ])
    }

    @Test func testDecodesArtistsAndAlbumsWithEscapedTitles() throws {
        let items = try PlexAPI.decodeItems(data("""
        <MediaContainer size="2">
          <Directory ratingKey="100" key="/library/metadata/100/children"
                     title="A Winged Victory &amp; Dustin O'Halloran" type="artist" />
          <Directory ratingKey="200" key="/library/metadata/200/children"
                     title="The Undivided Five" type="album" duration="2850000" />
        </MediaContainer>
        """))

        #expect(items[0].kind == .artist)
        #expect(items[0].title == "A Winged Victory & Dustin O'Halloran")
        #expect(items[1].kind == .album)
        #expect(items[1].durationSec == 2_850)
    }

    @Test func testDecodesTrackPartMetadata() throws {
        let track = try PlexAPI.decodeTrackMetadata(data("""
        <MediaContainer size="1">
          <Track ratingKey="300" key="/library/metadata/300" title="Poa Alpina"
                 type="track" duration="282000" grandparentTitle="Biosphere"
                 parentTitle="Substrata" index="4" parentIndex="1"
                 parentThumb="/library/metadata/200/thumb/1700000000">
            <Media id="400" duration="282000" audioCodec="flac">
              <Part id="500" key="/library/parts/500/1700000000/file.flac"
                    size="98765" container="flac" />
            </Media>
          </Track>
        </MediaContainer>
        """))

        #expect(track.ratingKey == "300")
        #expect(track.kind == .track)
        #expect(track.durationSec == 282)
        #expect(track.partKey == "/library/parts/500/1700000000/file.flac")
        #expect(track.sizeBytes == 98_765)
        #expect(track.artistTitle == "Biosphere")
        #expect(track.albumTitle == "Substrata")
        #expect(track.index == 4)
        #expect(track.parentIndex == 1)
        #expect(track.container == "flac")
        #expect(track.thumb == "/library/metadata/200/thumb/1700000000")
    }

    @Test func testMalformedAndIncompleteResponsesThrow() {
        do {
            _ = try PlexAPI.decodeItems(data("<not-plex />"))
            Issue.record("expected decodeItems of a malformed response to throw")
        } catch {
            #expect(error as? PlexAPI.Error == .malformedResponse)
        }
        do {
            _ = try PlexAPI.decodeTrackMetadata(data("""
            <MediaContainer size="1">
              <Track ratingKey="300" key="/library/metadata/300" title="Poa Alpina" type="track" />
            </MediaContainer>
            """))
            Issue.record("expected decodeTrackMetadata with a missing Part.key to throw")
        } catch {
            #expect(error as? PlexAPI.Error == .missingField("Track.Part.key"))
        }
    }

    @Test func testServerFormPolicy() throws {
        let url = try PlexServerPolicy.normalizeBaseURL("plex.example.com:32400")

        #expect(url.absoluteString == "http://plex.example.com:32400")
        #expect(PlexServerPolicy.canSubmit(url: "https://plex.example.com", token: "token"))
        #expect(!PlexServerPolicy.canSubmit(url: "ftp://plex.example.com", token: "token"))
        #expect(!PlexServerPolicy.canSubmit(url: "https://plex.example.com", token: " "))
    }

    private func data(_ string: String) -> Data {
        Data(string.utf8)
    }
}
