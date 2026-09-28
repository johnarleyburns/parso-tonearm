import XCTest
@testable import TonearmCore

final class DJGridLayoutTests: XCTestCase {
    func testPortraitAndLandscapeLayoutsFillSurfaceWithEqualCells() {
        let layout = DJGridLayout(size: CGSize(width: 393 - 12, height: 670), rows: 11, gap: 4)
        XCTAssertEqual(layout.columns, 8)
        XCTAssertEqual(layout.rows, 11)
        XCTAssertGreaterThanOrEqual(layout.cellWidth, 44)
        XCTAssertEqual(layout.frame(col: 0, row: 0, colSpan: 8).maxX, 381, accuracy: 0.001)
        XCTAssertEqual(layout.frame(col: 0, row: 0, colSpan: 8, rowSpan: 11).maxY, 670, accuracy: 0.001)

        let landscape = DJGridLayout(size: CGSize(width: 718, height: 360), columns: 15, rows: 8, gap: 4)
        XCTAssertEqual(landscape.columns, 15)
        XCTAssertEqual(landscape.rows, 8)
        XCTAssertGreaterThanOrEqual(landscape.cellWidth, 44)
        XCTAssertEqual(landscape.frame(col: 0, row: 0, colSpan: 15).maxX, 718, accuracy: 0.001)
    }

    func testEightByEightCompatibilityLayoutFillsSurfaceWithEqualCells() {
        let layout = DJGridLayout(size: CGSize(width: 800, height: 400), gap: 8)
        XCTAssertEqual(layout.frame(col: 0, row: 0).width, layout.cellWidth)
        XCTAssertEqual(layout.frame(col: 0, row: 0).height, layout.rowHeight)
        XCTAssertEqual(layout.frame(col: 0, row: 0, span: 8).maxX, 800, accuracy: 0.001)
        XCTAssertEqual(layout.frame(col: 0, row: 0, span: 8).maxY, layout.rowHeight, accuracy: 0.001)
        XCTAssertEqual(layout.frame(col: 2, row: 3, span: 3).width,
                       layout.cellWidth * 3 + layout.gap * 2, accuracy: 0.001)
    }

    func testKeyFormatterKeepsCamelotAndRejectsUnknownValues() {
        XCTAssertEqual(DJKeyFormatter.format("8A"), "8A")
        XCTAssertEqual(DJKeyFormatter.format("12B"), "12B")
        XCTAssertEqual(DJKeyFormatter.format("C major"), "—")
        XCTAssertEqual(DJKeyFormatter.format(nil), "—")
        XCTAssertEqual(DJKeyFormatter.shifted("6B", semitones: 2), "6B +2")
        XCTAssertEqual(DJKeyFormatter.shifted("6B", semitones: 0), "6B")
    }

    func testGridOverrideRebuildsBeatAndBarPositionsFromBPMAndFirstBeat() {
        XCTAssertEqual(DJGridOverride.positions(bpm: 120, firstBeat: 0.25, duration: 2.1),
                       [0.25, 0.75, 1.25, 1.75])
        XCTAssertEqual(DJGridOverride.positions(bpm: 120, firstBeat: 0.25, duration: 5, beatsPerBar: 4),
                       [0.25, 2.25, 4.25])
        XCTAssertTrue(DJGridOverride.positions(bpm: 0, firstBeat: 0, duration: 10).isEmpty)
    }

    func testCueTransportCoversCDJPressRulesAndPausedSeek() {
        var state = DJCueTransport()
        XCTAssertEqual(state.reduce(.cueDown, isPlaying: false, position: 12, cuePoint: 8), .setCue(12))
        XCTAssertEqual(state.reduce(.cueUp, isPlaying: true, position: 12, cuePoint: 12), .cuePlayRelease)
        XCTAssertEqual(state.reduce(.cueDown, isPlaying: true, position: 20, cuePoint: 12), .jumpToCue)
        XCTAssertEqual(state.reduce(.seek(40), isPlaying: false, position: 20, cuePoint: 12), .seek(40))
        XCTAssertEqual(state.reduce(.seek(40), isPlaying: true, position: 20, cuePoint: 12), .none)
    }

    func testJogMappingModesAndTempoClamp() {
        XCTAssertEqual(DJJogMapper.action(angle: 0.1, isPlaying: true, vinyl: false, bpm: 128), .nudge(0.4))
        guard case let .frameSearch(frame) = DJJogMapper.action(angle: 0.1, isPlaying: false, vinyl: true, bpm: 128) else {
            return XCTFail("expected frame search")
        }
        XCTAssertEqual(frame, 0.006, accuracy: 0.0001)
        XCTAssertEqual(DJJogMapper.tempoStep(angle: 4, current: 0, range: 6), 6)
        XCTAssertEqual(DJJogMapper.tempoStep(angle: -4, current: 0, range: 6), -6)
    }

    func testKnobAndFaderMappings() {
        XCTAssertEqual(DJKnobMapping.cfxLabel(0.5), "OFF")
        XCTAssertEqual(DJKnobMapping.cfxLabel(0.35), "LPF 30")
        XCTAssertEqual(DJKnobMapping.isolatorDB(0.02), nil)
        XCTAssertEqual(DJKnobMapping.display(0.5), "0 dB")
        XCTAssertEqual(DJFaderMapping.value(handleCenter: 25, firstCenter: 10, lastCenter: 40), 0.5)
        XCTAssertEqual(DJFaderMapping.snapped(0.51), 0.5)
    }

    func testLoopPadsUseCurrentBPMAndExitToggle() {
        var loop = DJLoopState()
        loop.pressIn(at: 10, isPlaying: true)
        loop.pressSet(bpm: 120, duration: 60)
        XCTAssertEqual(loop.outPoint ?? -1, 12, accuracy: 0.001)
        loop.pressEnter()
        XCTAssertTrue(loop.active)
        loop.pressEnter()
        XCTAssertTrue(loop.exitPending)
        loop.pressEnter()
        XCTAssertFalse(loop.exitPending)
    }

    func testHelpSearchIsCaseAndDiacriticInsensitiveAndUsesANDTerms() {
        let topics = [
            DJHelpTopic(title: "Loops", body: "Reloop with the pad mode", keywords: "reloop pad mode"),
            DJHelpTopic(title: "Jog", body: "Pitch bend and nudge", keywords: "pitch bend")
        ]
        XCTAssertEqual(DJHelpSearch.filter(topics, query: "RELOOP mode").count, 1)
        XCTAssertEqual(DJHelpSearch.filter(topics, query: "pitch bend").count, 1)
        XCTAssertTrue(DJHelpSearch.filter(topics, query: "not-a-feature").isEmpty)
    }

    func testDJHelpHasAllSeventeenSectionsAndEveryControlCovered() {
        XCTAssertEqual(DJHelpContent.sections.count, 17)
        XCTAssertEqual(DJHelpContent.sections.map(\.title), [
            "Start here", "Performance pads: choose what they do", "Play and cue (CDJ CUE)",
            "Jog wheel", "Waveforms and finding your place", "Hot cues", "Loops and beat jump",
            "Tempo, sync and key", "Deck modes", "Pad FX", "Beat FX", "Mixer",
            "Headphones, output and master", "Record your mix", "Track prep and sync",
            "CDJ-3000 and DDJ-FLX4 → Platterhead", "Hardware-only (not in the app)"
        ])
        let covered = Set(DJHelpContent.sections.flatMap(\.controls))
        XCTAssertEqual(covered, Set(DJControlID.allCases))
    }

    func testDJLoadScopeCoversMyMusicBrowsers() {
        XCTAssertNil(DJLoadLibraryScope.playlists.browseMode)
        XCTAssertEqual(DJLoadLibraryScope.artists.browseMode, .artists)
        XCTAssertEqual(DJLoadLibraryScope.albums.browseMode, .albums)
        XCTAssertEqual(DJLoadLibraryScope.songs.browseMode, .songs)
        XCTAssertEqual(DJLoadLibraryScope.genres.browseMode, .genres)
    }

    func testDJTrackPrepPayloadRoundTripsAndRejectsStaleAlgorithm() throws {
        let payload = DJTrackPrepPayload(
            sampleRate: 48_000, channels: 2, sourceFrameCount: 96_000,
            duration: 2, bpm: 120, tempoConfidence: 0.9,
            beatPositions: [0, 0.5, 1], downbeatPositions: [0],
            isConstantTempo: true,
            key: .init(tonic: 0, mode: "major", camelot: "8B", openKey: "1d", confidence: 0.8),
            sections: [],
            waveform: [.init(min: -1, max: 1, rms: 0.5, bandRMS: [0.2, 0.3, 0.4])],
            loudness: [-14, -1, 0, 0])
        let data = try payload.encoded()
        XCTAssertEqual(try DJTrackPrepPayload.decoded(data), payload)

        var stale = payload
        stale.algorithmID = "old-analysis"
        XCTAssertThrowsError(try DJTrackPrepPayload.decoded(stale.encoded())) { error in
            XCTAssertEqual(error as? DJTrackPrepPayloadError, .stale)
        }
    }
}
