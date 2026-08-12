import XCTest

@testable import TonearmDJ

/// BriefExtractor (§28A.6, plan §2.8): deterministic durations / track counts /
/// BPM ranges / arc phrases / +− terms, the editable-chip model, and the rule
/// that unrecognised prose is not an error — it still reaches CLAP unchanged.
final class BriefExtractorTests: XCTestCase {

    // MARK: - Durations

    func testDurationWordsAndDigits() {
        XCTAssertEqual(BriefExtractor.parse("two hours for a dinner party").targetSeconds, 7200)
        XCTAssertEqual(BriefExtractor.parse("45 min").targetSeconds, 2700)
        XCTAssertEqual(BriefExtractor.parse("90 minutes").targetSeconds, 5400)
        XCTAssertEqual(BriefExtractor.parse("an hour").targetSeconds, 3600)
        XCTAssertEqual(BriefExtractor.parse("1 hour 30 minutes").targetSeconds, 5400)
        XCTAssertEqual(BriefExtractor.parse("2 hours 15 min").targetSeconds, 8100)
        XCTAssertEqual(BriefExtractor.parse("half an hour").targetSeconds, 1800)
    }

    func testNoDurationWhenOnlyTracksMentioned() {
        XCTAssertNil(BriefExtractor.parse("twenty tracks, no times").targetSeconds)
    }

    // MARK: - Track counts

    func testTrackCounts() {
        XCTAssertEqual(BriefExtractor.parse("give me 20 tracks").targetTrackCount, 20)
        XCTAssertEqual(BriefExtractor.parse("a twelve-track set").targetTrackCount, 12)
        XCTAssertEqual(BriefExtractor.parse("ten songs please").targetTrackCount, 10)
        XCTAssertEqual(BriefExtractor.parse("five tracks").targetTrackCount, 5)
    }

    // MARK: - BPM ranges

    func testBPMRanges() {
        let ranged = BriefExtractor.parse("120-128 BPM house set")
        XCTAssertEqual(ranged.bpmLo, 120)
        XCTAssertEqual(ranged.bpmHi, 128)
        let spaced = BriefExtractor.parse("120 to 128 bpm")
        XCTAssertEqual(spaced.bpmLo, 120)
        XCTAssertEqual(spaced.bpmHi, 128)
        let around = BriefExtractor.parse("around 118 bpm")
        XCTAssertEqual(around.bpmLo, 118)
        XCTAssertEqual(around.bpmHi, 118)
    }

    // MARK: - Arc phrases

    func testArcPhrases() {
        let peak = BriefExtractor.parse("starts mellow and ends euphoric").arc
        XCTAssertEqual(peak, .peakAndRelease(peakAt: EnergyArc.defaultPeakAt))
        // "builds ... euphoric" resolves to peak-and-release, not plain build.
        XCTAssertEqual(
            BriefExtractor.parse("starts warm, builds after the food, ends euphoric").arc,
            .peakAndRelease(peakAt: EnergyArc.defaultPeakAt))
        XCTAssertEqual(BriefExtractor.parse("wind down the night").arc, .windDown)
        XCTAssertEqual(BriefExtractor.parse("for studying").arc, .steady(level: EnergyArc.defaultLevel))
        XCTAssertEqual(BriefExtractor.parse("a steady background set").arc,
                       .steady(level: EnergyArc.defaultLevel))
        XCTAssertEqual(BriefExtractor.parse("something that builds slowly").arc, .build)
        XCTAssertEqual(BriefExtractor.parse("a gentle wave of energy").arc,
                       .wave(cycles: EnergyArc.defaultCycles))
    }

    func testNoArcForUnrelatedProse() {
        XCTAssertNil(BriefExtractor.parse("rainy Sunday, like a long drive at night").arc)
    }

    // MARK: - +/− vocal and explicit terms

    func testVocalTerms() {
        let shouty = BriefExtractor.parse("nothing with shouty vocals")
        XCTAssertEqual(shouty.negativeTerms, ["shouty vocals"])
        XCTAssertTrue(shouty.positiveTerms.isEmpty)
        XCTAssertEqual(shouty.chips.map(\.label), ["shouty vocals"])

        let none = BriefExtractor.parse("no vocals please")
        XCTAssertEqual(none.negativeTerms, ["vocals"])
        XCTAssertTrue(none.positiveTerms.isEmpty)

        let some = BriefExtractor.parse("with vocals")
        XCTAssertEqual(some.positiveTerms, ["vocals"])
        XCTAssertTrue(some.negativeTerms.isEmpty)
    }

    func testExplicitTerms() {
        let clean = BriefExtractor.parse("no explicit lyrics")
        XCTAssertEqual(clean.allowExplicit, false)
        XCTAssertEqual(clean.negativeTerms, ["explicit"])

        let untouched = BriefExtractor.parse("a lovely dinner set")
        XCTAssertNil(untouched.allowExplicit)
        XCTAssertTrue(untouched.negativeTerms.isEmpty)
    }

    // MARK: - Chips

    func testChipsCoverEveryRecognisedSlot() {
        let parse = BriefExtractor.parse(
            "two hours at 120-128 bpm, builds to euphoric, no shouty vocals")
        let kinds = Set(parse.chips.map(\.kind))
        XCTAssertTrue(kinds.contains(.duration))
        XCTAssertTrue(kinds.contains(.bpm))
        XCTAssertTrue(kinds.contains(.arc))
        XCTAssertTrue(kinds.contains(.negative))
        // The arc "builds to euphoric" → peak-and-release chip.
        XCTAssertTrue(parse.chips.contains { $0.kind == .arc && $0.label.contains("peak") })
    }

    // MARK: - Unrecognised prose and determinism

    func testUnrecognisedTextIsNotAnError() {
        let parse = BriefExtractor.parse("something for a rainy Sunday, like a long drive")
        XCTAssertTrue(parse.chips.isEmpty)
        XCTAssertNil(parse.targetSeconds)
        XCTAssertNil(parse.arc)
        XCTAssertTrue(parse.positiveTerms.isEmpty)
    }

    func testParseIsDeterministic() {
        let prompt = "two hours at 120-128 bpm, builds to euphoric, no shouty vocals"
        XCTAssertEqual(BriefExtractor.parse(prompt), BriefExtractor.parse(prompt))
        // Repeated parses produce identical chip IDs for the UI's ForEach.
        let a = BriefExtractor.parse(prompt).chips.map(\.id)
        let b = BriefExtractor.parse(prompt).chips.map(\.id)
        XCTAssertEqual(a, b)
    }

    // MARK: - Crate-style request shape

    func testChipValuesCarryMachineValues() {
        let parse = BriefExtractor.parse("one hour and twenty tracks")
        let durationChip = parse.chips.first { $0.kind == .duration }
        XCTAssertEqual(durationChip?.value, 3600)
        let countChip = parse.chips.first { $0.kind == .trackCount }
        XCTAssertEqual(countChip?.value, 20)
    }
}
