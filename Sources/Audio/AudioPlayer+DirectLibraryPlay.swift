import Foundation

extension AudioPlayer {
    /// Stable toast tag so rapid consecutive direct plays replace rather than stack the message.
    public static let queueReplacedToastTag = "playback.queue-replaced"

    /// Direct tap on a song row in My Music / Find: replaces the queue with the visible result set
    /// and, if a non-empty queue existed beforehand, calls `notify` once with the toast text.
    /// The notice confirms the queue operation, not playback start, so it fires right after the
    /// replacement is committed. Other `play(tracks:)` callers intentionally do not notify.
    public func playLibraryResult(_ tracks: [TrackRow], startAt idx: Int,
                                  notify: (String) -> Void) {
        let hadQueue = !queue.isEmpty
        play(tracks: tracks, startAt: idx, source: .library)
        guard hadQueue, tracks.indices.contains(idx) else { return }
        notify("Queue updated with \(tracks[idx].track.title)")
    }
}
