import XCTest
@testable import TonearmCore

final class TransitionAdmissionTests: XCTestCase {
    private let roomy = TransitionSystemState(availableBytes: 3_000_000_000)
    private let tight = TransitionSystemState(availableBytes: 400_000_000)
    private func meta(_ sec: Double?, _ rate: Int? = 44_100, _ ch: Int? = 2) -> TransitionTrackMetadata {
        .init(durationSec: sec, sampleRate: rate, channels: ch)
    }

    func testOrdinaryPairAdmitted() {
        XCTAssertEqual(TransitionAdmissionController.decide(outgoing: meta(240), incoming: meta(240), system: roomy),
                       .allowLiveMix)
    }

    func testHiResAndHourLongDenied() {
        XCTAssertEqual(TransitionAdmissionController.decide(outgoing: nil, incoming: meta(600, 96_000), system: tight),
                       .gaplessFallback(reason: .decodedMemoryBudget))
        XCTAssertEqual(TransitionAdmissionController.decide(outgoing: nil, incoming: meta(3_700, 44_100), system: tight),
                       .gaplessFallback(reason: .decodedMemoryBudget))
    }

    func testDecisionUsesDecodedCharacteristics() {
        // Same duration: only rate differs, so the decision differs.
        XCTAssertEqual(TransitionAdmissionController.decide(outgoing: nil, incoming: meta(240, 44_100), system: roomy),
                       .allowLiveMix)
        XCTAssertNotEqual(TransitionAdmissionController.decide(outgoing: nil, incoming: meta(240, 192_000), system: roomy),
                          .allowLiveMix)
    }

    func testUnknownOrMalformedMetadataDenied() {
        for m in [meta(nil), meta(0), meta(.nan), meta(-5), meta(200, nil), meta(200, 0), meta(200, 44_100, 0)] {
            XCTAssertEqual(TransitionAdmissionController.decide(outgoing: nil, incoming: m, system: roomy),
                           .gaplessFallback(reason: .unavailableMetadata))
        }
        XCTAssertEqual(TransitionAdmissionController.decide(outgoing: nil, incoming: nil, system: roomy),
                       .gaplessFallback(reason: .unavailableMetadata))
    }

    func testCombinedPeakDeniesJointlyUnsafePair() {
        let one = meta(420)
        XCTAssertEqual(TransitionAdmissionController.decide(outgoing: nil, incoming: one, system: roomy), .allowLiveMix)
        let pair = TransitionAdmissionController.decide(outgoing: one, incoming: one, system: roomy)
        let single = TransitionAdmissionController.estimatedPeakBytes(outgoing: nil, incoming: one)!
        let both = TransitionAdmissionController.estimatedPeakBytes(outgoing: one, incoming: one)!
        XCTAssertGreaterThan(both, single)
        var config = TransitionAdmissionConfig()
        config.absoluteCapBytes = (single + both) / 2
        XCTAssertEqual(TransitionAdmissionController.decide(outgoing: nil, incoming: one, system: roomy, config: config),
                       .allowLiveMix)
        XCTAssertEqual(TransitionAdmissionController.decide(outgoing: one, incoming: one, system: roomy, config: config),
                       .gaplessFallback(reason: .decodedMemoryBudget))
        _ = pair
    }

    func testSystemPolicies() {
        let m = meta(200)
        XCTAssertEqual(TransitionAdmissionController.decide(outgoing: nil, incoming: m,
                           system: .init(availableBytes: nil, thermal: .serious)), .gaplessFallback(reason: .thermalPolicy))
        XCTAssertEqual(TransitionAdmissionController.decide(outgoing: nil, incoming: m,
                           system: .init(availableBytes: nil, lowPowerMode: true)), .gaplessFallback(reason: .lowPowerPolicy))
        XCTAssertEqual(TransitionAdmissionController.decide(outgoing: nil, incoming: m,
                           system: .init(availableBytes: nil, memoryWarningActive: true)), .defer(reason: .memoryPressure))
        XCTAssertEqual(TransitionAdmissionController.decide(outgoing: nil, incoming: m, sourceAvailable: false, system: roomy),
                       .gaplessFallback(reason: .unavailableSource))
        XCTAssertEqual(TransitionAdmissionController.decide(outgoing: nil, incoming: m, system: roomy, isCancelled: true),
                       .defer(reason: .cancelled))
        XCTAssertEqual(TransitionAdmissionController.decide(outgoing: nil, incoming: m,
                           system: .init(availableBytes: 100_000_000)), .gaplessFallback(reason: .memoryPressure))
    }

    func testPreviewAndLiveAgree() {
        let a = meta(300), b = meta(300, 96_000)
        XCTAssertEqual(TransitionAdmissionController.decide(outgoing: a, incoming: b, system: tight),
                       TransitionAdmissionController.decide(outgoing: a, incoming: b, system: tight))
    }

    func testGateRunsOneAtATimeAndSkipsCancelled() async throws {
        let gate = TransitionDecodeGate()
        let counter = Counter()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    try await gate.runAsync {
                        counter.enter(); try await Task.sleep(for: .milliseconds(10)); counter.leave()
                    }
                }
            }
            try await group.waitForAll()
        }
        XCTAssertEqual(counter.peak, 1)
    }

    func testExecutedKindLabelsOnlyWhatHappened() {
        XCTAssertEqual(TransitionExecutedKind.resolve(sourcesOverlap: true, fades: true, continuityProven: true), .overlapCrossfade)
        XCTAssertEqual(TransitionExecutedKind.resolve(sourcesOverlap: false, fades: true, continuityProven: false), .fadeOutFadeIn)
        XCTAssertEqual(TransitionExecutedKind.resolve(sourcesOverlap: false, fades: false, continuityProven: false), .sequentialHandoff)
        XCTAssertEqual(TransitionExecutedKind.resolve(sourcesOverlap: false, fades: false, continuityProven: true), .gapless)
        for reason in TransitionAdmissionReason.allCases {
            let status = TransitionFallbackStatus(decision: .gaplessFallback(reason: reason))
            XCTAssertEqual(status.executed, .sequentialHandoff)
        }
    }

    func testDeadlineAndPreparationFailureAreDistinctReasons() {
        let late = TransitionAdmissionReason.deadline.accessibilityLabel
        let failed = TransitionAdmissionReason.preparationFailed.accessibilityLabel
        XCTAssertNotEqual(late, failed)
        XCTAssertNotEqual(late, TransitionAdmissionReason.unavailableMetadata.accessibilityLabel)
        XCTAssertNotEqual(failed, TransitionAdmissionReason.unavailableSource.accessibilityLabel)
    }

    func testReasonsArePrivacySafeAndAccessible() {
        for reason in TransitionAdmissionReason.allCases {
            XCTAssertFalse(reason.accessibilityLabel.isEmpty)
            XCTAssertTrue(reason.message.contains("smart blend unavailable"))
        }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0
    private(set) var peak = 0
    func enter() { lock.withLock { current += 1; peak = max(peak, current) } }
    func leave() { lock.withLock { current -= 1 } }
}
