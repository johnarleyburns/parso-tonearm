import Foundation
import Testing
import TonearmWatchCore

@Suite struct WatchPlaybackRuntimeStateTests {
    @Test func testNewPlaybackClearsStalePlatformState() {
        var state = WatchPlaybackRuntimeState()
        state.begin(trackID: "old", generation: 4)
        state.playing(rate: 1)

        state.begin(trackID: "new", generation: 5)

        #expect(state.phase == .activating)
        #expect(state.generation == 5)
        #expect(state.trackID == "new")
        #expect(state.rate == 0)
        #expect(state.durationSeconds == 0)
        #expect(state.failure == nil)
    }

    @Test func testStateMovesThroughOnlyConfirmedPhases() {
        var state = WatchPlaybackRuntimeState()
        state.begin(trackID: "track", generation: 1)
        state.loading()
        #expect(state.phase == .loading)
        #expect(state.rate == 0)

        state.ready(durationSeconds: -2)
        #expect(state.phase == .ready)
        #expect(state.durationSeconds == 0)

        state.playing(rate: 1.25)
        #expect(state.phase == .playing)
        #expect(state.rate == 1.25)

        state.paused()
        #expect(state.phase == .paused)
        #expect(state.rate == 0)
    }

    @Test func testRouteFailureRetainsDiagnosticAndStopsRate() {
        var state = WatchPlaybackRuntimeState()
        state.begin(trackID: "track", generation: 9)
        state.playing(rate: 1)
        state.waitingForRoute(.init(code: "activationRejected", userMessage: "Select output"))

        #expect(state.phase == .waitingForRoute)
        #expect(state.rate == 0)
        #expect(state.failure?.code == "activationRejected")
    }

    @Test func testItemFailureStopsRateAndCanReturnToIdle() {
        var state = WatchPlaybackRuntimeState()
        state.begin(trackID: "track", generation: 2)
        state.failed(.init(code: "itemReadinessTimeout", userMessage: "Not ready"))

        #expect(state.phase == .failed)
        #expect(state.rate == 0)
        #expect(state.failure?.code == "itemReadinessTimeout")

        state.idle()
        #expect(state.phase == .idle)
        #expect(state.trackID == nil)
        #expect(state.failure == nil)
    }

    @Test func testActivationResultsExposeRouteAndCode() {
        let route = WatchRouteSnapshot(outputCount: 1, outputPortTypes: ["BluetoothA2DP"])
        let active = WatchAudioActivationResult.active(route: route)
        let unavailable = WatchAudioActivationResult.unavailable(code: "routeUnavailable", route: route)
        let failed = WatchAudioActivationResult.failed(code: "activation-failed", route: .init())

        #expect(active.isActive)
        #expect(active.code == nil)
        #expect(active.route == route)
        #expect(!unavailable.isActive)
        #expect(unavailable.code == "routeUnavailable")
        #expect(failed.code == "activation-failed")
    }

    @Test func testPlaybackResultsDistinguishReadyPlayingFailureAndCancellation() {
        #expect(WatchItemLoadResult.ready(durationSeconds: 12).isReady)
        #expect(!WatchItemLoadResult.failed(code: "bad-file").isReady)
        #expect(!WatchItemLoadResult.cancelled.isReady)
        #expect(WatchPlayResult.playing(rate: 0.5).isPlaying)
        #expect(!WatchPlayResult.playing(rate: 0).isPlaying)
        #expect(!WatchPlayResult.failed(code: "no-route").isPlaying)
        #expect(!WatchPlayResult.cancelled.isPlaying)
    }

    @Test func testRuntimeStateIsCodableForDiagnosticsOrPersistence() throws {
        var state = WatchPlaybackRuntimeState()
        state.begin(trackID: "track", generation: 11)
        state.ready(durationSeconds: 42)
        state.failed(.init(code: "item-failed", userMessage: "No"))

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(WatchPlaybackRuntimeState.self, from: data)
        #expect(decoded == state)
    }
}
