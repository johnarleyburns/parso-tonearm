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

    /// The plain crossfade between queue tracks on AVPlayer (the user's Crossfade setting).
    /// Smart transitions never come here: they play on the mix decks (AudioPlayer+MixDecks.swift),
    /// the one planner and mixer for every blend.
    func updateCrossfade(position: Double) {
        let fadeSeconds = normalizedCrossfadeSeconds
        guard fadeSeconds > 0,
              mixDecks == nil,
              !sleepAtEndOfTrack,
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
        let fadeStart = max(0, currentDuration - fadeSeconds)
        // Create the incoming item well before the fade so a stream has time to load.
        guard position >= fadeStart - Self.crossfadePrepareLeadSeconds else {
            player.volume = outputLevel
            return
        }
        guard prepareCrossfadePlayer(for: next, at: nextIndex),
              let incomingPlayer = crossfadePlayer else { return }
        startTransitionTicker()

        // `position` comes from a time observer hop and can be stale; read the clock now.
        let outgoingNow = freshOutgoingTime(fallback: position)
        let gains = CrossfadeCurve.gains(position: outgoingNow, fadeStart: fadeStart,
                                         fadeSeconds: fadeSeconds, curve: crossfadeCurve)
        guard gains.active else {
            player.volume = outputLevel
            incomingPlayer.volume = 0
            return
        }
        if !transitionStartedForCurrentEdge {
            // Starting an item that hasn't loaded raises; the outgoing keeps full level until it has.
            guard incomingPlayer.status == .readyToPlay,
                  incomingPlayer.currentItem?.status == .readyToPlay else {
                player.volume = outputLevel
                incomingPlayer.volume = 0
                if outgoingNow >= currentDuration { cancelCrossfade(resetVolume: true) }
                return
            }
            incomingPlayer.play()
            transitionStartedForCurrentEdge = true
            // Started after the fade began: fade in from here instead of jumping to the curve.
            transitionLateStartPosition = outgoingNow > fadeStart + 0.25 ? outgoingNow : nil
        }
        let lateFade = transitionLateStartPosition.map {
            min(max((outgoingNow - $0) / Self.crossfadeLateStartFadeSeconds, 0), 1)
        } ?? 1
        player.volume = Float(min(max(gains.outgoing, 0), 1)) * outputLevel
        incomingPlayer.volume = Float(min(max(gains.incoming * lateFade, 0), 1)) * outputLevel

        if outgoingNow >= fadeStart + fadeSeconds || outgoingNow >= currentDuration {
            finishCrossfade(to: nextIndex, row: next)
        }
    }

    static let crossfadePrepareLeadSeconds: Double = 20
    static let crossfadeLateStartFadeSeconds: Double = 2

    /// The outgoing player's item time right now while it is playing; otherwise the observed
    /// position (a paused player's clock doesn't move).
    private func freshOutgoingTime(fallback: Double) -> Double {
        guard player.rate > 0 else { return fallback }
        let seconds = player.currentTime().seconds
        return seconds.isFinite ? seconds : fallback
    }

    private func startTransitionTicker() {
        guard transitionTicker == nil else { return }
        transitionTicker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard !Task.isCancelled, let self else { return }
                guard self.crossfadePlayer != nil else { self.transitionTicker = nil; return }
                guard self.isPlaying else { continue }
                self.updateCrossfade(position: self.player.currentTime().seconds)
            }
        }
    }

    @discardableResult
    func prepareCrossfadePlayer(for row: TrackRow, at nextIndex: Int) -> Bool {
        if crossfadePlayer != nil, crossfadeNextTrackId == row.track.id, crossfadeNextIndex == nextIndex {
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
        applyEQ(to: built.item, row: row)

        let nextPlayer = AVPlayer(playerItem: built.item)
        nextPlayer.volume = 0
        crossfadePlayer = nextPlayer
        crossfadeNextTrackId = row.track.id
        crossfadeNextIndex = nextIndex
        crossfadeNextLoader = built.loader
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
        transitionTicker?.cancel()
        transitionTicker = nil
        transitionLateStartPosition = nil

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
        player.volume = outputLevel
        if let loader = crossfadeNextLoader {
            loaders.append(loader)
        }
        crossfadePlayer = nil
        crossfadeNextTrackId = nil
        crossfadeNextIndex = nil
        crossfadeNextLoader = nil
        transitionStartedForCurrentEdge = false

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
            if resetVolume { player.volume = outputLevel }
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
        transitionStartedForCurrentEdge = false
        transitionTicker?.cancel()
        transitionTicker = nil
        transitionLateStartPosition = nil
        if resetVolume { player.volume = outputLevel }
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
