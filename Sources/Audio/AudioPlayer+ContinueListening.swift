#if !os(watchOS)
import Foundation

@MainActor
public extension AudioPlayer {
    /// The Listen tab's resume card, derived from the one live player. `nil`
    /// while playing or when the paused session is not worth resuming.
    var continueListeningPresentation: ContinueListeningPresentation? {
        ContinueListeningPresentation(
            currentTrack: currentTrack,
            queue: queue,
            index: index,
            elapsed: currentTime,
            duration: duration,
            isPlaying: isPlaying,
            isAmbient: isAmbient,
            queueSource: queueSource)
    }
}
#endif
