import XCTest
@testable import Tonearm

final class FilenameQueryParserTests: XCTestCase {
    private let parser = FilenameQueryParser()

    func testArtistTitleWithMixQualifierAndExtension() {
        let q = parser.parse("Stephan Bodzin - Boavista (Original Mix).mp3")
        XCTAssertEqual(q.artist, "Stephan Bodzin")
        XCTAssertEqual(q.title, "Boavista")
    }

    func testLeadingTrackNumberAndUnderscores() {
        let q = parser.parse("01_Nicola Cruz_Colibria.flac")
        // Underscores split into a single term; no " - " so it's treated as artist term.
        XCTAssertEqual(q.artist, "Nicola Cruz Colibria")
        XCTAssertNil(q.title)
    }

    func testDashSeparatedWithTrackNumber() {
        let q = parser.parse("07 - Nicola Cruz - Boiler Room (Live)")
        XCTAssertEqual(q.artist, "Nicola Cruz")
        // "Boiler Room" is a venue/recording brand, stripped as noise for artwork lookup.
        XCTAssertNil(q.title)
    }

    func testBracketedLabelRemoved() {
        let q = parser.parse("[Diynamic] Solomun - Friends")
        XCTAssertEqual(q.artist, "Solomun")
        XCTAssertEqual(q.title, "Friends")
    }

    func testBareArtistName() {
        let q = parser.parse("Solomun.flac")
        XCTAssertEqual(q.artist, "Solomun")
        XCTAssertNil(q.title)
        XCTAssertEqual(q.cleanedTerm, "Solomun")
    }

    func testDescriptiveMixNameHasNoArtistTitleSplit() {
        let q = parser.parse("Trap hip-hop boxing music mix")
        // "mix" is a noise token and is stripped; "music" is kept. No " - " split,
        // so the whole thing becomes the artist term (which the confidence gate
        // later rejects for lack of a real artist match).
        XCTAssertNil(q.title)
        XCTAssertEqual(q.cleanedTerm, "Trap hip-hop boxing music")
    }

    func testYearStripped() {
        let q = parser.parse("Hozho - Adderall (2024)")
        XCTAssertEqual(q.artist, "Hozho")
        XCTAssertEqual(q.title, "Adderall")
    }

    func testDoesNotEatNumericName() {
        let q = parser.parse("3005")
        XCTAssertEqual(q.cleanedTerm, "3005")
    }

    func testBoilerRoomDJSetStripped() {
        let q = parser.parse("Solomun Boiler Room DJ Set (320 kbps)")
        XCTAssertEqual(q.artist, "Solomun")
        XCTAssertNil(q.title)
        XCTAssertEqual(q.cleanedTerm, "Solomun")
    }

    func testArtistWithVenueAndCity() {
        let q = parser.parse("Stephan Bodzin Boiler Room Berlin Live")
        // Parser strips known noise (boiler, room, live); city name "Berlin"
        // survives — the confidence gate handles the remaining extra tokens.
        XCTAssertEqual(q.artist, "Stephan Bodzin Berlin")
        XCTAssertNil(q.title)
        XCTAssertEqual(q.cleanedTerm, "Stephan Bodzin Berlin")
    }
}
