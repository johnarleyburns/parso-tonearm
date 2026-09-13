#if !os(watchOS)
import Foundation
import AVFoundation
import ParsoAudioStreaming
import Combine
import Network

extension AudioPlayer {
    // MARK: - Observers

    func addPeriodicObserver() {
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            Task { @MainActor in
                let previous = self.currentTime
                self.currentTime = time.seconds
                if let d = self.player.currentItem?.duration.seconds, d.isFinite, d > 0 {
                    self.duration = d
                }
                self.updateCrossfade(position: time.seconds)
                if time.seconds > 0 && time.seconds != previous {
                    self.stallModel.confirmPlayback(generation: self.stallModel.loadGeneration)
                }
                self.refreshCacheState()
                self.updateNowPlayingTime()

                // F3: persist on tick (throttled to ≥1 write/s inside persistTick)
                // F5: seek confirmation for restore
                if let target = self.pendingRestoreSeek {
                    let pos = time.seconds
                    if self.player.currentItem?.status == .readyToPlay,
                       abs(pos - target) > 2 {
                        // Re-issue the seek
                        let cmTime = CMTime(seconds: target, preferredTimescale: 600)
                        await self.player.seek(to: cmTime,
                                         toleranceBefore: .zero,
                                         toleranceAfter: .zero)
                    } else if abs(pos - target) <= 2 {
                        self.pendingRestoreSeek = nil
                        self.persist(reason: .restoreCommit)
                    }
                    // While pending, report target for persistence purposes
                    self.currentTime = target
                }

                self.persistTick()
            }
        }
    }

    /// Observes the player's true playback state (Fix 1). `timeControlStatus` is
    /// the ground truth: manual `isPlaying` flips can't see buffering stalls on
    /// remote streams, which made self-advancing progress sprint ahead while
    /// audio was actually frozen. Re-subscribed after crossfade swaps
    /// the player instance.
    func observeTimeControlStatus() {
        timeControlCancellable = player.publisher(for: \.timeControlStatus)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.handleTimeControlChange(self.player.timeControlStatus)
                }
            }
    }

    func handleTimeControlChange(_ status: AVPlayer.TimeControlStatus) {
        guard !isAmbient else { return }
        let wasAdvancing = isAdvancing
        let wasPlaying = isPlaying
        switch status {
        case .playing:
            isPlaying = true
            isStalled = false
        case .waitingToPlayAtSpecifiedRate:
            isStalled = true
        case .paused:
            if crossfadePlayer == nil {
                isPlaying = false
            }
            isStalled = false
        @unknown default:
            break
        }
        if isAdvancing != wasAdvancing || isPlaying != wasPlaying {
            updateNowPlaying()
        }
    }

    func refreshCacheState() {
        guard let asset = currentTrack?.asset, asset.kind == .remote,
              let urlString = remoteURLString(for: asset), let remote = URL(string: urlString) else {
            if currentTrack?.asset?.kind == .remote {
                cacheState = .none
                cachePercent = 0
                cachedFraction = 0
            } else {
                cacheState = .cached
                cachePercent = 100
                cachedFraction = 1
            }
            return
        }
        let key = AudioCache.key(for: remote)
        Task {
            let state = CacheGlyphState.of(await AudioCache.shared.meta(for: key))
            let map = await AudioCache.shared.rangeMap(for: key)
            let total = await AudioCache.shared.totalBytes(for: key) ?? 0
            await MainActor.run {
                self.cacheState = state
                if state == .cached {
                    self.cachedFraction = 1
                    self.cachePercent = 100
                } else if total > 0 {
                    self.cachedFraction = min(1, Double(map.totalBytes()) / Double(total))
                    self.cachePercent = Int((self.cachedFraction * 100).rounded())
                }
            }
        }
    }
}
#endif
