import XCTest
@testable import TonearmCore

final class TransitionPresentationTests: XCTestCase {
    private func plan(_ style: TransitionStyle, exit: Double = 100, overlap: Double = 12,
                      from: Int64 = 1, to: Int64 = 2) -> TransitionPlan {
        TransitionPlan(fromTrackID: from, toTrackID: to, style: style, exitTime: exit,
                       overlapSeconds: overlap, confidence: 0.8)
    }

    func testPhraseReadyConnector() {
        let p = TransitionPresentation.make(plan: plan(.phraseFade), preparation: .ready, position: 76)
        XCTAssertEqual(p.phase, .ready)
        XCTAssertEqual(p.connectorLabel, "Phrase-matched · 12 s · Ready")
        XCTAssertEqual(p.secondsUntilOverlap, 24)
        XCTAssertEqual(p.diagramSegments, [.outgoing, .overlap, .incoming])
        XCTAssertTrue(p.accessibilityLabel().contains("phrase-matched blend in 24 seconds"))
    }

    func testBeatMatchedPreparing() {
        let p = TransitionPresentation.make(plan: plan(.beatmatchedBlend), preparation: .analyzing(0.3))
        XCTAssertEqual(p.phase, .preparing)
        XCTAssertTrue(p.connectorLabel.hasPrefix("Beat-matched"))
        XCTAssertTrue(p.connectorLabel.hasSuffix("Preparing"))
    }

    func testGaplessIsNotFallback() {
        let p = TransitionPresentation.make(plan: plan(.gapless, overlap: 0), preparation: .ready)
        XCTAssertFalse(p.isFallback)
        XCTAssertEqual(p.connectorLabel, "Gapless continuation · Ready")
        XCTAssertTrue(p.diagramSegments.isEmpty)
    }

    func testMissingPlanFallsBackTruthfully() {
        let p = TransitionPresentation.make(plan: nil, preparation: .failed("x"))
        XCTAssertTrue(p.isFallback)
        XCTAssertEqual(p.connectorLabel, "Continuous playback — smart blend unavailable")
        XCTAssertEqual(p.fallbackDetail, "No smart blend plan for this transition")
        XCTAssertNil(p.secondsUntilOverlap)
        XCTAssertFalse(p.fallbackDetail?.contains("/") ?? false)
    }

    func testEndOfQueueHasNoEdge() {
        XCTAssertEqual(TransitionPresentation.make(plan: nil, preparation: .ready, hasNext: false), .none)
        XCTAssertFalse(TransitionPresentation.none.showsConnector)
    }

    func testOverlapNamesBothTracksAndSkipsDecoration() {
        let p = TransitionPresentation.make(plan: plan(.beatmatchedBlend), preparation: .ready, position: 106)
        XCTAssertEqual(p.phase, .overlap)
        XCTAssertEqual(p.secondsRemaining, 6)
        let label = p.accessibilityLabel(outgoingTitle: "Midnight City", incomingTitle: "Wait")
        XCTAssertEqual(label, "Blending Midnight City into Wait; 6 seconds remaining")
        XCTAssertTrue(p.cardTitle.hasPrefix("Blending now"))
        let head = try! XCTUnwrap(p.playhead(position: 106))
        XCTAssertEqual(head, 0.5, accuracy: 0.001)
    }

    func testUnknownStyleAndMissingTimingDoNotCrash() {
        XCTAssertEqual(TransitionDisplayStyle(rawEngineStyle: "quantumMorph"), .smartBlend)
        XCTAssertEqual(TransitionDisplayStyle.smartBlend.label, "Smart blend")
        let p = TransitionPresentation.make(plan: plan(.phraseFade, exit: 0, overlap: 0), preparation: nil, position: 5)
        XCTAssertNil(p.overlapRange)
        XCTAssertTrue(p.diagramSegments.isEmpty)
        XCTAssertNil(p.playhead(position: 5))
        _ = p.accessibilityLabel(); _ = p.cardTitle; _ = p.accessibilityValue
    }

    func testOutgoingTailKeepsEdgeAndIDs() {
        let p = TransitionPresentation.make(plan: plan(.beatmatchedBlend, from: 1, to: 2),
                                            preparation: .ready, position: 3, outgoingTail: true)
        XCTAssertEqual(p.phase, .outgoingTail)
        XCTAssertEqual(p.outgoingTrackID, 1)
        XCTAssertEqual(p.incomingTrackID, 2)
        XCTAssertTrue(p.isBlendingNow)
    }

    @MainActor
    func testHandoffKeepsABUntilOutgoingFinishes() {
        let player = AudioPlayer.shared
        let ab = plan(.beatmatchedBlend, from: 1, to: 2)
        let bc = plan(.phraseFade, from: 2, to: 3)
        player.transitionPlan = ab
        player.isOutgoingTransitionTailAudible = true
        player.mixDecksPublish(plan: bc, state: .ready)
        XCTAssertEqual(player.transitionPlan, ab)
        player.mixDecksOutgoingDidFinish()
        XCTAssertEqual(player.transitionPlan, bc)
        XCTAssertFalse(player.isOutgoingTransitionTailAudible)
        player.transitionPlan = nil
    }

    private func snapshot(_ phase: TransitionExecutionPhase,
                          executed: TransitionDisplayStyle = .bassSwap,
                          reason: TransitionExecutionReason? = nil) -> TransitionExecutionSnapshot {
        let a = QueueOccurrenceID(), b = QueueOccurrenceID()
        let key = TransitionEdgeKey(from: a, to: b)
        var ledger = TransitionExecutionLedger()
        XCTAssertTrue(ledger.record(key, generation: 0,
            .scheduled(requested: .bassSwap, planned: .bassSwap, executed: executed,
                       readiness: .ready, reason: reason,
                       overlapStart: executed.overlaps ? 100 : nil,
                       overlapEnd: executed.overlaps ? 200 : nil,
                       handoff: executed.overlaps ? 200 : nil, sampleRate: 44_100)))
        if phase == .overlapping {
            XCTAssertTrue(ledger.record(key, generation: 0, .overlapBegan(atFrame: 100)))
        } else if phase == .handedOff {
            XCTAssertTrue(ledger.record(key, generation: 0, .handedOff(atFrame: 200)))
        } else if phase == .completed {
            XCTAssertTrue(ledger.record(key, generation: 0, .completed(atFrame: 200)))
        }
        return try! XCTUnwrap(ledger.snapshot(for: key))
    }

    func testScheduledRendererSnapshotPromotesNoLegacyPlanToReady() {
        let base = TransitionPresentation.make(plan: nil, preparation: .ready, hasNext: true)
        let result = base.applying(snapshot(.upcoming))
        XCTAssertEqual(result.phase, .ready)
        XCTAssertEqual(result.plannedStyle, .bassSwap)
        XCTAssertEqual(result.actualStyle, .bassSwap)
        XCTAssertFalse(result.isFallback)
        XCTAssertEqual(result.connectorLabel, "Bass swap · Ready")
        XCTAssertNil(result.overlapRange, "the snapshot must not fabricate plan timing")
    }

    func testOverlappingRendererSnapshotPromotesNoLegacyPlanToOverlap() {
        let base = TransitionPresentation.make(plan: nil, preparation: .ready, hasNext: true)
        let result = base.applying(snapshot(.overlapping, executed: .doubleDrop))
        XCTAssertEqual(result.phase, .overlap)
        XCTAssertEqual(result.actualStyle, .doubleDrop)
        XCTAssertTrue(result.isBlendingNow)
        XCTAssertFalse(result.isFallback)
    }

    func testHandedOffAndCompletedRendererSnapshotsLeaveNoLegacyFallback() {
        let base = TransitionPresentation.make(plan: nil, preparation: .ready, hasNext: true)
        XCTAssertEqual(base.applying(snapshot(.handedOff)).phase, .outgoingTail)
        XCTAssertEqual(base.applying(snapshot(.completed)).phase, .ready)
    }

    func testGaplessAndTerminalSnapshotsRemainTruthfulFallbacksWithoutLegacyPlan() {
        let base = TransitionPresentation.make(plan: nil, preparation: .ready, hasNext: true)
        let gapless = base.applying(snapshot(.upcoming, executed: .gapless, reason: .lateForPlannedBlend))
        XCTAssertEqual(gapless.phase, .fallback)
        XCTAssertEqual(gapless.actualStyle, .gapless)
        XCTAssertTrue(gapless.fallbackDetail?.hasPrefix("Sequential handoff") == true)

        let key = TransitionEdgeKey(from: QueueOccurrenceID(), to: QueueOccurrenceID())
        var ledger = TransitionExecutionLedger()
        XCTAssertTrue(ledger.record(key, generation: 0,
                                    .denied(.admissionDenied("unsafe"), readiness: .ready)))
        let denied = base.applying(try! XCTUnwrap(ledger.snapshot(for: key)))
        XCTAssertEqual(denied.phase, .fallback)
        XCTAssertNil(denied.actualStyle)

        let key2 = TransitionEdgeKey(from: QueueOccurrenceID(), to: QueueOccurrenceID())
        var ledger2 = TransitionExecutionLedger()
        XCTAssertTrue(ledger2.record(key2, generation: 0,
            .scheduled(requested: .bassSwap, planned: .bassSwap, executed: .bassSwap, readiness: .ready,
                       reason: nil, overlapStart: 100, overlapEnd: 200, handoff: 200, sampleRate: 44_100)))
        ledger2.cancelAll(reason: .queueChanged)
        let cancelled = base.applying(try! XCTUnwrap(ledger2.snapshot(for: key2)))
        XCTAssertEqual(cancelled.phase, .fallback)
        XCTAssertNil(cancelled.actualStyle)
    }
}
