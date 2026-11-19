#if !os(watchOS)
import AVFoundation

/// The exact subset of `AVPlayer`'s own API `AudioPlayer` calls on its primary
/// `player` property — nothing more. `AVPlayer` conforms directly (see the
/// extension below), so the real path is the same concrete `AVPlayer`
/// production has always used, not a wrapper. Letting tests substitute
/// `FakePlayerEngine` (`Tests/Support/FakePlayerEngine.swift`) means most
/// tests never construct a real `AVPlayer` at all: many real `AVPlayer`s
/// built/torn down concurrently by separate test instances was shown to make
/// real local playback flaky and leave the test process unable to exit.
@MainActor
protocol PlayerEngine: AnyObject {
    var currentItem: AVPlayerItem? { get }
    var rate: Float { get }
    var volume: Float { get set }
    var timeControlStatus: AVPlayer.TimeControlStatus { get }
    var automaticallyWaitsToMinimizeStalling: Bool { get set }

    func play()
    func pause()
    func replaceCurrentItem(with item: AVPlayerItem?)
    func seek(to time: CMTime)
    @discardableResult func seek(to time: CMTime, toleranceBefore: CMTime, toleranceAfter: CMTime) async -> Bool
    func currentTime() -> CMTime
    func addPeriodicTimeObserver(forInterval interval: CMTime, queue: DispatchQueue?, using block: @escaping @Sendable (CMTime) -> Void) -> Any
    func removeTimeObserver(_ observer: Any)
}

extension AVPlayer: PlayerEngine {}
#endif
