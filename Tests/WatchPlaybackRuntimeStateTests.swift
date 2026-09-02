import XCTest
import TonearmWatchCore

final class WatchPlaybackRuntimeStateTests: XCTestCase {
    func testNewPlaybackClearsStalePlatformState() {
        var state = WatchPlaybackRuntimeState()
        state.begin(trackID: "old", generation: 4)
        state.playing(rate: 1)

        state.begin(trackID: "new", generation: 5)

        XCTAssertEqual(state.phase, .activating)
        XCTAssertEqual(state.generation, 5)
        XCTAssertEqual(state.trackID, "new")
        XCTAssertEqual(state.rate, 0)
        XCTAssertEqual(state.durationSeconds, 0)
        XCTAssertNil(state.failure)
    }

    func testStateMovesThroughOnlyConfirmedPhases() {
        var state = WatchPlaybackRuntimeState()
        state.begin(trackID: "track", generation: 1)
        state.loading()
        XCTAssertEqual(state.phase, .loading)
        XCTAssertEqual(state.rate, 0)

        state.ready(durationSeconds: -2)
        XCTAssertEqual(state.phase, .ready)
        XCTAssertEqual(state.durationSeconds, 0)

        state.playing(rate: 1.25)
        XCTAssertEqual(state.phase, .playing)
        XCTAssertEqual(state.rate, 1.25)

        state.paused()
        XCTAssertEqual(state.phase, .paused)
        XCTAssertEqual(state.rate, 0)
    }

    func testRouteFailureRetainsDiagnosticAndStopsRate() {
        var state = WatchPlaybackRuntimeState()
        state.begin(trackID: "track", generation: 9)
        state.playing(rate: 1)
        state.waitingForRoute(.init(code: "activationRejected", userMessage: "Select output"))

        XCTAssertEqual(state.phase, .waitingForRoute)
        XCTAssertEqual(state.rate, 0)
        XCTAssertEqual(state.failure?.code, "activationRejected")
    }

    func testItemFailureStopsRateAndCanReturnToIdle() {
        var state = WatchPlaybackRuntimeState()
        state.begin(trackID: "track", generation: 2)
        state.failed(.init(code: "itemReadinessTimeout", userMessage: "Not ready"))

        XCTAssertEqual(state.phase, .failed)
        XCTAssertEqual(state.rate, 0)
        XCTAssertEqual(state.failure?.code, "itemReadinessTimeout")

        state.idle()
        XCTAssertEqual(state.phase, .idle)
        XCTAssertNil(state.trackID)
        XCTAssertNil(state.failure)
    }

    func testActivationResultsExposeRouteAndCode() {
        let route = WatchRouteSnapshot(outputCount: 1, outputPortTypes: ["BluetoothA2DP"])
        let active = WatchAudioActivationResult.active(route: route)
        let unavailable = WatchAudioActivationResult.unavailable(code: "routeUnavailable", route: route)
        let failed = WatchAudioActivationResult.failed(code: "activation-failed", route: .init())

        XCTAssertTrue(active.isActive)
        XCTAssertNil(active.code)
        XCTAssertEqual(active.route, route)
        XCTAssertFalse(unavailable.isActive)
        XCTAssertEqual(unavailable.code, "routeUnavailable")
        XCTAssertEqual(failed.code, "activation-failed")
    }

    func testPlaybackResultsDistinguishReadyPlayingFailureAndCancellation() {
        XCTAssertTrue(WatchItemLoadResult.ready(durationSeconds: 12).isReady)
        XCTAssertFalse(WatchItemLoadResult.failed(code: "bad-file").isReady)
        XCTAssertFalse(WatchItemLoadResult.cancelled.isReady)
        XCTAssertTrue(WatchPlayResult.playing(rate: 0.5).isPlaying)
        XCTAssertFalse(WatchPlayResult.playing(rate: 0).isPlaying)
        XCTAssertFalse(WatchPlayResult.failed(code: "no-route").isPlaying)
        XCTAssertFalse(WatchPlayResult.cancelled.isPlaying)
    }

    func testRuntimeStateIsCodableForDiagnosticsOrPersistence() throws {
        var state = WatchPlaybackRuntimeState()
        state.begin(trackID: "track", generation: 11)
        state.ready(durationSeconds: 42)
        state.failed(.init(code: "item-failed", userMessage: "No"))

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(WatchPlaybackRuntimeState.self, from: data)
        XCTAssertEqual(decoded, state)
    }
}
