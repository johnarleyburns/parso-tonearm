import XCTest
@testable import TonearmDiscovery

/// The transition-prep crash (allocation abort decoding whole hi-res FLACs concurrently):
/// a decode must fit in memory before it starts, and decodes never overlap.
final class TransitionDecodeBudgetTests: XCTestCase {
    func testPeakEstimateFollowsDurationRateAndChannels() {
        // 10 min, 96 kHz, stereo: 600 × 96 000 × 2 × 4 B = 460.8 MB of PCM; ×2.5 peak.
        XCTAssertEqual(TransitionDecodeBudget.estimatedPeakBytes(durationSec: 600, sampleRate: 96_000, fileBytes: nil),
                       1_152_000_000)
        // Unknown rate assumes 44.1 kHz.
        XCTAssertEqual(TransitionDecodeBudget.estimatedPeakBytes(durationSec: 1, sampleRate: nil, fileBytes: nil),
                       882_000)
        // No duration falls back to the file size bound; nothing known → no estimate.
        XCTAssertEqual(TransitionDecodeBudget.estimatedPeakBytes(durationSec: nil, sampleRate: nil, fileBytes: 10),
                       200)
        XCTAssertNil(TransitionDecodeBudget.estimatedPeakBytes(durationSec: nil, sampleRate: nil, fileBytes: nil))
    }

    func testDecodeMayUseAtMostHalfOfAvailableMemory() {
        XCTAssertTrue(TransitionDecodeBudget.fits(estimatedPeakBytes: 500, availableBytes: 1_000))
        XCTAssertFalse(TransitionDecodeBudget.fits(estimatedPeakBytes: 501, availableBytes: 1_000))
        XCTAssertTrue(TransitionDecodeBudget.fits(estimatedPeakBytes: nil, availableBytes: 1_000))
        XCTAssertTrue(TransitionDecodeBudget.fits(estimatedPeakBytes: 10, availableBytes: nil))
    }

    func testGateNeverRunsTwoDecodesAtOnce() async throws {
        let gate = TransitionDecodeGate()
        let counter = ConcurrencyCounter()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    _ = try await gate.run {
                        counter.enter()
                        Thread.sleep(forTimeInterval: 0.02)
                        counter.leave()
                        return 0
                    }
                }
            }
            try await group.waitForAll()
        }
        XCTAssertEqual(counter.peak, 1)
    }

    func testCancelledDecodeWaitingItsTurnNeverStarts() async throws {
        let gate = TransitionDecodeGate()
        let started = ConcurrencyCounter()
        let first = Task { try await gate.run { Thread.sleep(forTimeInterval: 0.2); return 1 } }
        try await Task.sleep(for: .milliseconds(20))
        let second = Task { try await gate.run { started.enter(); return 2 } }
        second.cancel()
        _ = try await first.value
        let result = await second.result
        XCTAssertThrowsError(try result.get())
        XCTAssertEqual(started.peak, 0)
    }
}

private final class ConcurrencyCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0
    private(set) var peak = 0
    func enter() { lock.withLock { current += 1; peak = max(peak, current) } }
    func leave() { lock.withLock { current -= 1 } }
}
