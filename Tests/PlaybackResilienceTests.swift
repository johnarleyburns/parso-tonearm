import Testing
@testable import TonearmCore

@Suite struct PlaybackResilienceTests {

    // MARK: - FailureClassification

    @Test func testClassifyTransientHTTP() {
        #expect(PlaybackFailureClassifier.classify(httpStatus: 408) == .transient)
        #expect(PlaybackFailureClassifier.classify(httpStatus: 429) == .transient)
        #expect(PlaybackFailureClassifier.classify(httpStatus: 500) == .transient)
        #expect(PlaybackFailureClassifier.classify(httpStatus: 502) == .transient)
        #expect(PlaybackFailureClassifier.classify(httpStatus: 599) == .transient)
    }

    @Test func testClassifyPermanentHTTP() {
        #expect(PlaybackFailureClassifier.classify(httpStatus: 400) == .permanent)
        #expect(PlaybackFailureClassifier.classify(httpStatus: 403) == .permanent)
        #expect(PlaybackFailureClassifier.classify(httpStatus: 404) == .permanent)
    }

    @Test func testClassifyTransientURLError() {
        #expect(PlaybackFailureClassifier.classify(urlError: .timedOut) == .transient)
        #expect(PlaybackFailureClassifier.classify(urlError: .cannotConnectToHost) == .transient)
        #expect(PlaybackFailureClassifier.classify(urlError: .networkConnectionLost) == .transient)
        #expect(PlaybackFailureClassifier.classify(urlError: .dnsLookupFailed) == .transient)
    }

    @Test func testClassifyPermanentURLError() {
        #expect(PlaybackFailureClassifier.classify(urlError: .badURL) == .permanent)
        #expect(PlaybackFailureClassifier.classify(urlError: .unsupportedURL) == .permanent)
        #expect(PlaybackFailureClassifier.classify(urlError: .cannotDecodeContentData) == .permanent)
    }

    // MARK: - RetryPolicy

    @Test func testRetryBackoffIncreases() {
        let policy = RetryPolicy(baseDelay: 0.5, maxDelay: 8, jitterFraction: 0.0)
        let d0 = policy.delay(forAttempt: 0, rand: 0.5)
        let d1 = policy.delay(forAttempt: 1, rand: 0.5)
        let d2 = policy.delay(forAttempt: 2, rand: 0.5)
        #expect(d0 < d1)
        #expect(d1 < d2)
    }

    @Test func testRetryBackoffCapped() {
        let policy = RetryPolicy(baseDelay: 1, maxDelay: 4, jitterFraction: 0.0)
        let d5 = policy.delay(forAttempt: 5, rand: 0.5)
        #expect(d5 == 4)
    }

    @Test func testShouldRetryTransient() {
        let policy = RetryPolicy(maxAttemptsPerItem: 4)
        #expect(policy.shouldRetry(afterAttempt: 0, failure: .transient))
        #expect(policy.shouldRetry(afterAttempt: 1, failure: .transient))
        #expect(policy.shouldRetry(afterAttempt: 2, failure: .transient))
        #expect(!policy.shouldRetry(afterAttempt: 3, failure: .transient))
    }

    @Test func testNeverRetryPermanent() {
        let policy = RetryPolicy()
        #expect(!policy.shouldRetry(afterAttempt: 0, failure: .permanent))
        #expect(!policy.shouldRetry(afterAttempt: 1, failure: .permanent))
    }

    // MARK: - StallModel

    @Test func testStallFreshGeneration() {
        var model = StallModel()
        #expect(model.beginLoad() == 1)
        #expect(model.loadGeneration == 1)
    }

    @Test func testStallConfirmPlaybackResetsSkips() {
        var model = StallModel()
        let gen = model.beginLoad()
        model.confirmPlayback(generation: gen)
        #expect(model.consecutiveSkips == 0)
        #expect(model.confirmedGeneration == gen)
    }

    @Test func testStallEvaluateHealthyWhenConfirmed() {
        var model = StallModel()
        let gen = model.beginLoad()
        model.confirmPlayback(generation: gen)
        #expect(model.evaluateStall(generation: gen, autoPlay: true) == .healthy)
    }

    @Test func testStallEvaluateSkipWhenNotConfirmed() {
        var model = StallModel(maxConsecutiveSkips: 4)
        let gen = model.beginLoad()
        #expect(model.evaluateStall(generation: gen, autoPlay: true) == .skip)
        #expect(model.consecutiveSkips == 1)
    }

    @Test func testStallEvaluateIgnoreStaleGeneration() {
        var model = StallModel()
        let gen = model.beginLoad()
        _ = model.beginLoad() // newer generation
        #expect(model.evaluateStall(generation: gen, autoPlay: true) == .ignoreStale)
    }

    @Test func testStallGiveUpAfterMaxSkips() {
        var model = StallModel(maxConsecutiveSkips: 3)
        let gen = model.beginLoad()
        #expect(model.evaluateStall(generation: gen, autoPlay: true) == .skip)
        model.confirmPlayback(generation: gen) // playback confirmed, resets skip streak
        #expect(model.consecutiveSkips == 0)

        // Start fresh — no confirmation, markReady state for a paused load
        let gen2 = model.beginLoad()
        model.markReady(generation: gen2)
        #expect(model.evaluateStall(generation: gen2, autoPlay: false) == .healthy) // paused + ready = healthy
    }

    @Test func testStallResetSkipStreak() {
        var model = StallModel()
        let gen = model.beginLoad()
        _ = model.evaluateStall(generation: gen, autoPlay: true)
        _ = model.evaluateStall(generation: gen, autoPlay: true)
        #expect(model.consecutiveSkips == 2)
        model.resetSkipStreak()
        #expect(model.consecutiveSkips == 0)
    }

    // MARK: - InFlightRegistry

    @Test func testInFlightRegistryBeginAndEnd() {
        let registry = InFlightRegistry()
        #expect(registry.begin("abc"))
        #expect(registry.contains("abc"))
        #expect(!registry.begin("abc"))
        registry.end("abc")
        #expect(!registry.contains("abc"))
        #expect(registry.begin("abc"))
    }
}
