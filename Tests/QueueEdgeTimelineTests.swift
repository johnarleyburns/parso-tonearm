import XCTest
@testable import TonearmCore

final class QueueEdgeTimelineTests: XCTestCase {
    private func pres(_ phase: TransitionRuntimePhase = .ready, style: TransitionDisplayStyle? = .phraseBlend,
                      range: ClosedRange<Double>? = 125...137, prep: GridPrepState? = .ready) -> TransitionPresentation {
        TransitionPresentation(phase: phase, plannedStyle: style, actualStyle: style,
                               outgoingTrackID: 1, incomingTrackID: 2, overlapRange: range, preparation: prep)
    }

    func testPhraseEdgeShowsBoundariesAndReady() {
        let t = QueueEdgeTimeline(pres())
        XCTAssertEqual(t.kind, .phrase)
        XCTAssertEqual(t.availability, .ready)
        XCTAssertEqual(t.outgoingBoundary, "Out 2:05")
        XCTAssertEqual(t.incomingBoundary, "In 2:17")
        XCTAssertEqual(t.summary, "Phrase · Out 2:05 → In 2:17 · Ready")
        XCTAssertEqual(t.accessibilityLabel,
                       "Transition, Phrase, outgoing track out 2:05, incoming track in 2:17, Ready")
    }

    func testBeatEdgeWhilePreparing() {
        let t = QueueEdgeTimeline(pres(.preparing, style: .beatMatched, prep: .downloading(0.4)))
        XCTAssertEqual(t.kind, .beat)
        XCTAssertEqual(t.availability, .preparing)
        XCTAssertTrue(t.summary.hasSuffix("Preparing"))
    }

    func testFallbackMakesNoBlendPromise() {
        let t = QueueEdgeTimeline(TransitionPresentation(phase: .fallback))
        XCTAssertEqual(t.kind, .fallback)
        XCTAssertEqual(t.availability, .unavailable)
        XCTAssertNil(t.outgoingBoundary)
        XCTAssertNil(t.incomingBoundary)
        XCTAssertEqual(t.summary, "Fallback · Blend unavailable")
    }

    func testUnknownTimingOmitsBoundariesAndSaysSo() {
        let t = QueueEdgeTimeline(pres(range: nil))
        XCTAssertNil(t.outgoingBoundary)
        XCTAssertTrue(t.accessibilityLabel.contains("timing unavailable"))
    }

    func testGaplessAndFailedHaveNoBoundaries() {
        XCTAssertNil(QueueEdgeTimeline(pres(style: .gapless)).outgoingBoundary)
        let failed = QueueEdgeTimeline(pres(prep: .failed("x")))
        XCTAssertEqual(failed.availability, .failed)
        XCTAssertNil(failed.incomingBoundary)
    }

    func testWaitingStatesAndNotPlanned() {
        XCTAssertEqual(QueueEdgeTimeline(pres(.preparing, prep: .waitingForWiFi)).availabilityLabel, "Waiting for Wi-Fi")
        XCTAssertEqual(QueueEdgeTimeline(pres(prep: nil)).availability, .unknown)
        let n = QueueEdgeTimeline(TransitionPresentation(phase: .notPlanned))
        XCTAssertEqual(n.kind, .unplanned)
        XCTAssertEqual(n.summary, "Not planned yet")
        XCTAssertNil(n.outgoingBoundary)
    }
}
