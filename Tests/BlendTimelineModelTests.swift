import XCTest
@testable import TonearmCore

final class BlendTimelineModelTests: XCTestCase {
    private func plan(exit: Double = 100, entry: Double = 8, overlap: Double = 20) -> TransitionPlan {
        TransitionPlan(fromTrackID: 1, toTrackID: 2, style: .phraseFade, exitTime: exit, entryTime: entry,
                       overlapSeconds: overlap, confidence: 0.8)
    }
    private func model(position: Double, tail: Bool = false, prep: GridPrepState = .ready) -> BlendTimelineModel? {
        BlendTimelineModel(.make(plan: plan(), preparation: prep, position: position, outgoingTail: tail), position: position)
    }

    func testOutgoingAndIncomingMarkers() throws {
        let m = try XCTUnwrap(model(position: 50))
        XCTAssertEqual(m.outgoing.map(\.time), [100, 110, 120])
        XCTAssertEqual(m.incoming.map(\.time), [8, 18, 28])
        XCTAssertEqual(m.outgoing.map(\.marker), [.start, .swap, .end])
        XCTAssertEqual(m.outgoingText, "Out  Start 1:40 · Swap 1:50 · End 2:00")
        XCTAssertEqual(m.incomingText, "In  Start 0:08 · Swap 0:18 · End 0:28")
    }

    func testUpcomingCountsDownLive() throws {
        let a = try XCTUnwrap(model(position: 76)), b = try XCTUnwrap(model(position: 80))
        XCTAssertEqual(a.stage, .upcoming)
        XCTAssertEqual(a.secondsUntilStart, 24)
        XCTAssertEqual(b.secondsUntilStart, 20)
        XCTAssertNotEqual(a.statusText, b.statusText)
        XCTAssertEqual(a.statusText, "Blend starts in 24 s")
        XCTAssertNil(a.currentMarker)
        XCTAssertEqual(a.progress, 0)
    }

    func testProgressThroughBlend() throws {
        let start = try XCTUnwrap(model(position: 100))
        XCTAssertEqual(start.stage, .beforeSwap); XCTAssertEqual(start.progress, 0); XCTAssertEqual(start.currentMarker, .start)
        let early = try XCTUnwrap(model(position: 105))
        XCTAssertEqual(early.progress, 0.25, accuracy: 1e-9)
        XCTAssertEqual(early.secondsRemaining, 15)
        XCTAssertTrue(early.statusText.hasPrefix("Blending: before swap"))
        let swap = try XCTUnwrap(model(position: 110))
        XCTAssertEqual(swap.stage, .afterSwap); XCTAssertEqual(swap.currentMarker, .swap)
        let late = try XCTUnwrap(model(position: 118))
        XCTAssertEqual(late.progress, 0.9, accuracy: 1e-9)
        XCTAssertTrue(late.statusText.hasPrefix("Blending: after swap"))
        XCTAssertTrue(late.statusText.contains("2 s left"))
    }

    func testFinishedAfterEndAndInTail() throws {
        let tail = try XCTUnwrap(model(position: 5, tail: true))
        XCTAssertEqual(tail.stage, .finished); XCTAssertEqual(tail.progress, 1); XCTAssertEqual(tail.currentMarker, .end)
        XCTAssertEqual(tail.statusText, "Blend complete")
    }

    func testPreparingStillShowsTimeline() throws {
        let m = try XCTUnwrap(model(position: 70, prep: .analyzing(0.2)))
        XCTAssertEqual(m.stage, .upcoming)
    }

    func testNilWhenNothingToDraw() {
        XCTAssertNil(BlendTimelineModel(.none, position: 0))
        XCTAssertNil(BlendTimelineModel(.make(plan: nil, preparation: nil), position: 0))
        let gapless = TransitionPlan(fromTrackID: 1, toTrackID: 2, style: .gapless, exitTime: 100)
        XCTAssertNil(BlendTimelineModel(.make(plan: gapless, preparation: .ready), position: 0))
        XCTAssertNil(BlendTimelineModel(TransitionPresentation(phase: .notPlanned), position: 0))
    }

    func testUnknownIncomingEntryIsHonest() throws {
        let p = TransitionPresentation(phase: .ready, plannedStyle: .bassSwap, actualStyle: .bassSwap,
                                       overlapRange: 100...120)
        let m = try XCTUnwrap(BlendTimelineModel(p, position: 90))
        XCTAssertTrue(m.incoming.isEmpty)
        XCTAssertEqual(m.incomingText, "In: timing unknown")
        XCTAssertEqual(m.styleLabel, "Bass swap")
    }

    func testSnapshotUpcomingNoLongerClaimsZeroSeconds() {
        let key = TransitionEdgeKey(from: QueueOccurrenceID(), to: QueueOccurrenceID())
        var ledger = TransitionExecutionLedger()
        ledger.record(key, generation: 0, .scheduled(requested: .bassSwap, planned: .bassSwap, executed: .bassSwap,
                                                      readiness: .ready, reason: nil, overlapStart: nil,
                                                      overlapEnd: nil, handoff: nil, sampleRate: 48_000))
        let base = TransitionPresentation(phase: .fallback, outgoingTrackID: 1, incomingTrackID: 2)
        let p = base.applying(ledger.snapshot(for: key))
        XCTAssertFalse(p.cardTitle.contains("in 0 s"))
        XCTAssertNil(p.secondsUntilOverlap)
    }

    func testSpokenSummary() throws {
        let m = try XCTUnwrap(model(position: 76))
        let s = m.spokenSummary(outgoingTitle: "A", incomingTitle: "B")
        XCTAssertTrue(s.contains("A into B"))
        XCTAssertTrue(s.contains("Blend starts in 24 s"))
    }
}
