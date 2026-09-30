#if !os(watchOS)
import Foundation
import AVFoundation
import ParsoAudioStreaming
import Combine
import Network

extension AudioPlayer {
    // MARK: - Crossfade

    var normalizedCrossfadeSeconds: Double {
        guard crossfadeSeconds.isFinite else { return 0 }
        return max(0, crossfadeSeconds)
    }

    func updateCrossfade(position: Double) {
        let fadeSeconds = transitionPlan?.overlapSeconds ?? normalizedCrossfadeSeconds
        guard fadeSeconds > 0,
              !sleepAtEndOfTrack,
              transitionPlan?.style != .gapless,
              let nextIndex = upcomingQueueIndex(),
              queue.indices.contains(nextIndex),
              let current = currentTrack else {
            cancelCrossfade(resetVolume: true)
            return
        }

        let next = queue[nextIndex]
        guard !CrossfadeCurve.suppressesForGaplessAlbum(
            current: CrossfadeCurve.AlbumContinuity(row: current),
            next: CrossfadeCurve.AlbumContinuity(row: next)
        ) else {
            cancelCrossfade(resetVolume: true)
            return
        }

        let currentDuration = duration > 0 ? duration : (current.track.durationSec ?? 0)
        let gains = CrossfadeCurve.gains(position: position,
                                         duration: currentDuration,
                                         fadeSeconds: fadeSeconds,
                                         curve: crossfadeCurve)
        guard gains.active else {
            player.volume = 1
            return
        }

        guard prepareCrossfadePlayer(for: next, at: nextIndex) else { return }
        if let plan = transitionPlan,
           let currentItem = player.currentItem,
           let mix = AudioPlayer.transitionAudioMix(
               for: currentItem,
               fadeStart: CMTime(seconds: max(0, currentDuration - fadeSeconds), preferredTimescale: 600),
               fadeDuration: CMTime(seconds: fadeSeconds, preferredTimescale: 600),
               incoming: false,
               gainMatchDB: plan.gainMatchDB ?? 0) {
            currentItem.audioMix = mix
        }
        player.volume = Float(min(max(gains.outgoing, 0), 1))
        let gainMatch = transitionPlan?.gainMatchDB.map { pow(10, $0 / 20) } ?? 1
        crossfadePlayer?.volume = Float(min(max(gains.incoming * gainMatch, 0), 1.5))
        if let plan = transitionPlan, plan.style == .beatmatchedBlend {
            crossfadePlayer?.playImmediately(atRate: Float(plan.blendRate))
        } else {
            crossfadePlayer?.play()
        }

        if gains.incoming >= 1 || position >= currentDuration {
            finishCrossfade(to: nextIndex, row: next)
        }
    }

    @discardableResult
    func prepareCrossfadePlayer(for row: TrackRow, at nextIndex: Int) -> Bool {
        if crossfadePlayer != nil,
           crossfadeNextTrackId == row.track.id,
           crossfadeNextIndex == nextIndex {
            return true
        }

        cancelCrossfade(resetVolume: false)
        guard let asset = row.asset,
              asset.unsupportedReason == nil,
              playbackDecision(for: asset) != .skipWiFiOnly else {
            return false
        }

        let built: (item: AVPlayerItem, loader: CachingResourceLoader?)?
        if let preloadedNextItem, preloadedNextTrackId == row.track.id {
            built = (preloadedNextItem, preloadedNextLoader)
            self.preloadedNextItem = nil
            preloadedNextTrackId = nil
            preloadedNextLoader = nil
        } else {
            built = buildItem(for: asset)
        }

        guard let built else { return false }
        AudioPlayer.configureTransitionItem(built.item)
        applyEQ(to: built.item, row: row)

        let nextPlayer = AVPlayer(playerItem: built.item)
        nextPlayer.automaticallyWaitsToMinimizeStalling = false
        let entry = CMTime(seconds: transitionPlan?.entryTime ?? 0, preferredTimescale: 600)
        nextPlayer.seek(to: entry, toleranceBefore: .zero, toleranceAfter: .zero)
        if let plan = transitionPlan, plan.style == .beatmatchedBlend {
            nextPlayer.preroll(atRate: Float(plan.blendRate)) { _ in }
        } else {
            nextPlayer.preroll(atRate: 1) { _ in }
        }
        nextPlayer.volume = 0
        crossfadePlayer = nextPlayer
        crossfadeNextTrackId = row.track.id
        crossfadeNextIndex = nextIndex
        crossfadeNextLoader = built.loader
        if let plan = transitionPlan,
           let mix = AudioPlayer.transitionAudioMix(
               for: built.item,
               fadeStart: entry,
               fadeDuration: CMTime(seconds: plan.overlapSeconds, preferredTimescale: 600),
               incoming: true,
               gainMatchDB: plan.gainMatchDB ?? 0) {
            built.item.audioMix = mix
        }
        nextPlayer.play()
        return true
    }

    func finishCrossfade(to nextIndex: Int, row: TrackRow) {
        guard !crossfadeCompletionInFlight,
              let nextPlayer = crossfadePlayer,
              queue.indices.contains(nextIndex) else {
            return
        }
        crossfadeCompletionInFlight = true
        defer { crossfadeCompletionInFlight = false }

        let oldPlayer = player
        let oldLoaders = loaders
        loaders.removeAll()

        if let obs = itemEndObserver {
            NotificationCenter.default.removeObserver(obs)
            itemEndObserver = nil
        }
        if let observer = timeObserver {
            oldPlayer.removeTimeObserver(observer)
            timeObserver = nil
        }
        timeControlCancellable = nil

        oldPlayer.pause()
        oldPlayer.replaceCurrentItem(with: nil)
        oldLoaders.forEach { $0.shutdown() }

        player = nextPlayer
        player.volume = 1
        if let loader = crossfadeNextLoader {
            loaders.append(loader)
        }
        crossfadePlayer = nil
        crossfadeNextTrackId = nil
        crossfadeNextIndex = nil
        crossfadeNextLoader = nil

        index = nextIndex
        let seconds = player.currentTime().seconds
        currentTime = seconds.isFinite ? max(0, seconds) : 0
        if let rowDuration = row.track.durationSec {
            duration = rowDuration
        } else {
            let itemDuration = player.currentItem?.duration.seconds ?? 0
            duration = itemDuration.isFinite && itemDuration > 0 ? itemDuration : 0
        }
        if let item = player.currentItem {
            observeEnd(of: item)
        }
        scheduleTransitionPlan()
        addPeriodicObserver()
        observeTimeControlStatus()
        updateNowPlaying()
        prefetchNext()
        preloadNextItem()
        if let trackId = row.track.id {
            Task { try? await LibraryStore.shared.recordPlay(trackId: trackId) }
        }
    }

    func cancelCrossfade(resetVolume: Bool) {
        guard crossfadePlayer != nil || crossfadeNextLoader != nil || crossfadeNextIndex != nil else {
            if resetVolume { player.volume = 1 }
            return
        }
        crossfadePlayer?.pause()
        crossfadePlayer?.replaceCurrentItem(with: nil)
        crossfadePlayer = nil
        crossfadeNextTrackId = nil
        crossfadeNextIndex = nil
        crossfadeNextLoader?.shutdown()
        crossfadeNextLoader = nil
        crossfadeCompletionInFlight = false
        if resetVolume { player.volume = 1 }
    }

    func shutdownLoaders() {
        let oldLoaders = loaders
        loaders.removeAll()
        for loader in oldLoaders {
            loader.shutdown()
        }
    }
}
#endif
