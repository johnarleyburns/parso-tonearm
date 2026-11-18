import Testing

@testable import TonearmCore

@Suite struct LyricsTests {
    @Test func testParsesMetadataAndSelectsCurrentLineAtBoundaries() {
        let lyrics = LRCParser.parse("""
        [ar: Nils Frahm]
        [ti: Says]
        [00:01.00]First
        [00:02.50]Second
        [00:04.00]Third
        """)

        #expect(lyrics.metadata["ar"] == "Nils Frahm")
        #expect(lyrics.metadata["ti"] == "Says")
        #expect(lyrics.currentLine(at: 0.99) == nil)
        #expect(lyrics.currentLine(at: 1.0)?.text == "First")
        #expect(lyrics.currentLine(at: 2.49)?.text == "First")
        #expect(lyrics.currentLine(at: 2.5)?.text == "Second")
        #expect(lyrics.currentLine(at: 99)?.text == "Third")
    }

    @Test func testMultipleTimestampsProduceMultipleSortedLines() {
        let lyrics = LRCParser.parse("""
        [00:03.00]Later
        [00:01.00][00:02.00]Echo
        """)

        #expect(lyrics.lines.map(\.time) == [1, 2, 3])
        #expect(lyrics.lines.map(\.text) == ["Echo", "Echo", "Later"])
    }

    @Test func testDuplicateTimestampsKeepSourceOrderAndCurrentLineUsesLastMatch() {
        let lyrics = LRCParser.parse("""
        [00:10.00]Original language
        [00:10.00]Translation
        [00:12.00]Next
        """)

        #expect(lyrics.lines.map(\.text) == ["Original language", "Translation", "Next"])
        #expect(lyrics.currentLine(at: 10)?.text == "Translation")
        #expect(lyrics.currentLine(at: 11.99)?.text == "Translation")
    }

    @Test func testOffsetTagShiftsAllLinesEvenWhenTagAppearsLate() {
        let positive = LRCParser.parse("""
        [00:01.00]Late
        [offset:+500]
        """)
        let negative = LRCParser.parse("""
        [offset:-250]
        [00:01.00]Early
        """)

        #expect(positive.offset == 0.5)
        #expect(positive.lines.first?.time == 1.5)
        #expect(positive.currentLine(at: 1.49) == nil)
        #expect(positive.currentLine(at: 1.5)?.text == "Late")
        #expect(negative.offset == -0.25)
        #expect(negative.lines.first?.time == 0.75)
    }

    @Test func testMalformedOffsetIsMetadataOnly() {
        let lyrics = LRCParser.parse("""
        [offset: not a number]
        [00:01.00]Line
        """)

        #expect(lyrics.metadata["offset"] == "not a number")
        #expect(lyrics.offset == 0)
        #expect(lyrics.lines.first?.time == 1)
    }

    @Test func testMalformedRealWorldLinesAreIgnoredWithoutPoisoningValidLines() {
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

        #expect(lyrics.metadata["length"] == "03:31")
        #expect(lyrics.metadata["re"] == "Some exporter")
        #expect(lyrics.untimedLines == ["plain unsynced note"])
        #expect(lyrics.lines.map(\.text) == [
            "Intro",
            "No fraction",
            "Comma fraction",
            "Single digit fraction",
            "Hour timestamp",
        ])
        #expect(lyrics.lines.map(\.time) == [0, 62, 62.5, 63.5, 3_723.25])
    }

    @Test func testCRLFWhitespaceAndEmptyLyricLines() {
        let lyrics = LRCParser.parse("[00:01.00]  padded lyric  \r\n[00:02.00]\r\n")

        #expect(lyrics.lines.count == 2)
        #expect(lyrics.lines[0].text == "padded lyric")
        #expect(lyrics.lines[1].text == "")
    }

    @Test func testEmptyAndUntimedLyricsHaveNoCurrentLine() {
        let empty = LRCParser.parse("")
        let untimed = LRCParser.parse("""
        This is a static lyric sheet
        with no timestamps
        """)

        #expect(empty.lines.isEmpty)
        #expect(empty.currentLine(at: 10) == nil)
        #expect(untimed.untimedLines == [
            "This is a static lyric sheet",
            "with no timestamps",
        ])
        #expect(untimed.currentLine(at: 10) == nil)
    }

    @Test func testLyricsLookupIsStrictlyOptIn() {
        #expect(!LyricsLookupPolicy.defaultOptIn)
        #expect(
            LyricsLookupPolicy.decision(isOptedIn: false) ==
            .blocked(reason: "Lyrics lookup is off.")
        )
        #expect(
            LyricsLookupPolicy.decision(isOptedIn: true) ==
            .allowed(provider: "LRCLIB")
        )
        #expect(LyricsLookupPolicy.privacyStatement.contains("LRCLIB"))
    }
}
