#if !os(watchOS)
import Foundation
import AVFoundation
import ParsoAudioStreaming
import Combine
import Network

extension AudioPlayer {
    // MARK: - Shuffle & Repeat

    func applyShuffle() {
        guard queue.count > 1 else { return }
        unshuffledQueue = queue
        let current = queue[index]
        var rest = queue
        rest.remove(at: index)
        rest.shuffle()
        queue = [current] + rest
        index = 0
        invalidatePreloadedNext()
    }

    func restoreShuffle() {
        guard !unshuffledQueue.isEmpty else { return }
        if let current = currentTrack,
           let origIdx = unshuffledQueue.firstIndex(where: { $0.id == current.id }) {
            queue = unshuffledQueue
            index = origIdx
        }
        unshuffledQueue = []
        invalidatePreloadedNext()
    }

    /// Drops any preloaded next item whose position no longer follows the current
    /// track (e.g. after shuffle reorders the queue), then repreloads.
    func invalidatePreloadedNext() {
        cancelCrossfade(resetVolume: true)
        preloadedNextLoader?.shutdown()
        preloadedNextItem = nil
        preloadedNextTrackId = nil
        preloadedNextLoader = nil
        preloadNextItem()
    }

    public func cycleRepeatMode() {
        repeatMode = switch repeatMode {
        case .off: .all
        case .all: .one
        case .one: .off
        }
    }

    public func toggleShuffle() {
        shuffle.toggle()
    }
}
#endif
