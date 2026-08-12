import XCTest

@testable import TonearmDJ

/// Commit 4.6 — the pure beat-sync math (§32, AT-ENGINE-SYNC-\*). `SyncEngine`
/// is the §32.3 pure kernel: no I/O, no allocation, deterministic, so the phase
/// and tempo math is golden-pinned here against known grids, and the render
/// layer's application is asserted separately in `EngineOfflineTests`.
@MainActor
final class SyncMathTests: XCTestCase {

    // MARK: - Grid phase (DeckGrid.beatPhase / barPhase)

    func testBeatPhaseIsPeriodicOnTheGrid() {
        // 120 BPM @ 48 kHz → one beat = 24 000 samples, reference at 0.
        let grid = DeckGrid(referenceSample: 0, bpm: 120, beatsPerBar: 4, sampleRate: 48_000)
        XCTAssertEqual(grid.beatPhase(at: 0), 0)
        XCTAssertEqual(grid.beatPhase(at: 6000), 0.25, accuracy: 1e-12)
        XCTAssertEqual(grid.beatPhase(at: 12_000), 0.5, accuracy: 1e-12)
        XCTAssertEqual(grid.beatPhase(at: 24_000), 0, accuracy: 1e-12, "a boundary wraps to phase 0")
        XCTAssertEqual(grid.beatPhase(at: 30_000), 0.25, accuracy: 1e-12)
        XCTAssertEqual(grid.beatPhase(at: 119_999), 0.999958, accuracy: 1e-4)
    }

    func testBeatPhaseRespectsGridReference() {
        let grid = DeckGrid(referenceSample: 500, bpm: 120, beatsPerBar: 4, sampleRate: 48_000)
        XCTAssertEqual(grid.beatPhase(at: 500), 0, accuracy: 1e-12)
        XCTAssertEqual(grid.beatPhase(at: 6500), 0.25, accuracy: 1e-12)
        XCTAssertEqual(grid.beatPhase(at: 24_500), 0, accuracy: 1e-12, "reference plus one beat wraps")
    }

    func testBarPhaseCoversBeatsPerBar() {
        // One bar = 4 beats = 96 000 samples.
        let grid = DeckGrid(referenceSample: 0, bpm: 120, beatsPerBar: 4, sampleRate: 48_000)
        XCTAssertEqual(grid.barPhase(at: 0), 0)
        XCTAssertEqual(grid.barPhase(at: 24_000), 0.25, accuracy: 1e-12, "beat 2 of the bar")
        XCTAssertEqual(grid.barPhase(at: 96_000), 0, accuracy: 1e-12, "a bar boundary wraps")
    }

    // MARK: - Phase difference (SyncClock.phaseDifference)

    func testPhaseDifferenceReturnsShortestSignedDelta() {
        XCTAssertEqual(SyncClock.phaseDifference(0.25, 0.25), 0, accuracy: 1e-12)
        XCTAssertEqual(SyncClock.phaseDifference(0.8, 0.1), -0.3, accuracy: 1e-12,
                       "0.7 wraps to −0.3 across the 1.0 boundary")
        XCTAssertEqual(SyncClock.phaseDifference(0.1, 0.8), 0.3, accuracy: 1e-12)
        XCTAssertEqual(SyncClock.phaseDifference(0.9, 0.1), -0.2, accuracy: 1e-12)
        XCTAssertEqual(SyncClock.phaseDifference(0.5, 0), 0.5, accuracy: 1e-12,
                       "exactly +0.5 is in the closed half")
        XCTAssertEqual(SyncClock.phaseDifference(0, 0.5), 0.5, accuracy: 1e-12,
                       "−0.5 wraps to +0.5 — the bound is (−0.5, 0.5], §32.1")
        XCTAssertEqual(SyncClock.phaseDifference(0.999, 0.001), -0.002, accuracy: 1e-6)
    }

    // MARK: - correction (beat sync, §32.1)

    func testCorrectionTempoMatchesMaster() {
        // Master 120 BPM at unity; synced 100 BPM → target rate 1.2.
        let master = SyncClock(playheadSample: 0, grid: grid(120), rate: 1)
        let synced = SyncClock(playheadSample: 0, grid: grid(100), rate: 1)
        let correction = SyncEngine.correction(master: master, synced: synced, atMasterSample: 0)
        XCTAssertEqual(correction.setRate, 1.2, accuracy: 1e-6)
        XCTAssertEqual(correction.playheadShiftSamples, 0,
                       "identical phases need no nudge")
    }

    func testCorrectionPhaseAlignsWithSignedNudge() {
        // Master at phase 0.25 (playhead 6000); synced at phase 0.5 (12000).
        // The synced deck must move back half a beat (−0.25 × 24 000).
        let master = SyncClock(playheadSample: 6000, grid: grid(120), rate: 1)
        let synced = SyncClock(playheadSample: 12_000, grid: grid(120), rate: 1)
        let correction = SyncEngine.correction(master: master, synced: synced, atMasterSample: 42_000)
        XCTAssertEqual(correction.setRate, 1, accuracy: 1e-6, "same BPM → unity rate")
        XCTAssertEqual(correction.playheadShiftSamples, -6000)

        // Applying the nudge brings the synced playhead onto the master's phase.
        let shifted = synced.playheadSample + Double(correction.playheadShiftSamples)
        let masterPhase = master.beatPhase(at: master.playheadSample)
        let syncedPhase = synced.beatPhase(at: shifted)
        XCTAssertEqual(masterPhase, syncedPhase, accuracy: 1e-9,
                       "after the nudge both decks share the master's beat phase")
    }

    func testCorrectionIsDeterministic() {
        let master = SyncClock(playheadSample: 6000, grid: grid(120), rate: 1)
        let synced = SyncClock(playheadSample: 12_000, grid: grid(120), rate: 1)
        let a = SyncEngine.correction(master: master, synced: synced, atMasterSample: 100)
        let b = SyncEngine.correction(master: master, synced: synced, atMasterSample: 100)
        XCTAssertEqual(a, b, "identical inputs must produce identical corrections")
    }

    func testCorrectionConsidersMasterRateInTempoMatch() {
        // Master pitched +10% → effective 132 BPM; synced 100 → rate 1.32.
        let master = SyncClock(playheadSample: 0, grid: grid(120), rate: 1.1)
        let synced = SyncClock(playheadSample: 0, grid: grid(100), rate: 1)
        let correction = SyncEngine.correction(master: master, synced: synced, atMasterSample: 0)
        XCTAssertEqual(correction.setRate, 1.32, accuracy: 1e-6)
    }

    // MARK: - downbeatCorrection (bar sync, §32.2)

    func testDownbeatCorrectionAlignsBars() {
        // Master mid-bar-2 (bar phase 0.5, playhead 48 000); synced beat 2 of
        // bar 1 (bar phase 0.25, playhead 24 000). The shortest path to the
        // master's downbeat phase is +1 beat forward, so bar sync shifts the
        // synced deck +24 000 samples and both decks land on bar phase 0.5.
        let master = SyncClock(playheadSample: 48_000, grid: grid(120), rate: 1)
        let synced = SyncClock(playheadSample: 24_000, grid: grid(120), rate: 1)
        let correction = SyncEngine.downbeatCorrection(master: master, synced: synced, atMasterSample: 0)
        XCTAssertEqual(correction.setRate, 1, accuracy: 1e-6)
        XCTAssertEqual(correction.playheadShiftSamples, 24_000,
                       "+0.25 bar forward is the shortest wrap, not −0.75 back")

        let shifted = synced.playheadSample + Double(correction.playheadShiftSamples)
        XCTAssertEqual(master.barPhase(at: master.playheadSample),
                       synced.barPhase(at: shifted), accuracy: 1e-9,
                       "bar sync puts both decks on the same downbeat")
    }

    func testDownbeatCorrectionKeepsBeatPhaseRelationAcrossBoundary() {
        // Synced deck just past its bar boundary (phase 0.02); master near its
        // downbeat (phase 0.98). The shortest wrap must pull the synced deck
        // back ~0.04 of a bar, i.e. −0.16 beats ≈ −3840 samples.
        let master = SyncClock(playheadSample: 94_080, grid: grid(120), rate: 1)
        let synced = SyncClock(playheadSample: 1920, grid: grid(120), rate: 1)
        let correction = SyncEngine.downbeatCorrection(master: master, synced: synced, atMasterSample: 0)
        XCTAssertEqual(correction.playheadShiftSamples, -3840, accuracy: 1)
    }

    // MARK: - continuousRate (§32.1)

    func testContinuousRateKeepsEffectiveBPMMatched() {
        XCTAssertEqual(SyncEngine.continuousRate(masterRate: 1, masterBPM: 120, syncedBPM: 100),
                       1.2, accuracy: 1e-9)
        XCTAssertEqual(SyncEngine.continuousRate(masterRate: 1.1, masterBPM: 120, syncedBPM: 100),
                       1.32, accuracy: 1e-9, "a master pitch change moves the synced deck with it")
        XCTAssertEqual(SyncEngine.continuousRate(masterRate: 1, masterBPM: 120, syncedBPM: 120),
                       1.0, accuracy: 1e-9)
        XCTAssertEqual(SyncEngine.continuousRate(masterRate: 1.2, masterBPM: 100, syncedBPM: 100),
                       1.2, accuracy: 1e-9)
    }

    func testContinuousRateGuardsZeroSyncedBPM() {
        XCTAssertEqual(SyncEngine.continuousRate(masterRate: 1.2, masterBPM: 120, syncedBPM: 0), 1)
    }

    // MARK: - Helpers

    private func grid(_ bpm: Double) -> DeckGrid {
        DeckGrid(referenceSample: 0, bpm: bpm, beatsPerBar: 4, sampleRate: 48_000)
    }
}
