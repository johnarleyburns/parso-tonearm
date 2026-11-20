#if !os(watchOS)
import AVFoundation
import Combine

/// The exact subset of `AVPlayer`'s own API `AudioPlayer` calls on its primary
/// `player` property — nothing more. `AVPlayer` conforms directly (see the
/// extension below), so the real path is the same concrete `AVPlayer`
/// production has always used, not a wrapper. Letting tests substitute
/// `FakePlayerEngine` (`Tests/FakePlayerEngine.swift`) means most
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
    /// `AVPlayer.status` for the primary player; a fake reports ready only when
    /// its current item is ready, so the same readiness gate works for both.
    var status: AVPlayer.Status { get }

    func play()
    func pause()
    func replaceCurrentItem(with item: AVPlayerItem?)
    func seek(to time: CMTime)
    @discardableResult func seek(to time: CMTime, toleranceBefore: CMTime, toleranceAfter: CMTime) async -> Bool
    func currentTime() -> CMTime
    func addPeriodicTimeObserver(forInterval interval: CMTime, queue: DispatchQueue?, using block: @escaping @Sendable (CMTime) -> Void) -> Any
    func removeTimeObserver(_ observer: Any)

    /// Whether this player and the given item are both ready to play. Written as
    /// one predicate so tests can drive readiness deterministically instead of
    /// waiting on real AVFoundation item loading.
    func isItemReady(_ item: AVPlayerItem?) -> Bool
    /// The player-plus-item readiness gate used by crossfade promotion.
    var isReady: Bool { get }
    /// Item status changes, delivered on the main actor. Production observes the
    /// item's real `status` KVO; a fake lets tests publish a status directly.
    func observeItemStatus(
        _ item: AVPlayerItem,
        onChange: @escaping @MainActor @Sendable (AVPlayerItem.Status) -> Void
    ) -> AnyCancellable
}

extension AVPlayer: PlayerEngine {
    func isItemReady(_ item: AVPlayerItem?) -> Bool { item?.status == .readyToPlay }

    var isReady: Bool { status == .readyToPlay && isItemReady(currentItem) }

    func observeItemStatus(
        _ item: AVPlayerItem,
        onChange: @escaping @MainActor @Sendable (AVPlayerItem.Status) -> Void
    ) -> AnyCancellable {
        // KVO fires on an AVFoundation queue; `receive(on: .main)` moves delivery
        // to the main queue, so asserting main-actor isolation here is exact.
        item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { status in
                Task { @MainActor in onChange(status) }
            }
    }
}
#endif
