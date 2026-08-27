import XCTest
import TonearmWatchCore

/// Phase 9b — spy on `applyWatchDirectives` to prove engine directives reach the output **in order**
/// and each awaits the previous (a `.loadItem` must finish before its `.play`).
@MainActor
final class WatchDirectiveApplierTests: XCTestCase {

    final class Spy: WatchAudioOutput {
        private(set) var calls: [String] = []
        var onItemEnded: (() -> Void)?
        var onItemFailed: (() -> Void)?
        var onTimeUpdate: ((Double) -> Void)?

        func load(url: URL) async {
            calls.append("load:\(url.lastPathComponent)")
            await Task.yield()
            calls.append("loaded:\(url.lastPathComponent)")
        }
        func play() async { calls.append("play") }
        func pause() async { calls.append("pause") }
        func seek(to time: Double) async { calls.append("seek:\(time)") }
        func setVolume(_ volume: Double) { calls.append("volume:\(volume)") }
        func rebuildSession() async { calls.append("rebuild") }
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
}
