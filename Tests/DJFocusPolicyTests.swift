import XCTest
@testable import TonearmCore

final class DJFocusPolicyTests: XCTestCase {
    func testEveryDJControlHasAnExhaustiveFocusHome() {
        XCTAssertEqual(Set(DJControlID.allCases).count, 59)
        for control in DJControlID.allCases { _ = DJSurfaceMap.home(for: control) }
        let covered = Set(DJHelpContent.sections.flatMap(\.controls))
        XCTAssertEqual(covered, Set(DJControlID.allCases))
    }

    func testPerformPageTabsAndAlternates() {
        XCTAssertEqual(DJPerformPages.tabs.map(\.title), ["Hot Cue", "Loop", "Pad FX", "Beat Jump"])
        XCTAssertEqual(DJPerformPages.alternate(of: .beatLoop), .loop)
        XCTAssertEqual(DJPerformPages.alternate(of: .loop), .beatLoop)
        XCTAssertEqual(DJPerformPages.alternate(of: .fx), .beatFX)
        XCTAssertEqual(DJPerformPages.alternate(of: .beatFX), .fx)
        XCTAssertEqual(DJPerformPages.autoLoopBeats, [0.25, 0.5, 1, 2, 4, 8, 16, 32])
        XCTAssertEqual(DJPerformPages.beatJumpBeats, [-1, 1, -4, 4, -16, 16, -32, 32])
    }

    func testEveryFocusPadPageHasCanonicalLabels() {
        let empty = DJPadLabelState()
        XCTAssertEqual((0..<8).map { DJPerformPages.padLabel(mode: .hotCue, index: $0, state: empty).title }, ["1", "2", "3", "4", "5", "6", "7", "8"])
        XCTAssertEqual((0..<8).map { DJPerformPages.padLabel(mode: .beatLoop, index: $0, state: empty).title }, ["¼", "½", "1", "2", "4", "8", "16", "32"])
        XCTAssertEqual((0..<8).map { DJPerformPages.padLabel(mode: .loop, index: $0, state: empty).title }, ["In", "Out", "Set 4", "Enter", "½×", "2×", "← 4", "4 →"])
        XCTAssertEqual((0..<8).map { DJPerformPages.padLabel(mode: .fx, index: $0, state: empty).title }, ["Echo ¼", "Echo ½", "Echo 1", "Echo 2", "Echo Out", "Roll", "Reverb", "Brake"])
        XCTAssertEqual((0..<8).map { DJPerformPages.padLabel(mode: .beatFX, index: $0, state: empty).title }, ["Type", "← Beat", "Beat →", "Off", "Ch A", "Ch B", "Master", "Level"])
        XCTAssertEqual((0..<8).map { DJPerformPages.padLabel(mode: .beatJump, index: $0, state: empty).title }, ["← 1", "1 →", "← 4", "4 →", "← 16", "16 →", "← 32", "32 →"])
        XCTAssertEqual(DJPerformPages.padLabel(mode: .hotCue, index: 0, state: empty).caption, "tap to set")
        XCTAssertEqual(DJPerformPages.padLabel(mode: .beatFX, index: 7, state: empty).caption, "50%")
        let beatJump = DJPerformPages.padLabel(mode: .beatJump, index: 4, state: empty)
        XCTAssertEqual(beatJump.title, "← 16")
        XCTAssertEqual(beatJump.caption, "4 bars")
        let cue = DJPerformPages.padLabel(mode: .hotCue, index: 1,
                                          state: DJPadLabelState(hotCuePosition: 32))
        XCTAssertEqual(cue.title, "Cue 2")
        XCTAssertEqual(cue.caption, "2 · 0:32")
    }

    func testChipReadoutHonorsLoadingEmptyPlayingSyncAndOnAir() {
        XCTAssertEqual(DJChipReadout.text(bpm: nil, remaining: 0, isPlaying: false, synced: false, loadPhase: nil, onAir: false), "— · cued")
        XCTAssertEqual(DJChipReadout.text(bpm: nil, remaining: 0, isPlaying: false, synced: false, loadPhase: "ANALYZING", onAir: false), "Analyzing…")
        XCTAssertEqual(DJChipReadout.text(bpm: 119.8, remaining: 168, isPlaying: false, synced: false, loadPhase: nil, onAir: false), "119.8 · cued")
        XCTAssertEqual(DJChipReadout.text(bpm: 116, remaining: 168, isPlaying: true, synced: false, loadPhase: nil, onAir: true), "● 116.0 · −2:48")
        XCTAssertEqual(DJChipReadout.text(bpm: 116, remaining: 168, isPlaying: true, synced: true, loadPhase: nil, onAir: true), "116.0 · SYNC")
    }

    func testWaveformTouchPolicyCoversFocusSeekNudgeScratchAndFrameSearch() {
        XCTAssertEqual(DJWaveformTouchPolicy.action(phase: 0, isPlaying: false, touchMode: .nudge, heldFor: 0, translation: 0, width: 300), .focus)
        XCTAssertEqual(DJWaveformTouchPolicy.action(phase: 0, isPlaying: false, touchMode: .nudge, heldFor: 0.2, translation: 40, width: 300), .seek(40))
        XCTAssertEqual(DJWaveformTouchPolicy.action(phase: 0, isPlaying: true, touchMode: .nudge, heldFor: 0.2, translation: 40, width: 300), .nudge(40))
        XCTAssertEqual(DJWaveformTouchPolicy.action(phase: 0, isPlaying: true, touchMode: .scratch, heldFor: 0.2, translation: 40, width: 300), .scratch(40))
        XCTAssertEqual(DJWaveformTouchPolicy.action(phase: 0, isPlaying: false, touchMode: .nudge, heldFor: 0.35, translation: 40, width: 300), .frameSearch(40))
        XCTAssertEqual(DJWaveformTouchPolicy.action(phase: .infinity, isPlaying: false, touchMode: .nudge, heldFor: 0, translation: 1, width: 300), .none)
    }

    func testCoachPolicyUsesPriorityAndDismissal() {
        XCTAssertEqual(DJCoachPolicy.tip(for: DJCoachSnapshot())?.id, "load-a")
        XCTAssertEqual(DJCoachPolicy.tip(for: DJCoachSnapshot(loadedA: true, playingA: true))?.id, "load-b")
        XCTAssertEqual(DJCoachPolicy.tip(for: DJCoachSnapshot(loadedA: true, playingA: true, loadedB: true))?.id, "sync-b")
        XCTAssertEqual(DJCoachPolicy.tip(for: DJCoachSnapshot(loadedA: true, playingA: true, loadedB: true, syncedB: true))?.id, "play-b")
        XCTAssertNil(DJCoachPolicy.tip(for: DJCoachSnapshot(dismissedTipID: "load-a")))
        XCTAssertEqual(DJCoachPolicy.tip(for: DJCoachSnapshot(loadedA: true, keysCompatible: false))?.id, "keys")
        XCTAssertNil(DJCoachPolicy.tip(for: DJCoachSnapshot(loadedA: true, keysCompatible: nil)))
    }

    func testFocusHelpUsesTheNewSurfaceVocabulary() {
        let copy = DJHelpContent.sections.map(\.body).joined(separator: " ")
        XCTAssertFalse(copy.contains("top row has"))
        XCTAssertTrue(copy.contains("Focus Deck"))
        XCTAssertTrue(copy.contains("My Music"))
    }
}
