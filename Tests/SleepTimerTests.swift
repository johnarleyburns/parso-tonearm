import XCTest
@testable import Tonearm

final class SleepTimerTests: XCTestCase {

    func testRetryPolicyBackoffExponential() {
        let policy = RetryPolicy(baseDelay: 0.5, maxDelay: 8, jitterFraction: 0.0)
        let d0 = policy.delay(forAttempt: 0, rand: 0.5)
        let d1 = policy.delay(forAttempt: 1, rand: 0.5)
        let d2 = policy.delay(forAttempt: 2, rand: 0.5)
        let d3 = policy.delay(forAttempt: 3, rand: 0.5)
        XCTAssertEqual(d0, 0.5)
        XCTAssertEqual(d1, 1.0)
        XCTAssertEqual(d2, 2.0)
        XCTAssertEqual(d3, 4.0)
    }

    func testRetryPolicyBackoffCapped() {
        let policy = RetryPolicy(baseDelay: 1, maxDelay: 4, jitterFraction: 0.0)
        let d5 = policy.delay(forAttempt: 5, rand: 0.5)
        XCTAssertEqual(d5, 4.0)
    }

    func testStallFreshGenerationIncrements() {
        var model = StallModel()
        _ = model.beginLoad()
        XCTAssertEqual(model.beginLoad(), 2)
    }

    func testStallConfirmPlaybackResetsSkips() {
        var model = StallModel()
        let gen = model.beginLoad()
        model.confirmPlayback(generation: gen)
        XCTAssertEqual(model.confirmedGeneration, gen)
        XCTAssertEqual(model.consecutiveSkips, 0)
    }

    func testStallEvaluateHealthyWhenConfirmed() {
        var model = StallModel()
        let gen = model.beginLoad()
        model.confirmPlayback(generation: gen)
        XCTAssertEqual(model.evaluateStall(generation: gen, autoPlay: true), .healthy)
    }

    func testStallEvaluateSkipWhenNotConfirmed() {
        var model = StallModel(maxConsecutiveSkips: 4)
        let gen = model.beginLoad()
        XCTAssertEqual(model.evaluateStall(generation: gen, autoPlay: true), .skip)
    }

    func testStallEvaluateIgnoreStale() {
        var model = StallModel()
        let oldGen = model.beginLoad()
        _ = model.beginLoad()
        XCTAssertEqual(model.evaluateStall(generation: oldGen, autoPlay: true), .ignoreStale)
    }

    func testStallHealthyWhenPausedAndReady() {
        var model = StallModel()
        let gen = model.beginLoad()
        model.markReady(generation: gen)
        XCTAssertEqual(model.evaluateStall(generation: gen, autoPlay: false), .healthy)
    }

    func testStallSkipWhenPlayingAndNotConfirmed() {
        var model = StallModel()
        let gen = model.beginLoad()
        model.markReady(generation: gen)
        XCTAssertEqual(model.evaluateStall(generation: gen, autoPlay: true), .skip)
    }

    func testInFlightRegistryDedup() {
        let registry = InFlightRegistry()
        XCTAssertTrue(registry.begin("abc"))
        XCTAssertFalse(registry.begin("abc"))
        registry.end("abc")
        XCTAssertTrue(registry.begin("abc"))
    }
}
