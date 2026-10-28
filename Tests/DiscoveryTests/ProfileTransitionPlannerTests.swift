#if !os(watchOS)
import XCTest
@testable import TonearmCore
@testable import TonearmDiscovery

/// Synthetic profiles only: no audio decode, no waveform.
final class ProfileTransitionPlannerTests: XCTestCase {
    typealias Planner = ProfileTransitionPlanner

    func profile(period: Double = 0.5, phase: Double = 0.1, confidence: Double = 0.9,
                 outro: Double? = 170, phrases: [Double] = [0, 8, 16, 160, 168],
                 envelope: [Float] = [-20, -18]) -> TransitionProfile {
        TransitionProfile(beatPeriodSeconds: period, beatPhaseSeconds: phase, beatConfidence: confidence,
                          introEndSeconds: 8, outroStartSeconds: outro, phraseBoundariesSeconds: phrases,
                          loudnessEnvelopeDB: envelope, peak: 0.9)
    }

    func features(_ id: Int64, rev: String = "r1", duration: Double = 200,
                  _ p: TransitionProfile?) -> TrackTransitionFeatures {
        TrackTransitionFeatures(trackID: id, assetRevision: rev, durationSeconds: duration, bpm: 120, profile: p)
    }

    func input(_ a: TransitionProfile?, _ b: TransitionProfile?, duration: Double = 12,
               outDur: Double = 200, inDur: Double = 200) -> ProfileTransitionPlanInput {
        .init(outgoing: features(1, duration: outDur, a), incoming: features(2, duration: inDur, b),
              requestedDuration: duration)
    }

    func assertValid(_ plan: ProfileTransitionPlan, _ i: ProfileTransitionPlanInput,
                     file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThanOrEqual(plan.outgoingStart, 0, file: file, line: line)
        XCTAssertGreaterThanOrEqual(plan.incomingStart, 0, file: file, line: line)
        XCTAssertLessThanOrEqual(plan.outgoingStart + plan.duration, i.outgoing.durationSeconds + 1e-9, file: file, line: line)
        XCTAssertLessThanOrEqual(plan.incomingStart + plan.duration * (plan.tempoRatio ?? 1),
                                 i.incoming.durationSeconds + 1e-9, file: file, line: line)
    }

    func testPhraseAlignedBeatMatchedIsDeterministic() throws {
        let i = input(profile(), profile(period: 0.51, phase: 0.2))
        let plan = try Planner().makePlan(i)
        XCTAssertEqual(plan, try Planner().makePlan(i))
        XCTAssertEqual(plan.quality, .phraseAlignedBeatMatched)
        // Nearest outgoing phrase to the 170 s outro is 168 s, snapped to the 0.5 s grid (phase 0.1).
        XCTAssertEqual(plan.outgoingStart, 168.1, accuracy: 1e-9)
        XCTAssertEqual(plan.incomingStart, 0.2, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(plan.tempoRatio), 0.51 / 0.5, accuracy: 1e-12)
        XCTAssertTrue(plan.explanation.contains("phraseAligned"))
        assertValid(plan, i)
    }

    func testBeatMatchedWithoutPhraseData() throws {
        let i = input(profile(phrases: []), profile(phrases: []))
        let plan = try Planner().makePlan(i)
        XCTAssertEqual(plan.quality, .beatMatched)
        XCTAssertEqual(plan.outgoingStart, 170.1, accuracy: 1e-9)
        XCTAssertEqual(plan.incomingStart, 0.1, accuracy: 1e-9)
        XCTAssertNotNil(plan.tempoRatio)
        XCTAssertTrue(plan.explanation.contains("phraseCuesUnusable"))
        assertValid(plan, i)
    }

    func testPhraseCuesNotFittingDurationDegradeToBeatMatched() throws {
        // Only boundaries too late for a 12 s blend in the outgoing track.
        let i = input(profile(phrases: [199]), profile())
        XCTAssertEqual(try Planner().makePlan(i).quality, .beatMatched)
    }

    func testMissingLowConfidenceAndInvalidFallBackWithoutTempoRatio() throws {
        let cases: [(TransitionProfile?, TransitionProfile?, String)] = [
            (nil, profile(), "outgoingProfileMissing"),
            (profile(), nil, "incomingProfileMissing"),
            (profile(confidence: 0.2), profile(), "outgoingBeatLow"),
            (profile(), profile(confidence: 0.59), "incomingBeatLow"),
            (profile(period: -1), profile(), "outgoingProfileInvalid"),
            (profile(), profile(confidence: .nan), "incomingProfileInvalid"),
            (TransitionProfile(beatConfidence: 0.9), profile(), "outgoingBeatLow"),
        ]
        for (a, b, reason) in cases {
            let i = input(a, b)
            let plan = try Planner().makePlan(i)
            XCTAssertEqual(plan.quality, .energyCrossfadeFallback, reason)
            XCTAssertNil(plan.tempoRatio, reason)
            XCTAssertTrue(plan.explanation.contains(reason), "\(reason) in \(plan.explanation)")
            assertValid(plan, i)
        }
    }

    func testTempoLimitBoundary() throws {
        let inside = try Planner().makePlan(input(profile(), profile(period: 0.5 * 1.06)))
        XCTAssertEqual(inside.quality, .phraseAlignedBeatMatched)
        let outside = try Planner().makePlan(input(profile(), profile(period: 0.5 * 1.07)))
        XCTAssertEqual(outside.quality, .energyCrossfadeFallback)
        XCTAssertNil(outside.tempoRatio)
        XCTAssertTrue(outside.explanation.contains("tempoOutOfRange"))
    }

    func testBadCuesNegativeTimesAndEmptyEnvelopeAreSafe() throws {
        // Cue beyond the track, negative cue (invalid), empty envelope.
        let beyond = input(profile(outro: 9_999, phrases: [9_999]), profile())
        let p1 = try Planner().makePlan(beyond)
        assertValid(p1, beyond)
        let negative = input(profile(outro: -5), profile(phrases: [-1, 8]))
        let p2 = try Planner().makePlan(negative)
        XCTAssertEqual(p2.quality, .energyCrossfadeFallback)
        assertValid(p2, negative)
        let empty = input(profile(envelope: []), profile(envelope: []))
        let p3 = try Planner().makePlan(empty)
        XCTAssertTrue(p3.explanation.contains("envelopeMissing"))
        assertValid(p3, empty)
    }

    func testDurationClampedAndInvalidInputsRejected() throws {
        let short = input(profile(), profile(), duration: 500, outDur: 30, inDur: 20)
        let plan = try Planner().makePlan(short)
        XCTAssertLessThanOrEqual(plan.duration, 20)
        XCTAssertTrue(plan.explanation.contains("durationClamped"))
        assertValid(plan, short)
        XCTAssertThrowsError(try Planner().makePlan(input(profile(), profile(), duration: 0)))
        XCTAssertThrowsError(try Planner().makePlan(input(profile(), profile(), duration: .nan)))
        XCTAssertThrowsError(try Planner().makePlan(input(profile(), profile(), outDur: 0)))
        XCTAssertThrowsError(try Planner().makePlan(input(profile(), profile(), inDur: -3)))
    }

    func testCacheKeyChangesWithEveryInput() {
        let base = input(profile(), profile())
        let ctx = { (i: ProfileTransitionPlanInput, fp: String) in
            Planner.cacheContext(for: i, embeddingSpaceFingerprint: fp)
        }
        let baseCtx = ctx(base, "space-a")
        XCTAssertEqual(baseCtx, ctx(base, "space-a"))
        var variants: [BlendPlanCache.ProfileContext] = []
        let changedRev = ProfileTransitionPlanInput(outgoing: features(1, rev: "r2", profile()), incoming: base.incoming, requestedDuration: 12)
        variants.append(ctx(changedRev, "space-a"))
        variants.append(ctx(.init(outgoing: base.outgoing, incoming: features(2, rev: "r9", profile()), requestedDuration: 12), "space-a"))
        variants.append(ctx(input(profile(phase: 0.2), profile()), "space-a"))
        variants.append(ctx(input(profile(), profile(confidence: 0.8)), "space-a"))
        variants.append(ctx(input(profile(), profile(), duration: 13), "space-a"))
        variants.append(ctx(base, "space-b"))
        for v in variants { XCTAssertNotEqual(v, baseCtx) }
        XCTAssertEqual(Set(variants).count, variants.count)
        // Distinct contexts are distinct cache keys; the same one is a hit.
        let key = { (c: BlendPlanCache.ProfileContext) in BlendPlanCache.Key(from: 1, to: 2, outgoingTempo: 1, profile: c) }
        XCTAssertEqual(key(baseCtx), key(ctx(base, "space-a")))
        XCTAssertEqual(Set(variants.map(key) + [key(baseCtx)]).count, variants.count + 1)
        XCTAssertNotEqual(key(baseCtx), BlendPlanCache.Key(from: 1, to: 2, outgoingTempo: 1))
    }
}
#endif
