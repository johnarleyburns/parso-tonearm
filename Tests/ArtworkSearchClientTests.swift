import XCTest
@testable import Tonearm

final class ArtworkSearchClientTests: XCTestCase {

    // MARK: - Host allowlist

    func testAllowedHosts() {
        XCTAssertTrue(ArtworkSearchClient.isAllowedHost("itunes.apple.com"))
        XCTAssertTrue(ArtworkSearchClient.isAllowedHost("is1-ssl.mzstatic.com"))
        XCTAssertTrue(ArtworkSearchClient.isAllowedHost("mzstatic.com"))
    }

    func testDisallowedHosts() {
        XCTAssertFalse(ArtworkSearchClient.isAllowedHost("archive.org"))
        XCTAssertFalse(ArtworkSearchClient.isAllowedHost("example.com"))
        XCTAssertFalse(ArtworkSearchClient.isAllowedHost("itunes.apple.com.evil.com"))
        XCTAssertFalse(ArtworkSearchClient.isAllowedHost("mzstatic.com.hax.io"))
    }

    // MARK: - URL builders

    func testSearchURLEncoding() {
        let url = ArtworkSearchClient.searchURL(term: "Stephan Bodzin Boavista", entity: "musicTrack")
        let s = url!.absoluteString
        XCTAssertTrue(s.hasPrefix("https://itunes.apple.com/search?"))
        XCTAssertTrue(s.contains("media=music"))
        XCTAssertTrue(s.contains("entity=musicTrack"))
        XCTAssertTrue(s.contains("term=Stephan%20Bodzin%20Boavista")
                      || s.contains("term=Stephan+Bodzin+Boavista"))
    }

    func testSearchURLWithAttribute() {
        let url = ArtworkSearchClient.searchURL(term: "solomun", entity: "album", attribute: "artistTerm")
        XCTAssertTrue(url!.absoluteString.contains("attribute=artistTerm"))
    }

    func testUpscaleArtworkURL() {
        let raw = "https://is1-ssl.mzstatic.com/image/thumb/abc/100x100bb.jpg"
        let url = ArtworkSearchClient.upscaledArtworkURL(raw)
        XCTAssertEqual(url?.absoluteString,
                       "https://is1-ssl.mzstatic.com/image/thumb/abc/600x600bb.jpg")
    }

    // MARK: - Confidence gate fixtures

    private func decode(_ json: String) -> [ITunesResult] {
        let data = json.data(using: .utf8)!
        return (try? JSONDecoder().decode(ITunesResponse.self, from: data))?.results ?? []
    }

    // Fixture 1: Stephan Bodzin - Boavista. results[0] is (Synthapella); the exact
    // "Boavista" album should be chosen (strong).
    func testBodzinStrongExactTrack() {
        let json = """
        {"results":[
          {"wrapperType":"track","artistName":"Stephan Bodzin","collectionName":"Boavista - Single","trackName":"Boavista (Synthapella)","artworkUrl100":"https://is1-ssl.mzstatic.com/a/100x100bb.jpg","trackCount":3},
          {"wrapperType":"track","artistName":"Stephan Bodzin","collectionName":"Boavista","trackName":"Boavista","artworkUrl100":"https://is1-ssl.mzstatic.com/b/100x100bb.jpg","trackCount":17}
        ]}
        """
        let match = ArtworkSearchClient.bestMatch(from: decode(json),
                                                  queryArtist: "Stephan Bodzin",
                                                  queryTitle: "Boavista")
        XCTAssertNotNil(match)
        XCTAssertEqual(match?.artworkURL.absoluteString,
                       "https://is1-ssl.mzstatic.com/b/600x600bb.jpg")
        XCTAssertTrue(match!.isStrong)
    }

    // Fixture 2: Solomun (artist-only). results[0] is a collab; exact "Solomun" wins.
    func testSolomunSkipsCollab() {
        let json = """
        {"results":[
          {"wrapperType":"collection","collectionType":"Album","artistName":"Skrillex & Solomun","collectionName":"Rumpta - Single","artworkUrl100":"https://is1-ssl.mzstatic.com/x/100x100bb.jpg","trackCount":1},
          {"wrapperType":"collection","collectionType":"Album","artistName":"Solomun","collectionName":"Nobody Is Not Loved","artworkUrl100":"https://is1-ssl.mzstatic.com/y/100x100bb.jpg","trackCount":12}
        ]}
        """
        let match = ArtworkSearchClient.bestMatch(from: decode(json),
                                                  queryArtist: "Solomun",
                                                  queryTitle: nil)
        XCTAssertEqual(match?.artworkURL.absoluteString,
                       "https://is1-ssl.mzstatic.com/y/600x600bb.jpg")
        XCTAssertTrue(match!.isStrong)
    }

    // Fixture 3: Nicola Cruz Boiler Room (live compilation). Artist matches -> weak.
    func testNicolaCruzWeakLive() {
        let json = """
        {"results":[
          {"wrapperType":"track","artistName":"Nicola Cruz","collectionName":"Boiler Room: El Búho in Tulum","trackName":"Colibria (History of Colour Remix) [Live]","artworkUrl100":"https://is1-ssl.mzstatic.com/z/100x100bb.jpg","trackCount":20}
        ]}
        """
        let match = ArtworkSearchClient.bestMatch(from: decode(json),
                                                  queryArtist: "Nicola Cruz",
                                                  queryTitle: "Boiler Room")
        XCTAssertNotNil(match)
        XCTAssertEqual(match?.artworkURL.absoluteString,
                       "https://is1-ssl.mzstatic.com/z/600x600bb.jpg")
        // Title tokens ("boiler room") don't align with the live remix track name.
        XCTAssertFalse(match!.isStrong)
    }

    // Fixture 4: Hozho via artistTerm album fallback (track search returned nothing).
    func testHozhoArtistTermWeak() {
        let json = """
        {"results":[
          {"wrapperType":"collection","collectionType":"Album","artistName":"Hozho","collectionName":"Honey Trap - Single","artworkUrl100":"https://is1-ssl.mzstatic.com/h/100x100bb.jpg","trackCount":1}
        ]}
        """
        let match = ArtworkSearchClient.bestMatch(from: decode(json),
                                                  queryArtist: "Hozho",
                                                  queryTitle: nil)
        XCTAssertEqual(match?.artworkURL.absoluteString,
                       "https://is1-ssl.mzstatic.com/h/600x600bb.jpg")
        XCTAssertTrue(match!.isStrong) // exact artist, single-name artist term
    }

    // Fixture 5: "Trap hip-hop boxing music mix" -> unrelated results -> NONE.
    func testTrapMixRejected() {
        let json = """
        {"results":[
          {"wrapperType":"track","artistName":"Jordan Adetunji","collectionName":"KEHLANI - Single","trackName":"KEHLANI","artworkUrl100":"https://is1-ssl.mzstatic.com/k/100x100bb.jpg","trackCount":1},
          {"wrapperType":"track","artistName":"USHER","collectionName":"My Way","trackName":"You Make Me Wanna...","artworkUrl100":"https://is1-ssl.mzstatic.com/u/100x100bb.jpg","trackCount":10}
        ]}
        """
        let match = ArtworkSearchClient.bestMatch(from: decode(json),
                                                  queryArtist: "Trap hip-hop boxing",
                                                  queryTitle: nil)
        XCTAssertNil(match)
    }

    // Fixture 6: "workout music rocky motivation" -> only the generic word
    // "motivation" overlaps a track title, never the artist -> NONE.
    func testWorkoutMotivationRejected() {
        let json = """
        {"results":[
          {"wrapperType":"track","artistName":"Sia","collectionName":"1000 Forms of Fear","trackName":"Chandelier","artworkUrl100":"https://is1-ssl.mzstatic.com/s/100x100bb.jpg","trackCount":12},
          {"wrapperType":"track","artistName":"Normani","collectionName":"Motivation - Single","trackName":"Motivation","artworkUrl100":"https://is1-ssl.mzstatic.com/n/100x100bb.jpg","trackCount":1}
        ]}
        """
        let match = ArtworkSearchClient.bestMatch(from: decode(json),
                                                  queryArtist: "workout rocky motivation",
                                                  queryTitle: nil)
        XCTAssertNil(match)
    }

    // Fixture 7: "Stephan Bodzin Berlin" (artist + city noise) -> partial
    // token overlap passes the >=0.5 threshold, returning a weak match.
    func testArtistWithLocationNoiseAcceptedPartialMatch() {
        let json = """
        {"results":[
          {"wrapperType":"collection","collectionType":"Album","artistName":"Stephan Bodzin","collectionName":"Powers of Ten","artworkUrl100":"https://is1-ssl.mzstatic.com/p/100x100bb.jpg","trackCount":15},
          {"wrapperType":"collection","collectionType":"Album","artistName":"Skrillex","collectionName":"Quest For Fire","artworkUrl100":"https://is1-ssl.mzstatic.com/q/100x100bb.jpg","trackCount":15}
        ]}
        """
        let match = ArtworkSearchClient.bestMatch(from: decode(json),
                                                  queryArtist: "Stephan Bodzin Berlin",
                                                  queryTitle: nil)
        XCTAssertNotNil(match)
        XCTAssertEqual(match?.artworkURL.absoluteString,
                       "https://is1-ssl.mzstatic.com/p/600x600bb.jpg")
        XCTAssertFalse(match!.isStrong) // extra noise token means inexact artist
    }

    func testEmptyResultsReturnNil() {
        XCTAssertNil(ArtworkSearchClient.bestMatch(from: [], queryArtist: "Anyone", queryTitle: nil))
    }
}
