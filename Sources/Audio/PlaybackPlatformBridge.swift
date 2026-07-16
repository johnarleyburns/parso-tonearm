import Foundation

/// Keeps `AudioPlayer` host-compilable. All iOS-only platform I/O — AVAudioSession
/// configuration/observation, `MPNowPlayingInfoCenter`, `MPRemoteCommandCenter`,
/// artwork decoding (UIImage), and Live Activity / widget publishing — lives
/// behind this seam. The app injects `SystemPlaybackBridge`; `swift test` gets the
/// no-op default so the playback *logic* is exercised on the macOS host.
@MainActor
public protocol PlaybackPlatformBridge: AnyObject {
    /// The output hardware sample rate (`AVAudioSession`), used by DSP sizing.
    var sampleRate: Double { get }

    /// Activates the playback audio session.
    func configureSession()

    /// Wires the lock-screen / control-center remote commands to the player.
    func setupRemoteCommands(
        resume: @escaping () -> Void,
        pause: @escaping () -> Void,
        next: @escaping () -> Void,
        previous: @escaping () -> Void,
        seek: @escaping (Double) -> Void)

    /// Starts route-change / interruption observation. The bridge owns the
    /// AVAudioSession-specific reasoning and calls back when the player should act.
    func startObservers(
        routeShouldPause: @escaping () -> Void,
        interruptionPause: @escaping () -> Void,
        interruptionResume: @escaping () -> Void)

    /// Full now-playing refresh: title/artist/duration, async artwork, and the
    /// Live Activity / widget snapshot publish.
    func refreshNowPlaying(_ player: AudioPlayer)

    /// Elapsed-time / playback-rate refresh of the system now-playing info only.
    func refreshNowPlayingTime(_ player: AudioPlayer)

    /// Re-publishes the Live Activity / widget snapshot without rebuilding
    /// now-playing info (used after a seek).
    func publishSnapshot(_ player: AudioPlayer)

    /// Clears system now-playing info and publishes the empty snapshot.
    func clearNowPlaying()

    /// Warms the on-disk artwork cache for a prefetched track (offline availability).
    func prefetchArtwork(for row: TrackRow)
}

/// The host-test / headless default: every platform call is a no-op, so
/// `AudioPlayer`'s queue, shuffle, repeat, and up-next logic run without any
/// iOS-only dependency.
@MainActor
public final class NoopPlaybackBridge: PlaybackPlatformBridge {
    public init() {}
    public var sampleRate: Double { 44_100 }
    public func configureSession() {}
    public func setupRemoteCommands(
        resume: @escaping () -> Void,
        pause: @escaping () -> Void,
        next: @escaping () -> Void,
        previous: @escaping () -> Void,
        seek: @escaping (Double) -> Void) {}
    public func startObservers(
        routeShouldPause: @escaping () -> Void,
        interruptionPause: @escaping () -> Void,
        interruptionResume: @escaping () -> Void) {}
    public func refreshNowPlaying(_ player: AudioPlayer) {}
    public func refreshNowPlayingTime(_ player: AudioPlayer) {}
    public func publishSnapshot(_ player: AudioPlayer) {}
    public func clearNowPlaying() {}
    public func prefetchArtwork(for row: TrackRow) {}
}
