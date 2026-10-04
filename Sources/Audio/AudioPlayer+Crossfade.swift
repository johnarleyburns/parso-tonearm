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
        let fadeSeconds: Double = {
            guard let plan = transitionPlan else { return normalizedCrossfadeSeconds }
            if plan.overlapSeconds > 0 { return plan.overlapSeconds }
            // A planned transition always blends unless it is deliberately gapless; plans saved
            // before plain crossfades had a length would otherwise cut hard.
            return plan.style == .gapless ? 0 : max(normalizedCrossfadeSeconds, TransitionPlanner.plainCrossfadeSeconds)
        }()
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
        let gains: CrossfadeCurve.Gains
        if transitionPlan?.style == .beatmatchedBlend,
           transitionPlan?.overlapBeats == 96 {
            gains = CrossfadeCurve.threePhraseGains(position: position,
                                                    fadeStart: plannedFadeStart,
                                                    fadeSeconds: fadeSeconds)
        } else {
            gains = CrossfadeCurve.gains(position: position,
                                         fadeStart: plannedFadeStart,
                                         fadeSeconds: fadeSeconds,
                                         curve: crossfadeCurve)
        }
        guard gains.active else {
            player.volume = outputLevel
            return
        }

        guard prepareCrossfadePlayer(for: next, at: nextIndex),
              let incomingPlayer = crossfadePlayer else { return }
        let startingNow = !transitionStartedForCurrentEdge
        if startingNow {
            guard TransitionPlayerControl.isReady(incomingPlayer),
                  startScheduledTransition(fadeStart: plannedFadeStart,
                                           entryTime: transitionPlan?.entryTime ?? 0) else {
                // The incoming track hasn't loaded yet (usual for a stream). Starting it now is
                // what crashed TestFlight 520/521; instead the outgoing track keeps playing at full
                // level, the fade begins once the incoming one is ready, and if the outgoing track
                // ends first the queue simply advances as it would without a crossfade.
                player.volume = outputLevel
                incomingPlayer.volume = 0
                if position >= currentDuration { cancelCrossfade(resetVolume: true) }
                return
            }
        }
        player.volume = Float(min(max(gains.outgoing, 0), 1)) * outputLevel
        let gainMatch = transitionPlan?.gainMatchDB.map { pow(10, $0 / 20) } ?? 1
        incomingPlayer.volume = Float(min(max(gains.incoming * gainMatch, 0), 1.5)) * outputLevel
        if !startingNow, let plan = transitionPlan, plan.style == .beatmatchedBlend {
            let incoming = incomingPlayer
            let clockRate: Double = {
                guard case .mix = queueSource else { return plan.blendRate }
                return 1
            }()
            let expected = plan.entryTime + max(0, position - plan.exitTime) * clockRate
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

        // Keep both tracks alive for the full three-phrase handoff. The old
        // implementation advanced as soon as the incoming ramp reached 1,
        // truncating the equal-volume phrase and the outgoing fade.
        let transitionEnd = plannedFadeStart + fadeSeconds
        if position >= transitionEnd || position >= currentDuration {
            finishCrossfade(to: nextIndex, row: next)
        }
    }

    @discardableResult
    func prepareCrossfadePlayer(for row: TrackRow, at nextIndex: Int) -> Bool {
        if let existing = crossfadePlayer,
           crossfadeNextTrackId == row.track.id,
           crossfadeNextIndex == nextIndex {
            // The incoming item usually finishes loading a few ticks after it was created.
            if !crossfadePrerolled, !transitionStartedForCurrentEdge {
                crossfadePrerolled = TransitionPlayerControl.preroll(existing, rate: crossfadeTargetRate)
            }
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
        nextPlayer.volume = 0
        crossfadePlayer = nextPlayer
        crossfadeNextTrackId = row.track.id
        crossfadeNextIndex = nextIndex
        crossfadeNextLoader = built.loader
        nextPlayer.rate = 0
        crossfadePrerolled = TransitionPlayerControl.preroll(nextPlayer, rate: crossfadeTargetRate)
        return true
    }

    private var crossfadeTargetRate: Float {
        guard transitionPlan?.style == .beatmatchedBlend,
              let trackID = transitionPlan?.toTrackID else { return 1 }
        if case .mix = queueSource { return mixPlaybackRate(for: trackID) }
        return Float(transitionPlan?.blendRate ?? 1)
    }

    /// Schedules the incoming item against the outgoing player's host clock.
    /// The audio-mix ramp is intentionally not used here: AVPlayer.volume is
    /// the sole gain ramp, avoiding the previous double-fade dip.
    /// Returns false, leaving the incoming player untouched, when it can't be started yet.
    private func startScheduledTransition(fadeStart: Double, entryTime: Double) -> Bool {
        guard let incoming = crossfadePlayer, TransitionPlayerControl.isReady(incoming) else { return false }
        let plan = transitionPlan
        let targetRate = crossfadeTargetRate
        let scheduled: Bool
        if let timebase = player.currentItem?.timebase {
            let now = CMClockGetTime(CMClockGetHostTimeClock())
            let host = AudioPlayer.transitionHostTime(
                exitSeconds: fadeStart,
                currentItemTime: player.currentTime(),
                timebase: timebase,
                hostTime: now)
            scheduled = TransitionPlayerControl.schedule(
                incoming, rate: targetRate,
                itemTime: CMTime(seconds: entryTime.isFinite ? max(0, entryTime) : 0, preferredTimescale: 600),
                hostTime: host)
        } else {
            scheduled = false
        }
        // No usable clock, or the synchronized start refused: start it now instead (never raises).
        if !scheduled {
            if targetRate == 1 { incoming.play() } else { incoming.playImmediately(atRate: targetRate) }
        }
        transitionStartedForCurrentEdge = true

        transitionTask?.cancel()
        guard let plan, plan.style == .beatmatchedBlend,
              let beats = plan.rateRampBeats, beats > 0,
              let overlapBeats = plan.overlapBeats,
              plan.overlapSeconds > 0
        else { return true }
        let rampBPM = max(1, Double(overlapBeats) / plan.overlapSeconds * 60)
        let rateRampStart: Double
        let rateRampEnd: Double
        if case .mix = queueSource {
            // Both players are already on the mix's single reference clock;
            // do not ramp the incoming item back toward its source tempo.
            rateRampStart = Double(targetRate)
            rateRampEnd = Double(targetRate)
        } else {
            rateRampStart = plan.blendRate
            rateRampEnd = 1
        }
        let ramp = AudioPlayer.transitionRateRamp(start: rateRampStart, end: rateRampEnd,
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
            if resetVolume { player.volume = outputLevel }
            return
        }
        crossfadePlayer?.pause()
        crossfadePlayer?.replaceCurrentItem(with: nil)
        crossfadePlayer = nil
        crossfadeNextTrackId = nil
        crossfadeNextIndex = nil
        crossfadePrerolled = false
        crossfadeNextLoader?.shutdown()
        crossfadeNextLoader = nil
        crossfadeCompletionInFlight = false
        transitionStartedForCurrentEdge = false
        transitionTask?.cancel()
        transitionTask = nil
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
