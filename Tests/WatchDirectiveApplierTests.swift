import XCTest
import TonearmWatchCore

/// Phase 9b — spy on `applyWatchDirectives` to prove engine directives reach the output **in order**
/// and each awaits the previous (a `.loadItem` must finish before its `.play`).
@MainActor
final class WatchDirectiveApplierTests: XCTestCase {

    final class Spy: WatchAudioOutput {
        private(set) var calls: [String] = []
        var loadResult: WatchItemLoadResult = .ready(durationSeconds: 1)
        var playResult: WatchPlayResult = .playing(rate: 1)
        var onItemEnded: (() -> Void)?
        var onItemFailed: ((String) -> Void)?
        var onTimeUpdate: ((Double) -> Void)?

        func activateSession() async -> WatchAudioActivationResult {
            calls.append("activate")
            return .active(route: WatchRouteSnapshot(outputCount: 1, outputPortTypes: ["test"]))
        }
        func load(url: URL) async -> WatchItemLoadResult {
            calls.append("load:\(url.lastPathComponent)")
            await Task.yield()
            calls.append("loaded:\(url.lastPathComponent)")
            return loadResult
        }
        func play() async -> WatchPlayResult { calls.append("play"); return playResult }
        func pause() async { calls.append("pause") }
        func seek(to time: Double) async { calls.append("seek:\(time)") }
        func setVolume(_ volume: Double) { calls.append("volume:\(volume)") }
        func rebuildSession() async -> WatchSessionRebuildResult {
            calls.append("rebuild")
            return .ready(durationSeconds: 1)
        }
        func currentRate() -> Double { 0 }
        func currentRoute() -> WatchRouteSnapshot { WatchRouteSnapshot() }
        func currentItemReadiness() -> WatchItemReadiness { .noItem }
    }

    func testLoadFullyCompletesBeforePlay() async {
        let spy = Spy()
        var engine = WatchPlayerEngine(queue: ["t1"])
        let directives = engine.command(.play, urlForTrack: { URL(fileURLWithPath: "/tmp/\($0).mp3") })

        await applyWatchDirectives(directives, to: spy)

        XCTAssertEqual(spy.calls, ["load:t1.mp3", "loaded:t1.mp3", "play"])
    }

    func testJumpEmitsLoadThenPlayInOrder() async {
        let spy = Spy()
        var engine = WatchPlayerEngine(queue: ["a", "b", "c"])
        let directives = engine.command(.jump(to: 2), urlForTrack: { URL(fileURLWithPath: "/tmp/\($0).mp3") })

        await applyWatchDirectives(directives, to: spy)

        XCTAssertEqual(spy.calls, ["load:c.mp3", "loaded:c.mp3", "play"])
    }

    func testStopMapsToPause() async {
        let spy = Spy()
        var engine = WatchPlayerEngine(queue: ["only"])
        _ = engine.command(.play, urlForTrack: { URL(fileURLWithPath: "/tmp/\($0).mp3") })
        let directives = engine.command(.itemEnded, urlForTrack: { URL(fileURLWithPath: "/tmp/\($0).mp3") })

        XCTAssertEqual(directives, [.stop])
        await applyWatchDirectives(directives, to: spy)
        XCTAssertEqual(spy.calls, ["pause"])
    }

    func testLoadFailureStopsBeforePlay() async {
        let spy = Spy()
        spy.loadResult = .failed(code: "item-bad-file")
        let result = await applyWatchDirectives([.loadItem(URL(fileURLWithPath: "/tmp/a.mp3")), .play], to: spy)

        XCTAssertEqual(result, .failed(code: "item-bad-file"))
        XCTAssertEqual(spy.calls, ["load:a.mp3", "loaded:a.mp3"])
    }

    func testPlayFailureIsReturnedToCaller() async {
        let spy = Spy()
        spy.playResult = .failed(code: "playbackRateZero")
        let result = await applyWatchDirectives([.loadItem(URL(fileURLWithPath: "/tmp/a.mp3")), .play], to: spy)

        XCTAssertEqual(result, .failed(code: "playbackRateZero"))
        XCTAssertEqual(spy.calls, ["load:a.mp3", "loaded:a.mp3", "play"])
    }

    func testCancellationStopsDirectiveBatch() async {
        let spy = Spy()
        spy.loadResult = .cancelled
        let result = await applyWatchDirectives([.loadItem(URL(fileURLWithPath: "/tmp/a.mp3")), .play], to: spy)

        XCTAssertEqual(result, .cancelled)
        XCTAssertEqual(spy.calls, ["load:a.mp3", "loaded:a.mp3"])
    }
}
