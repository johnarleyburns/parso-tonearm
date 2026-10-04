import XCTest
@testable import TonearmCore
@testable import TonearmDiscovery

final class TransitionPlannerTests: XCTestCase {
    func testGaplessAndUserOverrideTakePriority() {
        let context = TransitionPlanningContext(fromTrackID: 1, toTrackID: 2,
                                                 sameAlbumInOrder: true,
                                                 userChosePlainFade: true)
        let plan = TransitionPlanner.plan(from: payload(bpm: 120), to: payload(bpm: 121), context: context)
        XCTAssertEqual(plan.style, .gapless)

        let override = TransitionPlanner.plan(
            from: payload(bpm: 120), to: payload(bpm: 121),
            context: TransitionPlanningContext(fromTrackID: 1, toTrackID: 2,
                                                userChosePlainFade: true))
        XCTAssertEqual(override.style, .plainCrossfade)
        XCTAssertTrue(override.reasons.contains(.userChosePlainFade))
    }

    func testMissingOrUnbufferedPayloadExplainsDowngrade() {
        let missing = TransitionPlanner.plan(
            from: nil, to: payload(bpm: 120),
            context: TransitionPlanningContext(fromTrackID: 1, toTrackID: 2,
                                                prepState: .analyzing(0.4)))
        XCTAssertEqual(missing.style, .plainCrossfade)
        XCTAssertTrue(missing.reasons.contains(.gridNotReady(.analyzing(0.4))))

        let unbuffered = TransitionPlanner.plan(
            from: payload(bpm: 120), to: payload(bpm: 121),
            context: TransitionPlanningContext(fromTrackID: 1, toTrackID: 2,
                                                incomingBuffered: false))
        XCTAssertEqual(unbuffered.downgradedFrom, .beatmatchedBlend)
        XCTAssertTrue(unbuffered.reasons.contains(.notBuffered))
    }

    func testBeatmatchedBlendSnapsAndReportsSilenceKeyAndLoudness() {
        let outgoing = payload(bpm: 120, key: "8A", loudness: [-14])
        let incoming = payload(bpm: 124, key: "8A", leadingSilence: 1,
                               loudness: [-10])
        let context = TransitionPlanningContext(fromTrackID: 1, toTrackID: 2,
                                                fromDuration: 60, toDuration: 60)
        let plan = TransitionPlanner.plan(from: outgoing, to: incoming, context: context)

        XCTAssertEqual(plan.style, .beatmatchedBlend)
        XCTAssertEqual(plan.overlapBeats, 96)
        XCTAssertEqual(plan.rateRampBeats, 96)
        XCTAssertEqual(plan.keyRelation, .same)
        XCTAssertTrue(plan.reasons.contains { if case .skippedLeadingSilence = $0 { return true }; return false })
        XCTAssertTrue(plan.reasons.contains { if case .loudnessMatched = $0 { return true }; return false })
    }

    func testPhraseFadeReportsTheBlockedBeatmatchedReasons() {
        let plan = TransitionPlanner.plan(
            from: payload(bpm: 100, confidence: 0.4, constant: false),
            to: payload(bpm: 132, confidence: 0.5),
            context: TransitionPlanningContext(fromTrackID: 1, toTrackID: 2))

        XCTAssertEqual(plan.style, .phraseFade)
        XCTAssertEqual(plan.downgradedFrom, .beatmatchedBlend)
        XCTAssertTrue(plan.reasons.contains(.variableTempo))
        XCTAssertTrue(plan.reasons.contains { if case .lowTempoConfidence = $0 { return true }; return false })
        XCTAssertTrue(plan.reasons.contains { if case .tempoTooFar = $0 { return true }; return false })
    }

    private func payload(bpm: Double, key: String = "8A", confidence: Double = 0.9,
                         constant: Bool = true, leadingSilence: Double = 0,
                         loudness: [Double] = [-12]) -> DJTrackPrepPayload {
        let beats = stride(from: 0.0, through: 60.0, by: 0.5).map { $0 }
        let downbeats = stride(from: 0.0, through: 60.0, by: 2.0).map { $0 }
        let waveform = (0..<120).map { index in
            DJTrackPrepPayload.WaveformBin(min: 0, max: 1,
                                           rms: index < 2 && leadingSilence > 0 ? 0.001 : 0.2,
                                           bandRMS: [0.2, 0.2, 0.2])
        }
        return DJTrackPrepPayload(sampleRate: 48_000, channels: 2, sourceFrameCount: 2_880_000,
                                  duration: 60, bpm: bpm, tempoConfidence: confidence,
                                  beatPositions: beats, downbeatPositions: downbeats,
                                  isConstantTempo: constant,
                                  key: .init(tonic: 0, mode: "major", camelot: key,
                                             openKey: "1d", confidence: confidence),
                                  sections: [.init(start: 48, kind: "outro", bar: 13)],
                                  waveform: waveform, loudness: loudness)
    }
}
