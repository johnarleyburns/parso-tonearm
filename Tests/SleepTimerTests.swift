import Testing
@testable import TonearmCore

@Suite struct SleepTimerTests {

    @Test func testRetryPolicyBackoffExponential() {
        let policy = RetryPolicy(baseDelay: 0.5, maxDelay: 8, jitterFraction: 0.0)
        let d0 = policy.delay(forAttempt: 0, rand: 0.5)
        let d1 = policy.delay(forAttempt: 1, rand: 0.5)
        let d2 = policy.delay(forAttempt: 2, rand: 0.5)
        let d3 = policy.delay(forAttempt: 3, rand: 0.5)
        #expect(d0 == 0.5)
        #expect(d1 == 1.0)
        #expect(d2 == 2.0)
        #expect(d3 == 4.0)
    }

    @Test func testRetryPolicyBackoffCapped() {
        let policy = RetryPolicy(baseDelay: 1, maxDelay: 4, jitterFraction: 0.0)
        let d5 = policy.delay(forAttempt: 5, rand: 0.5)
        #expect(d5 == 4.0)
    }

    @Test func testStallFreshGenerationIncrements() {
        var model = StallModel()
        _ = model.beginLoad()
        #expect(model.beginLoad() == 2)
    }

    @Test func testStallConfirmPlaybackResetsSkips() {
        var model = StallModel()
        let gen = model.beginLoad()
        model.confirmPlayback(generation: gen)
        #expect(model.confirmedGeneration == gen)
        #expect(model.consecutiveSkips == 0)
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
    }

    @Test func testStallEvaluateIgnoreStale() {
        var model = StallModel()
        let oldGen = model.beginLoad()
        _ = model.beginLoad()
        #expect(model.evaluateStall(generation: oldGen, autoPlay: true) == .ignoreStale)
    }

    @Test func testStallHealthyWhenPausedAndReady() {
        var model = StallModel()
        let gen = model.beginLoad()
        model.markReady(generation: gen)
        #expect(model.evaluateStall(generation: gen, autoPlay: false) == .healthy)
    }

    @Test func testStallSkipWhenPlayingAndNotConfirmed() {
        var model = StallModel()
        let gen = model.beginLoad()
        model.markReady(generation: gen)
        #expect(model.evaluateStall(generation: gen, autoPlay: true) == .skip)
    }

    @Test func testInFlightRegistryDedup() {
        let registry = InFlightRegistry()
        #expect(registry.begin("abc"))
        #expect(!registry.begin("abc"))
        registry.end("abc")
        #expect(registry.begin("abc"))
    }
}
