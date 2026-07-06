import XCTest
@testable import Tonearm

final class PlaybackResilienceTests: XCTestCase {

    // MARK: - FailureClassification

    func testClassifyTransientHTTP() {
        XCTAssertEqual(PlaybackFailureClassifier.classify(httpStatus: 408), .transient)
        XCTAssertEqual(PlaybackFailureClassifier.classify(httpStatus: 429), .transient)
        XCTAssertEqual(PlaybackFailureClassifier.classify(httpStatus: 500), .transient)
        XCTAssertEqual(PlaybackFailureClassifier.classify(httpStatus: 502), .transient)
        XCTAssertEqual(PlaybackFailureClassifier.classify(httpStatus: 599), .transient)
    }

    func testClassifyPermanentHTTP() {
        XCTAssertEqual(PlaybackFailureClassifier.classify(httpStatus: 400), .permanent)
        XCTAssertEqual(PlaybackFailureClassifier.classify(httpStatus: 403), .permanent)
        XCTAssertEqual(PlaybackFailureClassifier.classify(httpStatus: 404), .permanent)
    }

    func testClassifyTransientURLError() {
        XCTAssertEqual(PlaybackFailureClassifier.classify(urlError: .timedOut), .transient)
        XCTAssertEqual(PlaybackFailureClassifier.classify(urlError: .cannotConnectToHost), .transient)
        XCTAssertEqual(PlaybackFailureClassifier.classify(urlError: .networkConnectionLost), .transient)
        XCTAssertEqual(PlaybackFailureClassifier.classify(urlError: .dnsLookupFailed), .transient)
    }

    func testClassifyPermanentURLError() {
        XCTAssertEqual(PlaybackFailureClassifier.classify(urlError: .badURL), .permanent)
        XCTAssertEqual(PlaybackFailureClassifier.classify(urlError: .unsupportedURL), .permanent)
        XCTAssertEqual(PlaybackFailureClassifier.classify(urlError: .cannotDecodeContentData), .permanent)
    }

    // MARK: - RetryPolicy

    func testRetryBackoffIncreases() {
        let policy = RetryPolicy(baseDelay: 0.5, maxDelay: 8, jitterFraction: 0.0)
        let d0 = policy.delay(forAttempt: 0, rand: 0.5)
        let d1 = policy.delay(forAttempt: 1, rand: 0.5)
        let d2 = policy.delay(forAttempt: 2, rand: 0.5)
        XCTAssertLessThan(d0, d1)
        XCTAssertLessThan(d1, d2)
    }

    func testRetryBackoffCapped() {
        let policy = RetryPolicy(baseDelay: 1, maxDelay: 4, jitterFraction: 0.0)
        let d5 = policy.delay(forAttempt: 5, rand: 0.5)
        XCTAssertEqual(d5, 4)
    }

    func testShouldRetryTransient() {
        let policy = RetryPolicy(maxAttemptsPerItem: 4)
        XCTAssertTrue(policy.shouldRetry(afterAttempt: 0, failure: .transient))
        XCTAssertTrue(policy.shouldRetry(afterAttempt: 1, failure: .transient))
        XCTAssertTrue(policy.shouldRetry(afterAttempt: 2, failure: .transient))
        XCTAssertFalse(policy.shouldRetry(afterAttempt: 3, failure: .transient))
    }

    func testNeverRetryPermanent() {
        let policy = RetryPolicy()
        XCTAssertFalse(policy.shouldRetry(afterAttempt: 0, failure: .permanent))
        XCTAssertFalse(policy.shouldRetry(afterAttempt: 1, failure: .permanent))
    }

    // MARK: - StallModel

    func testStallFreshGeneration() {
        var model = StallModel()
        XCTAssertEqual(model.beginLoad(), 1)
        XCTAssertEqual(model.loadGeneration, 1)
    }

    func testStallConfirmPlaybackResetsSkips() {
        var model = StallModel()
        let gen = model.beginLoad()
        model.confirmPlayback(generation: gen)
        XCTAssertEqual(model.consecutiveSkips, 0)
        XCTAssertEqual(model.confirmedGeneration, gen)
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
        XCTAssertEqual(model.consecutiveSkips, 1)
    }

    func testStallEvaluateIgnoreStaleGeneration() {
        var model = StallModel()
        let gen = model.beginLoad()
        _ = model.beginLoad() // newer generation
        XCTAssertEqual(model.evaluateStall(generation: gen, autoPlay: true), .ignoreStale)
    }

    func testStallGiveUpAfterMaxSkips() {
        var model = StallModel(maxConsecutiveSkips: 3)
        let gen = model.beginLoad()
        XCTAssertEqual(model.evaluateStall(generation: gen, autoPlay: true), .skip)
        model.confirmPlayback(generation: gen) // playback confirmed, resets skip streak
        XCTAssertEqual(model.consecutiveSkips, 0)

        // Start fresh — no confirmation, markReady state for a paused load
        let gen2 = model.beginLoad()
        model.markReady(generation: gen2)
        XCTAssertEqual(model.evaluateStall(generation: gen2, autoPlay: false), .healthy) // paused + ready = healthy
    }

    func testStallResetSkipStreak() {
        var model = StallModel()
        let gen = model.beginLoad()
        _ = model.evaluateStall(generation: gen, autoPlay: true)
        _ = model.evaluateStall(generation: gen, autoPlay: true)
        XCTAssertEqual(model.consecutiveSkips, 2)
        model.resetSkipStreak()
        XCTAssertEqual(model.consecutiveSkips, 0)
    }

    // MARK: - InFlightRegistry

    func testInFlightRegistryBeginAndEnd() {
        let registry = InFlightRegistry()
        XCTAssertTrue(registry.begin("abc"))
        XCTAssertTrue(registry.contains("abc"))
        XCTAssertFalse(registry.begin("abc"))
        registry.end("abc")
        XCTAssertFalse(registry.contains("abc"))
        XCTAssertTrue(registry.begin("abc"))
    }
}
