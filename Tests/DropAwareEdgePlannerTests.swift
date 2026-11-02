import XCTest
@testable import TonearmCore

final class DropAwareEdgePlannerTests: XCTestCase {
    private func facts(_ id: String, bpm: Double = 120, period: Double = 0.5, rms: Double = -12,
                       duration: Double = 300) -> StarterTrackFacts {
        StarterTrackFacts(id: id, durationSeconds: duration, bpm: bpm, beatPeriod: period,
                         beatPhase: 0.1, rmsDB: rms)
    }

    /// 600 beats (~5 min at 120 bpm), drop/exit lists already bar-snapped as `detect` would leave them.
    private func structure(drops: [Int] = [], exits: [Int] = [], phrasePhase: Int = 0,
                          beatCount: Int = 600, bassLevelsDB: [Double] = []) -> DropAwareTrackStructure {
        DropAwareTrackStructure(barPhase: 0, phrasePhase: phrasePhase, drops: drops.sorted(),
                               exits: exits.sorted(), beatCount: beatCount, bassLevelsDB: bassLevelsDB)
    }

    func testRealDropsOnBothSidesProduceADoubleDrop() throws {
        // Outgoing drops at 320 and 400 (second half of 600); incoming has an early drop at 40.
        let outgoing = structure(drops: [320, 400])
        let incoming = structure(drops: [40])
        let point = try XCTUnwrap(DropAwareEdgePlanner.swapPoint(outgoing: outgoing, incoming: incoming))
        XCTAssertEqual(point.style, .doubleDrop)
        XCTAssertEqual(point.outgoingBeat, 400, "latest drop in the second half wins")
        XCTAssertEqual(point.incomingBeat, 40, "incoming's own first (earliest) drop wins")

        let plan = try XCTUnwrap(DropAwareEdgePlanner.plan(
            blendID: "b", edge: 1, outgoing: facts("a"), outgoingStructure: outgoing,
            incoming: facts("b"), incomingStructure: incoming))
        XCTAssertEqual(plan.style, .doubleDrop)
        XCTAssertEqual(plan.outgoingSwapBeat, 400)
        XCTAssertEqual(plan.incomingSwapBeat, DropAwareEdgePlanner.half)
        XCTAssertEqual(plan.overlapBeats, DropAwareEdgePlanner.overlapBeats)
        XCTAssertNotNil(plan.schedule())
    }

    func testOnlyABassExitProducesABassSwap() throws {
        let outgoing = structure(exits: [450])
        let incoming = structure(drops: [40])
        let point = try XCTUnwrap(DropAwareEdgePlanner.swapPoint(outgoing: outgoing, incoming: incoming))
        XCTAssertEqual(point.style, .bassSwap)
        XCTAssertEqual(point.outgoingBeat, 450)
    }

    func testOnlyAPhraseLineProducesAHardPhraseCut() throws {
        // No drops or exits at all; only phrase-line candidates (every 32 beats from phase 16).
        let outgoing = structure(phrasePhase: 16)
        let incoming = structure(phrasePhase: 8)
        let point = try XCTUnwrap(DropAwareEdgePlanner.swapPoint(outgoing: outgoing, incoming: incoming))
        XCTAssertEqual(point.style, .phraseCut)

        let plan = try XCTUnwrap(DropAwareEdgePlanner.plan(
            blendID: "b", edge: 1, outgoing: facts("a"), outgoingStructure: outgoing,
            incoming: facts("b"), incomingStructure: incoming))
        XCTAssertEqual(plan.style, .phraseCut)
        XCTAssertEqual(plan.overlapBeats, 0)
        XCTAssertNotNil(plan.outgoingStartSeconds)
        XCTAssertNotNil(plan.incomingStartSeconds)
        XCTAssertNil(plan.blendStartSeconds, "a phrase cut has no overlap window")
        XCTAssertNotNil(plan.schedule())
    }

    func testNoUsablePointsReturnsNilNotAGuess() {
        // Incoming has nothing at all (no drops, phrase phase past its own midpoint).
        let outgoing = structure(drops: [400])
        let incoming = structure(phrasePhase: 0, beatCount: 10)
        XCTAssertNil(DropAwareEdgePlanner.swapPoint(outgoing: outgoing, incoming: incoming))
    }

    func testOutgoingTrackTooShortForTheOverlapWindowRejectsEveryPoint() {
        // A 50-beat track can never satisfy `i - half >= 0 && i + half < beatCount - 1` for
        // half == 32 (that needs i in [32, 17), impossible) — no drop, exit or phrase line on
        // the outgoing side qualifies, regardless of what the incoming side offers.
        let outgoing = structure(drops: [10], beatCount: 50)
        let incoming = structure(drops: [40])
        XCTAssertNil(DropAwareEdgePlanner.swapPoint(outgoing: outgoing, incoming: incoming))
    }

    func testTempoMismatchBeyondToleranceStillFailsEvenWithRealDrops() {
        let outgoing = structure(drops: [400])
        let incoming = structure(drops: [40])
        let plan = DropAwareEdgePlanner.plan(
            blendID: "b", edge: 1, outgoing: facts("a", bpm: 120), outgoingStructure: outgoing,
            incoming: facts("b", bpm: 140), incomingStructure: incoming)
        XCTAssertNil(plan)
    }

    func testBassPresentFromStartFallsBackToAPhraseLineWithNoDropAtAll() throws {
        // Incoming has no drop anywhere, but its bass is present from the start (flat loudness
        // curve) — its first candidate should be a phrase line, not nothing.
        let flatLevels = [Double](repeating: -10, count: 300)
        let incoming = structure(phrasePhase: 24, beatCount: 600, bassLevelsDB: flatLevels)
        let outgoing = structure(drops: [400])
        let point = try XCTUnwrap(DropAwareEdgePlanner.swapPoint(outgoing: outgoing, incoming: incoming))
        XCTAssertEqual(point.incomingBeat, 24 + 32, "first phrase line at least half a window past silence")
    }

    func testADropAlwaysOutranksAPhraseLineEvenWithBassFromStart() throws {
        // Even when bass is present from the start, incoming's own early drop still wins — blend-
        // lab never prefers the phrase-line tier over a real drop.
        let flatLevels = [Double](repeating: -10, count: 300)
        let incoming = structure(drops: [40], phrasePhase: 24, beatCount: 600, bassLevelsDB: flatLevels)
        let outgoing = structure(drops: [400])
        let point = try XCTUnwrap(DropAwareEdgePlanner.swapPoint(outgoing: outgoing, incoming: incoming))
        XCTAssertEqual(point.incomingBeat, 40)
    }
}
