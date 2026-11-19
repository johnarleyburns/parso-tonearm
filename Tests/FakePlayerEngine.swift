#if !os(watchOS)
import AVFoundation
@testable import TonearmCore

/// Lightweight stand-in for `PlayerEngine` with zero real AVFoundation
/// resources — no real decode pipeline, no CoreMedia/audio-session
/// connections. Lets tests construct `AudioPlayer.makeForTesting()` freely
/// and in parallel, for the tests that never inspect real `AVPlayer` state.
@MainActor
final class FakePlayerEngine: PlayerEngine {
    var currentItem: AVPlayerItem?
    var rate: Float = 0
    var volume: Float = 1
    var timeControlStatus: AVPlayer.TimeControlStatus = .paused
    var automaticallyWaitsToMinimizeStalling = true

    func play() {
        rate = 1
        timeControlStatus = .playing
    }

    func pause() {
        rate = 0
        timeControlStatus = .paused
    }

    func replaceCurrentItem(with item: AVPlayerItem?) {
        currentItem = item
    }

    func seek(to time: CMTime) {}

    @discardableResult
    func seek(to time: CMTime, toleranceBefore: CMTime, toleranceAfter: CMTime) async -> Bool { true }

    func currentTime() -> CMTime { .zero }

    func addPeriodicTimeObserver(
        forInterval interval: CMTime, queue: DispatchQueue?, using block: @escaping @Sendable (CMTime) -> Void
    ) -> Any {
        // Never fires: nothing constructed with this fake depends on periodic-tick-driven
        // side effects (they set AudioPlayer's own state directly instead).
        NSObject()
    }

    func removeTimeObserver(_ observer: Any) {}
}

/// Matching fake for `NetworkPathMonitoring` — no test touches network-path
/// behavior today, so this just reports available and never fires updates.
final class FakeNetworkPathMonitor: NetworkPathMonitoring {
    var isAvailable = true
    var pathUpdateHandler: ((Bool) -> Void)?
    func start(queue: DispatchQueue) {}
    func cancel() {}
}

extension AudioPlayer {
    /// Bundles both fakes for the test files that never inspect real
    /// `AVPlayer`/network behavior — zero real AVFoundation or
    /// Network-framework resources, safe to construct freely and in parallel.
    static func makeForTesting() -> AudioPlayer {
        AudioPlayer(player: FakePlayerEngine(), pathMonitor: FakeNetworkPathMonitor())
    }
}
#endif
