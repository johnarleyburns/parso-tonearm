import Testing

@testable import TonearmCore

@Suite struct ArtistNamePolicyTests {

    @Test func testSortNameDropsLeadingArticlesAcrossLanguages() {
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
            #expect(ArtistNamePolicy.sortName(for: input) == expected, "\(input)")
        }
    }

    @Test func testSplitArtistsHandlesFeaturedWithAndExplicitSeparators() {
        #expect(ArtistNamePolicy.splitArtists("A feat. B") == ["A", "B"])
        #expect(ArtistNamePolicy.splitArtists("A featuring B") == ["A", "B"])
        #expect(ArtistNamePolicy.splitArtists("A ft. B") == ["A", "B"])
        #expect(ArtistNamePolicy.splitArtists("A with B") == ["A", "B"])
        #expect(ArtistNamePolicy.splitArtists("A & B") == ["A", "B"])
        #expect(ArtistNamePolicy.splitArtists("A; B") == ["A", "B"])
        #expect(ArtistNamePolicy.splitArtists("A + B") == ["A", "B"])
        #expect(ArtistNamePolicy.splitArtists("A / B") == ["A", "B"])
        #expect(ArtistNamePolicy.splitArtists("A feat. B & C") == ["A", "B", "C"])
    }

    @Test func testSplitArtistsPreservesBandNamesAndDedupes() {
        #expect(ArtistNamePolicy.splitArtists("AC/DC") == ["AC/DC"])
        #expect(ArtistNamePolicy.splitArtists("Björk & björk") == ["Björk"])
    }

    @Test func testNormalizeAndSortHandleWhitespaceUnicodeAndDiacritics() {
        #expect(
            ArtistNamePolicy.normalize("  Björk\u{00a0}Guðmundsdóttir  ") ==
            "Björk Guðmundsdóttir")
        #expect(ArtistNamePolicy.sortName(for: "Álvaro Soler") == "Alvaro Soler")
        #expect(ArtistNamePolicy.identityKey(for: "Beyoncé") == "beyonce")
    }

    @Test func testEmptyWhitespaceOnlyInputsProduceNoArtist() {
        #expect(ArtistNamePolicy.normalize(nil) == nil)
        #expect(ArtistNamePolicy.normalize("") == nil)
        #expect(ArtistNamePolicy.normalize(" \n\t ") == nil)
        #expect(ArtistNamePolicy.splitArtists(" \n\t ") == [])
        #expect(ArtistNamePolicy.sortName(for: " ") == "")
    }

    @Test func testVariousArtistsVariantsCanonicalize() {
        for value in [
            "Various Artists", "various artists", "Various Artist", "Various", "VA", "V.A.", "V/A",
        ] {
            #expect(ArtistNamePolicy.isVariousArtists(value), "\(value)")
            #expect(ArtistNamePolicy.normalize(value) == "Various Artists", "\(value)")
            #expect(ArtistNamePolicy.splitArtists(value) == ["Various Artists"], "\(value)")
        }
    }

    @Test func testAttributionKeepsAlbumArtistSeparateFromTrackArtists() {
        let compilation = ArtistNamePolicy.attribution(albumArtist: "VA", trackArtist: "A & B")
        #expect(compilation.albumArtist == "Various Artists")
        #expect(compilation.trackArtists == ["A", "B"])
        #expect(compilation.isCompilation)

        let inferred = ArtistNamePolicy.attribution(albumArtist: nil, trackArtist: "The Beatles")
        #expect(inferred.albumArtist == "The Beatles")
        #expect(inferred.trackArtists == ["The Beatles"])
        #expect(!inferred.isCompilation)

        let guest = ArtistNamePolicy.attribution(
            albumArtist: "Miles Davis",
            trackArtist: "John Coltrane with Miles Davis")
        #expect(guest.albumArtist == "Miles Davis")
        #expect(guest.trackArtists == ["John Coltrane", "Miles Davis"])
        #expect(!guest.isCompilation)
    }
}
