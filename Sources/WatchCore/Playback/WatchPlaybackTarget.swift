/// Which engine owns transport right now (§7.1). Always explicit, always visible on Now Playing —
/// never inferred, never switched automatically.
public enum WatchPlaybackTarget: String, Codable, Sendable, CaseIterable {
    /// The phone's `AudioPlayer`. The watch is a remote control and predicts elapsed from the
    /// last snapshot's `(elapsed, anchorDate, rate)`.
    case iPhone
    /// This watch's local `AVPlayer`, driving a queue of ready local assets.
    case thisWatch
}
