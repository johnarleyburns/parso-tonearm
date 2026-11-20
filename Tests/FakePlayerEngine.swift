#if !os(watchOS)
import AVFoundation
import Combine
@testable import TonearmCore

/// Lightweight stand-in for `PlayerEngine` with zero real AVFoundation
/// resources — no real decode pipeline, no CoreMedia/audio-session
/// connections. Lets tests construct `AudioPlayer.makeForTesting()` freely
/// and in parallel, for the tests that never inspect real `AVPlayer` state.
///
/// State is fully deterministic: nothing loads asynchronously. `isItemReady`
/// treats a local-file item as loaded (the same items the old tests waited for
/// AVFoundation to open) and a remote item as never-loading, so the crossfade
/// tests can exercise "ready" and "not ready yet" without real players.
@MainActor
final class FakePlayerEngine: PlayerEngine {
    var currentItem: AVPlayerItem?
    var rate: Float = 0
    var volume: Float = 1
    var timeControlStatus: AVPlayer.TimeControlStatus = .paused
    var automaticallyWaitsToMinimizeStalling = true

    /// Overrides the computed readiness for every item (tests that need a
    /// remote item to count as loaded).
    var itemReadinessOverride: ((AVPlayerItem?) -> Bool)?

    private var currentTimeValue: CMTime = .zero
    private var periodicObservers: [ObjectIdentifier: @Sendable (CMTime) -> Void] = [:]
    private var statusHandlers: [ObjectIdentifier: @MainActor @Sendable (AVPlayerItem.Status) -> Void] = [:]

    var status: AVPlayer.Status { isItemReady(currentItem) ? .readyToPlay : .unknown }
    var isReady: Bool { status == .readyToPlay && isItemReady(currentItem) }

    func isItemReady(_ item: AVPlayerItem?) -> Bool {
        if let itemReadinessOverride { return itemReadinessOverride(item) }
        guard let item else { return false }
        guard let urlAsset = item.asset as? AVURLAsset else { return false }
        return urlAsset.url.isFileURL
    }

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

    func seek(to time: CMTime) { currentTimeValue = time }

    @discardableResult
    func seek(to time: CMTime, toleranceBefore: CMTime, toleranceAfter: CMTime) async -> Bool {
        currentTimeValue = time
        return true
    }

    func currentTime() -> CMTime { currentTimeValue }

    func addPeriodicTimeObserver(
        forInterval interval: CMTime, queue: DispatchQueue?, using block: @escaping @Sendable (CMTime) -> Void
    ) -> Any {
        let token = NSObject()
        periodicObservers[ObjectIdentifier(token)] = block
        return token
    }

    func removeTimeObserver(_ observer: Any) {
        periodicObservers[ObjectIdentifier(observer as AnyObject)] = nil
    }

    func observeItemStatus(
        _ item: AVPlayerItem,
        onChange: @escaping @MainActor @Sendable (AVPlayerItem.Status) -> Void
    ) -> AnyCancellable {
        statusHandlers[ObjectIdentifier(item)] = onChange
        return AnyCancellable {}
    }

    /// Test hook: publish an item-status change the way AVFoundation KVO would.
    func sendItemStatus(_ status: AVPlayerItem.Status, for item: AVPlayerItem? = nil) {
        guard let item = item ?? currentItem,
              let handler = statusHandlers[ObjectIdentifier(item)] else { return }
        handler(status)
    }

    /// Test hook: fire every registered periodic time observer (the production
    /// player drives these from real playback).
    func tick(_ time: CMTime) {
        currentTimeValue = time
        for block in periodicObservers.values { block(time) }
    }
}

/// Matching fake for `NetworkPathMonitoring` — no test touches network-path
/// behavior today, so this just reports available and never fires updates.
final class FakeNetworkPathMonitor: NetworkPathMonitoring {
    var isAvailable = true
    var pathUpdateHandler: ((Bool) -> Void)?
    func start(queue: DispatchQueue) {}
    func cancel() {}
}

/// A `PlaybackStatePersistence` backed by an in-memory defaults store. Every
/// `AudioPlayer.makeForTesting()` gets its own instance, so playback-state
/// tests never share the App Group file or preferences domain.
@MainActor
final class InMemoryPlaybackStatePersistence: PlaybackStatePersistence {
    let defaults: InMemoryDefaultsStore
    /// Every snapshot written through this persistence, in order. Lets a test
    /// assert on regressed writes without a real `UserDefaults` spy.
    private(set) var savedSnapshots: [PlaybackStateSnapshot] = []

    init(defaults: InMemoryDefaultsStore = InMemoryDefaultsStore()) {
        self.defaults = defaults
    }

    func load() -> PlaybackStateSnapshot? { PlaybackStateStore.load(defaults: defaults) }

    func save(_ snapshot: PlaybackStateSnapshot) {
        savedSnapshots.append(snapshot)
        PlaybackStateStore.save(snapshot, defaults: defaults)
    }

    func clear() { PlaybackStateStore.clear(defaults: defaults) }

    func clearRecorded() { savedSnapshots.removeAll() }
}

extension AudioPlayer {
    /// Bundles both fakes for the test files that never inspect real
    /// `AVPlayer`/network behavior — zero real AVFoundation or
    /// Network-framework resources, safe to construct freely and in parallel.
    static func makeForTesting() -> AudioPlayer {
        let player = AudioPlayer(
            player: FakePlayerEngine(),
            pathMonitor: FakeNetworkPathMonitor(),
            makeCrossfadePlayer: { item in
                let engine = FakePlayerEngine()
                engine.replaceCurrentItem(with: item)
                return engine
            })
        player.persistor = PlaybackPositionPersistor(stateStore: InMemoryPlaybackStatePersistence())
        // Never build a real remote item in a test: `buildItem` would create a
        // `CachingResourceLoader`/URLSession that outlives the test and keeps the
        // process alive. Tests that specifically exercise item construction call
        // `buildItem(for:)` directly (LocalAssetResolverTests) or replace this hook.
        player.ordinaryBuildItemHook = { _ in
            (AVPlayerItem(asset: AVMutableComposition()), nil)
        }
        // No speculative remote prefetch in tests: it would create a real
        // CachingResourceLoader/URLSession for an unreachable URL. Tests that
        // specifically cover prefetch set this back to a positive value.
        player.prefetchDepth = 0
        player.prefetchLoaderEnabled = false
        return player
    }

    /// The fake behind `makeForTesting()`, for tests that drive readiness or
    /// item-status changes deterministically.
    var fakeEngine: FakePlayerEngine? { player as? FakePlayerEngine }
}
#endif
