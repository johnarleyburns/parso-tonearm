import XCTest
import AVFoundation
@testable import TonearmCore

/// Exercises the real AVPlayerItem state machine on the host. AVAudioSession itself is an iOS/watchOS
/// service and is therefore exercised by WatchSmokeUITests plus the on-device audio pass.
@MainActor
final class WatchAVPlayerItemTests: XCTestCase {
    func testRealAVPlayerItemReachesReadyToPlayForRemuxedWatchAudio() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("watch-av-item-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let opus = root.appendingPathComponent("fixture.opus")
        try Fixtures.data("tone_mono", ext: "opus").write(to: opus)
        let caf = try await OpusRemuxer().remux(opusFileURL: opus, cacheKey: "watch-av-item")
        let item = AVPlayerItem(url: caf)
        let player = AVPlayer(playerItem: item)
        player.play()

        let status = await waitForStatus(of: item)

        XCTAssertEqual(status, .readyToPlay)
        let duration = item.duration
        XCTAssertTrue(duration.seconds.isFinite)
        XCTAssertGreaterThan(duration.seconds, 0)
    }

    func testRealAVPlayerItemReportsFailureForMalformedWatchAudio() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("watch-av-item-bad-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let malformed = root.appendingPathComponent("fixture.opus")
        try Fixtures.data("corrupt_notogg", ext: "opus").write(to: malformed)
        let item = AVPlayerItem(url: malformed)
        let player = AVPlayer(playerItem: item)
        player.play()

        let status = await waitForStatus(of: item)

        XCTAssertEqual(status, .failed)
        XCTAssertNotNil(item.error)
    }

    private func waitForStatus(of item: AVPlayerItem) async -> AVPlayerItem.Status {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if item.status != .unknown { return item.status }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return item.status
    }
}
