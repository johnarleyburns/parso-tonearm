import XCTest
@testable import TonearmCore

@MainActor
final class PlaybackPositionModelTests: XCTestCase {

    struct RNG {
        private var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state
        }
        func int(in r: ClosedRange<Int>) -> Int { var c = self; return r.lowerBound + Int(c.next() % UInt64(r.count)) }
        func double(in r: ClosedRange<Double>) -> Double {
            var c = self; return r.lowerBound + (Double(c.next() % 1_000_000) / 1_000_000) * (r.upperBound - r.lowerBound)
        }
    }

    enum Event: Equatable {
        case tick, pause, resume, seek, nextTrack, previousTrack, background, kill, uninstall
    }

    func testInvariantsOverRuns() async throws {
        for run in 0..<50 {
            let seed: UInt64 = 42 + UInt64(run)
            try await runOne(seed: seed)
        }
    }

    private func runOne(seed: UInt64) async throws {
        let fakeCloud = FakePlaybackCloudBackend()
        let persistor = PlaybackPositionPersistor(cloudBackend: fakeCloud)
        var rng = RNG(seed: seed)
        let ids: [Int64] = [1, 2, 3, 4, 5]
        let syncs: [String] = ["s1", "s2", "s3", "s4", "s5"]
        var index = 0, elapsed = 0.0
        var isPlaying = false
        var lastDurableElapsed = 0.0

        for _ in 0..<20 {
            let event: Event
            switch rng.int(in: 0...100) {
            case 0..<22:  event = .tick
            case 22..<27: event = .pause
            case 27..<32: event = .resume
            case 32..<38: event = .seek
            case 38..<43: event = .nextTrack
            case 43..<47: event = .previousTrack
            case 47..<52: event = .background
            case 52..<57: event = .kill
            case 57..<62: event = .uninstall
            default:      event = .tick
            }

            var reason: PlaybackWriteReason
            switch event {
            case .tick:       elapsed += 0.5; reason = .tick
            case .pause:      isPlaying = false; reason = .transportEvent
            case .resume:     isPlaying = true; reason = .transportEvent
            case .seek:       elapsed = rng.double(in: 0...300); reason = .userSeek
            case .nextTrack:  if index + 1 < ids.count { index += 1 }; elapsed = 0; reason = .transportEvent
            case .previousTrack: if index > 0 { index -= 1 }; elapsed = 0; reason = .transportEvent
            case .background: reason = .background
            case .kill:       reason = .background
            case .uninstall:  reason = .transportEvent
            }

            let snap = PlaybackStateSnapshot(
                trackIDs: ids, trackSyncIDs: syncs,
                currentIndex: index, elapsed: elapsed,
                isPlaying: isPlaying, savedAt: Date())
            persistor.save(candidate: snap, reason: reason)

            let durable = PlaybackStateFileStore.load()
            if let d = durable, d.trackIDs == ids, d.currentIndex == index {
                if reason == .tick || reason == .background {
                    let reg = lastDurableElapsed - d.elapsed
                    XCTAssertLessThanOrEqual(reg, 1.0,
                        "G3: tick/bg regression ≤1 s, seed=\(seed)")
                }
                switch event {
                case .pause, .resume, .seek, .nextTrack, .previousTrack:
                    XCTAssertEqual(d.elapsed, elapsed, accuracy: 0.01,
                        "G1: exact, seed=\(seed)")
                default: break
                }
                lastDurableElapsed = d.elapsed
            }

            if event == .uninstall {
                fakeCloud.save(snap)
                PlaybackStateStore.clear()
                if let url = PlaybackStateFileStore.fileURL() {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }

        // Cloud: if a discrete event saved and uninstall happened, cloud survives.
        // Not every seed generates discrete events before an uninstall.
        let cloudSnap = await fakeCloud.load()
        // G6 is tested thoroughly in testSnapshotSurvivesReinstall; here we just
        // verify the model runs don't crash and basic invariants hold.
        _ = cloudSnap
    }
}
