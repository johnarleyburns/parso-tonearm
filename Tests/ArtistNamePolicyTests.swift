import XCTest

@testable import TonearmCore

final class ArtistNamePolicyTests: XCTestCase {

    func testSortNameDropsLeadingArticlesAcrossLanguages() {
        let cases: [(String, String)] = [
            ("The Beatles", "Beatles"),
            ("A Tribe Called Quest", "Tribe Called Quest"),
            ("An Horse", "Horse"),
            ("Los Lobos", "Lobos"),
            ("Las Cafeteras", "Cafeteras"),
            ("La Femme", "Femme"),
            ("El Guincho", "Guincho"),
            ("Le Tigre", "Tigre"),
            ("Les Rita Mitsouko", "Rita Mitsouko"),
            ("Die Ärzte", "Arzte"),
            ("L'Orchestre National", "Orchestre National"),
        ]

        for (input, expected) in cases {
            XCTAssertEqual(ArtistNamePolicy.sortName(for: input), expected, input)
        }
    }

    func testSplitArtistsHandlesFeaturedWithAndExplicitSeparators() {
        XCTAssertEqual(ArtistNamePolicy.splitArtists("A feat. B"), ["A", "B"])
        XCTAssertEqual(ArtistNamePolicy.splitArtists("A featuring B"), ["A", "B"])
        XCTAssertEqual(ArtistNamePolicy.splitArtists("A ft. B"), ["A", "B"])
        XCTAssertEqual(ArtistNamePolicy.splitArtists("A with B"), ["A", "B"])
        XCTAssertEqual(ArtistNamePolicy.splitArtists("A & B"), ["A", "B"])
        XCTAssertEqual(ArtistNamePolicy.splitArtists("A; B"), ["A", "B"])
        XCTAssertEqual(ArtistNamePolicy.splitArtists("A + B"), ["A", "B"])
        XCTAssertEqual(ArtistNamePolicy.splitArtists("A / B"), ["A", "B"])
        XCTAssertEqual(ArtistNamePolicy.splitArtists("A feat. B & C"), ["A", "B", "C"])
    }

    func testSplitArtistsPreservesBandNamesAndDedupes() {
        XCTAssertEqual(ArtistNamePolicy.splitArtists("AC/DC"), ["AC/DC"])
        XCTAssertEqual(ArtistNamePolicy.splitArtists("Björk & björk"), ["Björk"])
    }

    func testNormalizeAndSortHandleWhitespaceUnicodeAndDiacritics() {
        XCTAssertEqual(
            ArtistNamePolicy.normalize("  Björk\u{00a0}Guðmundsdóttir  "),
            "Björk Guðmundsdóttir")
        XCTAssertEqual(ArtistNamePolicy.sortName(for: "Álvaro Soler"), "Alvaro Soler")
        XCTAssertEqual(ArtistNamePolicy.identityKey(for: "Beyoncé"), "beyonce")
    }

    func testEmptyWhitespaceOnlyInputsProduceNoArtist() {
        XCTAssertNil(ArtistNamePolicy.normalize(nil))
        XCTAssertNil(ArtistNamePolicy.normalize(""))
        XCTAssertNil(ArtistNamePolicy.normalize(" \n\t "))
        XCTAssertEqual(ArtistNamePolicy.splitArtists(" \n\t "), [])
        XCTAssertEqual(ArtistNamePolicy.sortName(for: " "), "")
    }

    func testVariousArtistsVariantsCanonicalize() {
        for value in [
            "Various Artists", "various artists", "Various Artist", "Various", "VA", "V.A.", "V/A",
        ] {
            XCTAssertTrue(ArtistNamePolicy.isVariousArtists(value), value)
            XCTAssertEqual(ArtistNamePolicy.normalize(value), "Various Artists", value)
            XCTAssertEqual(ArtistNamePolicy.splitArtists(value), ["Various Artists"], value)
        }
    }

    func testAttributionKeepsAlbumArtistSeparateFromTrackArtists() {
        let compilation = ArtistNamePolicy.attribution(albumArtist: "VA", trackArtist: "A & B")
        XCTAssertEqual(compilation.albumArtist, "Various Artists")
        XCTAssertEqual(compilation.trackArtists, ["A", "B"])
        XCTAssertTrue(compilation.isCompilation)

        let inferred = ArtistNamePolicy.attribution(albumArtist: nil, trackArtist: "The Beatles")
        XCTAssertEqual(inferred.albumArtist, "The Beatles")
        XCTAssertEqual(inferred.trackArtists, ["The Beatles"])
        XCTAssertFalse(inferred.isCompilation)

        let guest = ArtistNamePolicy.attribution(
            albumArtist: "Miles Davis",
            trackArtist: "John Coltrane with Miles Davis")
        XCTAssertEqual(guest.albumArtist, "Miles Davis")
        XCTAssertEqual(guest.trackArtists, ["John Coltrane", "Miles Davis"])
        XCTAssertFalse(guest.isCompilation)
    }
}
