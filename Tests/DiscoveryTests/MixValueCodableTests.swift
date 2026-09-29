import XCTest
@testable import TonearmCore

final class MixValueCodableTests: XCTestCase {
    func testMixAndTransitionValuesRoundTrip() throws {
        let candidate = MixCandidate(trackID: 1, bpm: 124, camelot: "8A", energy: 0.7,
                                     artist: "Artist", albumID: 2, duration: 180,
                                     embedding: [0.1, 0.2])
        let request = MixRequest(candidates: [candidate], shape: .warmUpPeakCoolDown,
                                 targetDuration: 900, lockedFirst: 1, locks: [1: 0], seed: 42)
        let edge = EdgeScore(key: .adjacentUp, bpmDeltaPct: 2, energyDelta: 0.1,
                             similarity: 0.2, shapeDeviation: 0.03, total: 1.2,
                             flags: [.tempoJump, .unavoidable(.limitedTempoPool)])
        let runner = RunnerUp(trackID: 2, total: 3, lostBecause: [.keyClash],
                              keyRelation: .clash(steps: 4), bpmDeltaPct: 12)
        let step = MixStep(trackID: 1, position: 0, effectiveBPM: 124,
                           tempoRelation: .same, reasons: [.lockedByUser], edgeIn: edge,
                           runnersUp: [runner])
        let plan = MixPlan(steps: [step],
                           excluded: [MixExclusion(trackID: 3, reason: .notAnalyzed(missing: [.bpm]))],
                           summary: MixSummary(bpmRange: 120...130, harmonicEdges: 1,
                                               totalEdges: 1, tempoJumps: 0, againstShape: 0,
                                               duration: 180, weakestEdges: [0]), request: request)
        let transition = TransitionPlan(fromTrackID: 1, toTrackID: 2,
                                        style: .beatmatchedBlend, exitTime: 48, entryTime: 4,
                                        overlapBeats: 16, overlapSeconds: 8, blendRate: 0.98,
                                        rateRampBeats: 16, gainMatchDB: -2,
                                        keyRelation: .relative, bpmDeltaPct: 2,
                                        confidence: 0.9,
                                        reasons: [.tempoMatched(pct: 2), .keyCompatible(.relative)])

        try assertRoundTrip(MixShape.risingBPM)
        try assertRoundTrip(MixTempoRelation.halfTime)
        try assertRoundTrip(MixMissingAnalysis.bpmAndKey)
        try assertRoundTrip(KeyRelation.energyBoost)
        try assertRoundTrip(EdgeFlag.againstShape)
        try assertRoundTrip(UnavoidableReason.onlyRemainingOption)
        try assertRoundTrip(PlacementReason.soundsSimilar)
        try assertRoundTrip(MixExclusionReason.overTargetLength)
        try assertRoundTrip(TransitionStyle.phraseFade)
        try assertRoundTrip(GridPrepState.analyzing(0.5))
        try assertRoundTrip(TransitionReason.gridNotReady(.queued))
        try assertRoundTrip(candidate)
        try assertRoundTrip(request)
        try assertRoundTrip(edge)
        try assertRoundTrip(runner)
        try assertRoundTrip(step)
        try assertRoundTrip(plan)
        try assertRoundTrip(transition)
    }

    private func assertRoundTrip<T: Codable & Equatable>(_ value: T,
                                                          file: StaticString = #filePath,
                                                          line: UInt = #line) throws {
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(T.self, from: data)
        XCTAssertEqual(decoded, value, file: file, line: line)
    }
}
