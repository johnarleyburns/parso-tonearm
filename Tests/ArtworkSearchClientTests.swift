import Testing
@testable import TonearmCore

@Suite struct ArtworkSearchClientTests {

    // MARK: - Host allowlist

    @Test func testAllowedHosts() {
        #expect(ArtworkSearchClient.isAllowedHost("itunes.apple.com"))
        #expect(ArtworkSearchClient.isAllowedHost("is1-ssl.mzstatic.com"))
        #expect(ArtworkSearchClient.isAllowedHost("mzstatic.com"))
    }

    @Test func testDisallowedHosts() {
        #expect(!ArtworkSearchClient.isAllowedHost("archive.org"))
        #expect(!ArtworkSearchClient.isAllowedHost("example.com"))
        #expect(!ArtworkSearchClient.isAllowedHost("itunes.apple.com.evil.com"))
        #expect(!ArtworkSearchClient.isAllowedHost("mzstatic.com.hax.io"))
    }

    // MARK: - URL builders

    @Test func testSearchURLEncoding() {
        let url = ArtworkSearchClient.searchURL(term: "Stephan Bodzin Boavista", entity: "musicTrack")
        let s = url!.absoluteString
        #expect(s.hasPrefix("https://itunes.apple.com/search?"))
        #expect(s.contains("media=music"))
        #expect(s.contains("entity=musicTrack"))
        #expect(s.contains("term=Stephan%20Bodzin%20Boavista")
                      || s.contains("term=Stephan+Bodzin+Boavista"))
    }

    @Test func testSearchURLWithAttribute() {
        let url = ArtworkSearchClient.searchURL(term: "solomun", entity: "album", attribute: "artistTerm")
        #expect(url!.absoluteString.contains("attribute=artistTerm"))
    }

    @Test func testUpscaleArtworkURL() {
        let raw = "https://is1-ssl.mzstatic.com/image/thumb/abc/100x100bb.jpg"
        let url = ArtworkSearchClient.upscaledArtworkURL(raw)
        #expect(url?.absoluteString ==
                       "https://is1-ssl.mzstatic.com/image/thumb/abc/600x600bb.jpg")
    }

    // MARK: - Confidence gate fixtures

    private func decode(_ json: String) -> [ITunesResult] {
        let data = json.data(using: .utf8)!
        return (try? JSONDecoder().decode(ITunesResponse.self, from: data))?.results ?? []
    }

    // Fixture 1: Stephan Bodzin - Boavista. results[0] is (Synthapella); the exact
    // "Boavista" album should be chosen (strong).
    @Test func testBodzinStrongExactTrack() {
        let json = """
        {"results":[
          {"wrapperType":"track","artistName":"Stephan Bodzin","collectionName":"Boavista - Single","trackName":"Boavista (Synthapella)","artworkUrl100":"https://is1-ssl.mzstatic.com/a/100x100bb.jpg","trackCount":3},
          {"wrapperType":"track","artistName":"Stephan Bodzin","collectionName":"Boavista","trackName":"Boavista","artworkUrl100":"https://is1-ssl.mzstatic.com/b/100x100bb.jpg","trackCount":17}
        ]}
        """
        let match = ArtworkSearchClient.bestMatch(from: decode(json),
                                                  queryArtist: "Stephan Bodzin",
                                                  queryTitle: "Boavista")
        #expect(match != nil)
        #expect(match?.artworkURL.absoluteString ==
                       "https://is1-ssl.mzstatic.com/b/600x600bb.jpg")
        #expect(match!.isStrong)
    }

    // Fixture 2: Solomun (artist-only). results[0] is a collab; exact "Solomun" wins.
    @Test func testSolomunSkipsCollab() {
        let json = """
        {"results":[
          {"wrapperType":"collection","collectionType":"Album","artistName":"Skrillex & Solomun","collectionName":"Rumpta - Single","artworkUrl100":"https://is1-ssl.mzstatic.com/x/100x100bb.jpg","trackCount":1},
          {"wrapperType":"collection","collectionType":"Album","artistName":"Solomun","collectionName":"Nobody Is Not Loved","artworkUrl100":"https://is1-ssl.mzstatic.com/y/100x100bb.jpg","trackCount":12}
        ]}
        """
        let match = ArtworkSearchClient.bestMatch(from: decode(json),
                                                  queryArtist: "Solomun",
                                                  queryTitle: nil)
        #expect(match?.artworkURL.absoluteString ==
                       "https://is1-ssl.mzstatic.com/y/600x600bb.jpg")
        #expect(match!.isStrong)
    }

    // Fixture 3: Nicola Cruz Boiler Room (live compilation). Artist matches -> weak.
    @Test func testNicolaCruzWeakLive() {
        let json = """
        {"results":[
          {"wrapperType":"track","artistName":"Nicola Cruz","collectionName":"Boiler Room: El Búho in Tulum","trackName":"Colibria (History of Colour Remix) [Live]","artworkUrl100":"https://is1-ssl.mzstatic.com/z/100x100bb.jpg","trackCount":20}
        ]}
        """
        let match = ArtworkSearchClient.bestMatch(from: decode(json),
                                                  queryArtist: "Nicola Cruz",
                                                  queryTitle: "Boiler Room")
        #expect(match != nil)
        #expect(match?.artworkURL.absoluteString ==
                       "https://is1-ssl.mzstatic.com/z/600x600bb.jpg")
        // Title tokens ("boiler room") don't align with the live remix track name.
        #expect(!match!.isStrong)
    }

    // Fixture 4: Hozho via artistTerm album fallback (track search returned nothing).
    @Test func testHozhoArtistTermWeak() {
        let json = """
        {"results":[
          {"wrapperType":"collection","collectionType":"Album","artistName":"Hozho","collectionName":"Honey Trap - Single","artworkUrl100":"https://is1-ssl.mzstatic.com/h/100x100bb.jpg","trackCount":1}
        ]}
        """
        let match = ArtworkSearchClient.bestMatch(from: decode(json),
                                                  queryArtist: "Hozho",
                                                  queryTitle: nil)
        #expect(match?.artworkURL.absoluteString ==
                       "https://is1-ssl.mzstatic.com/h/600x600bb.jpg")
        #expect(match!.isStrong) // exact artist, single-name artist term
    }

    // Fixture 5: "Trap hip-hop boxing music mix" -> unrelated results -> NONE.
    @Test func testTrapMixRejected() {
        let json = """
        {"results":[
          {"wrapperType":"track","artistName":"Jordan Adetunji","collectionName":"KEHLANI - Single","trackName":"KEHLANI","artworkUrl100":"https://is1-ssl.mzstatic.com/k/100x100bb.jpg","trackCount":1},
          {"wrapperType":"track","artistName":"USHER","collectionName":"My Way","trackName":"You Make Me Wanna...","artworkUrl100":"https://is1-ssl.mzstatic.com/u/100x100bb.jpg","trackCount":10}
        ]}
        """
        let match = ArtworkSearchClient.bestMatch(from: decode(json),
                                                  queryArtist: "Trap hip-hop boxing",
                                                  queryTitle: nil)
        #expect(match == nil)
    }

    // Fixture 6: "workout music rocky motivation" -> only the generic word
    // "motivation" overlaps a track title, never the artist -> NONE.
    @Test func testWorkoutMotivationRejected() {
        let json = """
        {"results":[
          {"wrapperType":"track","artistName":"Sia","collectionName":"1000 Forms of Fear","trackName":"Chandelier","artworkUrl100":"https://is1-ssl.mzstatic.com/s/100x100bb.jpg","trackCount":12},
          {"wrapperType":"track","artistName":"Normani","collectionName":"Motivation - Single","trackName":"Motivation","artworkUrl100":"https://is1-ssl.mzstatic.com/n/100x100bb.jpg","trackCount":1}
        ]}
        """
        let match = ArtworkSearchClient.bestMatch(from: decode(json),
                                                  queryArtist: "workout rocky motivation",
                                                  queryTitle: nil)
        #expect(match == nil)
    }

    // Fixture 7: "Stephan Bodzin Berlin" (artist + city noise) -> partial
    // token overlap passes the >=0.5 threshold, returning a weak match.
    @Test func testArtistWithLocationNoiseAcceptedPartialMatch() {
        let json = """
        {"results":[
          {"wrapperType":"collection","collectionType":"Album","artistName":"Stephan Bodzin","collectionName":"Powers of Ten","artworkUrl100":"https://is1-ssl.mzstatic.com/p/100x100bb.jpg","trackCount":15},
          {"wrapperType":"collection","collectionType":"Album","artistName":"Skrillex","collectionName":"Quest For Fire","artworkUrl100":"https://is1-ssl.mzstatic.com/q/100x100bb.jpg","trackCount":15}
        ]}
        """
        let match = ArtworkSearchClient.bestMatch(from: decode(json),
                                                  queryArtist: "Stephan Bodzin Berlin",
                                                  queryTitle: nil)
        #expect(match != nil)
        #expect(match?.artworkURL.absoluteString ==
                       "https://is1-ssl.mzstatic.com/p/600x600bb.jpg")
        #expect(!match!.isStrong) // extra noise token means inexact artist
    }

    @Test func testEmptyResultsReturnNil() {
        #expect(ArtworkSearchClient.bestMatch(from: [], queryArtist: "Anyone", queryTitle: nil) == nil)
    }
}
