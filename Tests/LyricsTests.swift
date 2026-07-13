import XCTest

@testable import Tonearm

final class LyricsTests: XCTestCase {
    func testParsesMetadataAndSelectsCurrentLineAtBoundaries() {
        let lyrics = LRCParser.parse("""
        [ar: Nils Frahm]
        [ti: Says]
        [00:01.00]First
        [00:02.50]Second
        [00:04.00]Third
        """)

        XCTAssertEqual(lyrics.metadata["ar"], "Nils Frahm")
        XCTAssertEqual(lyrics.metadata["ti"], "Says")
        XCTAssertNil(lyrics.currentLine(at: 0.99))
        XCTAssertEqual(lyrics.currentLine(at: 1.0)?.text, "First")
        XCTAssertEqual(lyrics.currentLine(at: 2.49)?.text, "First")
        XCTAssertEqual(lyrics.currentLine(at: 2.5)?.text, "Second")
        XCTAssertEqual(lyrics.currentLine(at: 99)?.text, "Third")
    }

    func testMultipleTimestampsProduceMultipleSortedLines() {
        let lyrics = LRCParser.parse("""
        [00:03.00]Later
        [00:01.00][00:02.00]Echo
        """)

        XCTAssertEqual(lyrics.lines.map(\.time), [1, 2, 3])
        XCTAssertEqual(lyrics.lines.map(\.text), ["Echo", "Echo", "Later"])
    }

    func testDuplicateTimestampsKeepSourceOrderAndCurrentLineUsesLastMatch() {
        let lyrics = LRCParser.parse("""
        [00:10.00]Original language
        [00:10.00]Translation
        [00:12.00]Next
        """)

        XCTAssertEqual(lyrics.lines.map(\.text), ["Original language", "Translation", "Next"])
        XCTAssertEqual(lyrics.currentLine(at: 10)?.text, "Translation")
        XCTAssertEqual(lyrics.currentLine(at: 11.99)?.text, "Translation")
    }

    func testOffsetTagShiftsAllLinesEvenWhenTagAppearsLate() {
        let positive = LRCParser.parse("""
        [00:01.00]Late
        [offset:+500]
        """)
        let negative = LRCParser.parse("""
        [offset:-250]
        [00:01.00]Early
        """)

        XCTAssertEqual(positive.offset, 0.5)
        XCTAssertEqual(positive.lines.first?.time, 1.5)
        XCTAssertNil(positive.currentLine(at: 1.49))
        XCTAssertEqual(positive.currentLine(at: 1.5)?.text, "Late")
        XCTAssertEqual(negative.offset, -0.25)
        XCTAssertEqual(negative.lines.first?.time, 0.75)
    }

    func testMalformedOffsetIsMetadataOnly() {
        let lyrics = LRCParser.parse("""
        [offset: not a number]
        [00:01.00]Line
        """)

        XCTAssertEqual(lyrics.metadata["offset"], "not a number")
        XCTAssertEqual(lyrics.offset, 0)
        XCTAssertEqual(lyrics.lines.first?.time, 1)
    }

    func testMalformedRealWorldLinesAreIgnoredWithoutPoisoningValidLines() {
        let lyrics = LRCParser.parse("""
        \u{feff}[length:03:31]
        [re:Some exporter]
        plain unsynced note
        [00:00.00]Intro
        [00:60.00]bad seconds
        [not-a-time]bad tag
        [00:xx.10]bad number
        [01:02]No fraction
        [01:02,50]Comma fraction
        [01:03.5]Single digit fraction
        [01:02:03.25]Hour timestamp
        [00:04.00
        """)

        XCTAssertEqual(lyrics.metadata["length"], "03:31")
        XCTAssertEqual(lyrics.metadata["re"], "Some exporter")
        XCTAssertEqual(lyrics.untimedLines, ["plain unsynced note"])
        XCTAssertEqual(lyrics.lines.map(\.text), [
            "Intro",
            "No fraction",
            "Comma fraction",
            "Single digit fraction",
            "Hour timestamp",
        ])
        XCTAssertEqual(lyrics.lines.map(\.time), [0, 62, 62.5, 63.5, 3_723.25])
    }

    func testCRLFWhitespaceAndEmptyLyricLines() {
        let lyrics = LRCParser.parse("[00:01.00]  padded lyric  \r\n[00:02.00]\r\n")

        XCTAssertEqual(lyrics.lines.count, 2)
        XCTAssertEqual(lyrics.lines[0].text, "padded lyric")
        XCTAssertEqual(lyrics.lines[1].text, "")
    }

    func testEmptyAndUntimedLyricsHaveNoCurrentLine() {
        let empty = LRCParser.parse("")
        let untimed = LRCParser.parse("""
        This is a static lyric sheet
        with no timestamps
        """)

        XCTAssertTrue(empty.lines.isEmpty)
        XCTAssertNil(empty.currentLine(at: 10))
        XCTAssertEqual(untimed.untimedLines, [
            "This is a static lyric sheet",
            "with no timestamps",
        ])
        XCTAssertNil(untimed.currentLine(at: 10))
    }

    func testLyricsLookupIsStrictlyOptIn() {
        XCTAssertFalse(LyricsLookupPolicy.defaultOptIn)
        XCTAssertEqual(
            LyricsLookupPolicy.decision(isOptedIn: false),
            .blocked(reason: "Lyrics lookup is off.")
        )
        XCTAssertEqual(
            LyricsLookupPolicy.decision(isOptedIn: true),
            .allowed(provider: "LRCLIB")
        )
        XCTAssertTrue(LyricsLookupPolicy.privacyStatement.contains("LRCLIB"))
    }
}
