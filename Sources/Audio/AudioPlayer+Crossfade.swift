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
        let plannedFadeStart = transitionPlan.map(\.exitTime).flatMap { $0 > 0 ? $0 : nil }
            ?? max(0, currentDuration - fadeSeconds)
        let gains = CrossfadeCurve.gains(position: position,
                                         fadeStart: plannedFadeStart,
                                         fadeSeconds: fadeSeconds,
                                         curve: crossfadeCurve)
        guard gains.active else {
            player.volume = 1
            return
        }

        guard prepareCrossfadePlayer(for: next, at: nextIndex) else { return }
        player.volume = Float(min(max(gains.outgoing, 0), 1))
        let gainMatch = transitionPlan?.gainMatchDB.map { pow(10, $0 / 20) } ?? 1
        crossfadePlayer?.volume = Float(min(max(gains.incoming * gainMatch, 0), 1.5))
        if !transitionStartedForCurrentEdge {
            startScheduledTransition(fadeStart: plannedFadeStart,
                                     entryTime: transitionPlan?.entryTime ?? 0)
        } else if let plan = transitionPlan,
                  plan.style == .beatmatchedBlend,
                  let incoming = crossfadePlayer {
            let expected = plan.entryTime + max(0, position - plan.exitTime) * plan.blendRate
            let actual = incoming.currentTime().seconds
            if actual.isFinite, expected.isFinite {
                let drift = actual - expected
                let correction = AudioPlayer.transitionDriftCorrection(driftSeconds: drift)
                if correction != 0 {
                    incoming.seek(to: CMTime(seconds: max(plan.entryTime, actual + correction),
                                             preferredTimescale: 600),
                                  toleranceBefore: .zero, toleranceAfter: .zero)
                    logTransitionDrift(drift, trackID: plan.toTrackID)
                }
            }
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
        nextPlayer.preroll(atRate: transitionPlan?.style == .beatmatchedBlend
                           ? Float(transitionPlan?.blendRate ?? 1) : 1) { _ in }
        nextPlayer.volume = 0
        crossfadePlayer = nextPlayer
        crossfadeNextTrackId = row.track.id
        crossfadeNextIndex = nextIndex
        crossfadeNextLoader = built.loader
        nextPlayer.rate = 0
        return true
    }

    /// Schedules the incoming item against the outgoing player's host clock.
    /// The audio-mix ramp is intentionally not used here: AVPlayer.volume is
    /// the sole gain ramp, avoiding the previous double-fade dip.
    private func startScheduledTransition(fadeStart: Double, entryTime: Double) {
        guard let incoming = crossfadePlayer else { return }
        let plan = transitionPlan
        transitionStartedForCurrentEdge = true
        let targetRate = Float(plan?.style == .beatmatchedBlend ? (plan?.blendRate ?? 1) : 1)
        if let timebase = player.currentItem?.timebase {
            let now = CMClockGetTime(CMClockGetHostTimeClock())
            let host = AudioPlayer.transitionHostTime(
                exitSeconds: fadeStart,
                currentItemTime: player.currentTime(),
                timebase: timebase,
                hostTime: now)
            incoming.setRate(targetRate,
                             time: CMTime(seconds: entryTime, preferredTimescale: 600),
                             atHostTime: host)
        } else if targetRate == 1 {
            incoming.play()
        } else {
            incoming.playImmediately(atRate: targetRate)
        }

        transitionTask?.cancel()
        guard let plan, plan.style == .beatmatchedBlend,
              let beats = plan.rateRampBeats, beats > 0,
              let overlapBeats = plan.overlapBeats,
              plan.overlapSeconds > 0
        else { return }
        let rampBPM = max(1, Double(overlapBeats) / plan.overlapSeconds * 60)
        let ramp = AudioPlayer.transitionRateRamp(start: plan.blendRate, end: 1,
                                                   beats: beats, bpm: rampBPM)
        transitionTask = Task { [weak self] in
            var previousOffset = 0.0
            for point in ramp.dropFirst() {
                guard !Task.isCancelled else { return }
                let delta = max(0, point.offset - previousOffset)
                try? await Task.sleep(nanoseconds: UInt64(delta * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.crossfadePlayer?.rate = Float(point.rate)
                previousOffset = point.offset
            }
        }
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
        transitionStartedForCurrentEdge = false
        transitionTask?.cancel()
        transitionTask = nil
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
