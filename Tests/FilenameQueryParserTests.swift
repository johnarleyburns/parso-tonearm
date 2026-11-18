import Testing
@testable import TonearmCore

@Suite struct FilenameQueryParserTests {
    private let parser = FilenameQueryParser()

    @Test func testArtistTitleWithMixQualifierAndExtension() {
        let q = parser.parse("Stephan Bodzin - Boavista (Original Mix).mp3")
        #expect(q.artist == "Stephan Bodzin")
        #expect(q.title == "Boavista")
    }

    @Test func testLeadingTrackNumberAndUnderscores() {
        let q = parser.parse("01_Nicola Cruz_Colibria.flac")
        // Underscores split into a single term; no " - " so it's treated as artist term.
        #expect(q.artist == "Nicola Cruz Colibria")
        #expect(q.title == nil)
    }

    @Test func testDashSeparatedWithTrackNumber() {
        let q = parser.parse("07 - Nicola Cruz - Boiler Room (Live)")
        #expect(q.artist == "Nicola Cruz")
        // "Boiler Room" is a venue/recording brand, stripped as noise for artwork lookup.
        #expect(q.title == nil)
    }

    @Test func testBracketedLabelRemoved() {
        let q = parser.parse("[Diynamic] Solomun - Friends")
        #expect(q.artist == "Solomun")
        #expect(q.title == "Friends")
    }

    @Test func testBareArtistName() {
        let q = parser.parse("Solomun.flac")
        #expect(q.artist == "Solomun")
        #expect(q.title == nil)
        #expect(q.cleanedTerm == "Solomun")
    }

    @Test func testDescriptiveMixNameHasNoArtistTitleSplit() {
        let q = parser.parse("Trap hip-hop boxing music mix")
        // "mix" is a noise token and is stripped; "music" is kept. No " - " split,
        // so the whole thing becomes the artist term (which the confidence gate
        // later rejects for lack of a real artist match).
        #expect(q.title == nil)
        #expect(q.cleanedTerm == "Trap hip-hop boxing music")
    }

    @Test func testYearStripped() {
        let q = parser.parse("Hozho - Adderall (2024)")
        #expect(q.artist == "Hozho")
        #expect(q.title == "Adderall")
    }

    @Test func testDoesNotEatNumericName() {
        let q = parser.parse("3005")
        #expect(q.cleanedTerm == "3005")
    }

    @Test func testBoilerRoomDJSetStripped() {
        let q = parser.parse("Solomun Boiler Room DJ Set (320 kbps)")
        #expect(q.artist == "Solomun")
        #expect(q.title == nil)
        #expect(q.cleanedTerm == "Solomun")
    }

    @Test func testArtistWithVenueAndCity() {
        let q = parser.parse("Stephan Bodzin Boiler Room Berlin Live")
        // Parser strips known noise (boiler, room, live); city name "Berlin"
        // survives — the confidence gate handles the remaining extra tokens.
        #expect(q.artist == "Stephan Bodzin Berlin")
        #expect(q.title == nil)
        #expect(q.cleanedTerm == "Stephan Bodzin Berlin")
    }
}
