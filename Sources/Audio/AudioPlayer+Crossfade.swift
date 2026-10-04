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
        // Field test 2026-10-03: the incoming item used to be created only once the fade had begun.
        // A stream then started late, at its entry point rather than in phase, so the beats were
        // offset and it jumped in at the curve's current level. Prepare it well before the exit.
        guard position >= plannedFadeStart - TransitionTiming.prepareLeadSeconds else {
            player.volume = outputLevel
            return
        }
        guard prepareCrossfadePlayer(for: next, at: nextIndex),
              let incomingPlayer = crossfadePlayer else { return }
        startTransitionTicker()

        // `position` comes from a time observer hop and can be stale; read the clock now.
        let outgoingNow = freshOutgoingTime(fallback: position)
        if !transitionStartedForCurrentEdge {
            let untilExitSeconds = (plannedFadeStart - outgoingNow) / max(outgoingRate, 0.001)
            guard untilExitSeconds <= TransitionTiming.scheduleLeadSeconds,
                  TransitionPlayerControl.isReady(incomingPlayer),
                  startScheduledTransition(exit: plannedFadeStart,
                                           entry: transitionPlan?.entryTime ?? 0,
                                           outgoingNow: outgoingNow) else {
                // Not time yet, or the incoming track hasn't loaded (usual for a stream; starting it
                // unready is what crashed TestFlight 520/521). The outgoing track keeps full level;
                // if it ends first the queue simply advances as it would without a crossfade.
                player.volume = outputLevel
                incomingPlayer.volume = 0
                if outgoingNow >= currentDuration { cancelCrossfade(resetVolume: true) }
                return
            }
        }

        let gains: CrossfadeCurve.Gains
        if transitionPlan?.style == .beatmatchedBlend,
           transitionPlan?.overlapBeats == 96 {
            gains = CrossfadeCurve.threePhraseGains(position: outgoingNow,
                                                    fadeStart: plannedFadeStart,
                                                    fadeSeconds: fadeSeconds)
        } else {
            gains = CrossfadeCurve.gains(position: outgoingNow,
                                         fadeStart: plannedFadeStart,
                                         fadeSeconds: fadeSeconds,
                                         curve: crossfadeCurve)
        }
        guard gains.active else {
            // Scheduled, waiting for the exit downbeat.
            player.volume = outputLevel
            incomingPlayer.volume = 0
            return
        }
        let lateFade = TransitionTiming.lateStartGain(outgoingNow: outgoingNow,
                                                      startedAtOutgoing: transitionLateStartPosition)
        player.volume = Float(min(max(gains.outgoing, 0), 1)) * outputLevel
        let gainMatch = transitionPlan?.gainMatchDB.map { pow(10, $0 / 20) } ?? 1
        incomingPlayer.volume = Float(min(max(gains.incoming * lateFade * gainMatch, 0), 1.5)) * outputLevel
        if let plan = transitionPlan, plan.style == .beatmatchedBlend {
            keepBeatsAligned(plan: plan, exit: plannedFadeStart, outgoingNow: outgoingNow,
                             incoming: incomingPlayer)
        }

        // Keep both tracks alive for the full three-phrase handoff. The old
        // implementation advanced as soon as the incoming ramp reached 1,
        // truncating the equal-volume phrase and the outgoing fade.
        let transitionEnd = plannedFadeStart + fadeSeconds
        if outgoingNow >= transitionEnd || outgoingNow >= currentDuration {
            finishCrossfade(to: nextIndex, row: next)
        }
    }

    /// The outgoing player's item time right now while it is playing; otherwise the observed
    /// position (a paused player's clock doesn't move).
    private func freshOutgoingTime(fallback: Double) -> Double {
        guard player.rate > 0 else { return fallback }
        let seconds = player.currentTime().seconds
        return seconds.isFinite ? seconds : fallback
    }

    /// The outgoing track's playback rate: its live rate, or the one it is meant to play at.
    private var outgoingRate: Double {
        if player.rate > 0 { return Double(player.rate) }
        guard let id = currentTrack?.track.id else { return 1 }
        return Double(mixPlaybackRate(for: id))
    }

    /// Compares the incoming item with where the outgoing beat says it should be, twice a second,
    /// and removes small drift by nudging the incoming rate for the next half second. The old
    /// check seeked by 5 ms on every tick, which was audible as a gap, and in a mix compared against
    /// a clock that assumed both tracks had the same source tempo, so it pushed them apart.
    private func keepBeatsAligned(plan: TransitionPlan, exit: Double, outgoingNow: Double,
                                  incoming: AVPlayer) {
        guard outgoingNow - lastTransitionDriftCheck >= 0.5 * outgoingRate,
              outgoingNow >= exit + 0.25 else { return }
        lastTransitionDriftCheck = outgoingNow
        let target = Double(crossfadeTargetRate)
        let expected = TransitionTiming.expectedIncomingTime(
            exit: exit, entry: plan.entryTime, outgoingNow: outgoingNow,
            outgoingRate: outgoingRate, incomingRate: target)
        let actual = incoming.currentTime().seconds
        guard actual.isFinite, incoming.rate > 0 else { return }
        switch TransitionTiming.correction(driftSeconds: actual - expected, expectedIncomingTime: expected) {
        case .none:
            incoming.rate = Float(target)
        case .nudgeRate(let factor):
            incoming.rate = Float(target * factor)
            logTransitionDrift(actual - expected, trackID: plan.toTrackID)
        case .seek(let time):
            incoming.seek(to: CMTime(seconds: time, preferredTimescale: 600),
                          toleranceBefore: .zero, toleranceAfter: .zero)
            logTransitionDrift(actual - expected, trackID: plan.toTrackID)
        }
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

    /// Starts the incoming item on the host clock so its entry downbeat lands on the outgoing
    /// exit downbeat. Normally scheduled ahead of the exit; when the incoming item was ready only
    /// after it, it starts a moment from now at the matching point of its own beat grid
    /// (`TransitionTiming.start`) and fades in from there instead of jumping to the curve.
    /// AVPlayer.volume is the sole gain ramp (no audio-mix ramp, which double-faded).
    /// Returns false, leaving the incoming player untouched, when it can't be started yet.
    private func startScheduledTransition(exit: Double, entry: Double, outgoingNow: Double) -> Bool {
        guard let incoming = crossfadePlayer, TransitionPlayerControl.isReady(incoming) else { return false }
        let targetRate = crossfadeTargetRate
        let start = TransitionTiming.start(exit: exit, entry: entry, outgoingNow: outgoingNow,
                                           outgoingRate: outgoingRate, incomingRate: Double(targetRate))
        let itemTime = CMTime(seconds: start.incomingItemTime, preferredTimescale: 48_000)
        let host = CMClockGetTime(CMClockGetHostTimeClock())
            + CMTime(seconds: start.delaySeconds, preferredTimescale: 48_000)
        let scheduled = TransitionPlayerControl.schedule(incoming, rate: targetRate,
                                                         itemTime: itemTime, hostTime: host)
        if !scheduled {
            // No synchronized start available: start now from the in-phase point (never raises).
            incoming.seek(to: itemTime, toleranceBefore: .zero, toleranceAfter: .zero)
            if targetRate == 1 { incoming.play() } else { incoming.playImmediately(atRate: targetRate) }
        }
        transitionLateStartPosition = start.isLate || !scheduled
            ? outgoingNow + start.delaySeconds * outgoingRate : nil
        lastTransitionDriftCheck = -.infinity
        transitionStartedForCurrentEdge = true
        // The incoming track stays on the outgoing tempo for the whole overlap. Ramping it back to
        // its own tempo while both play (as before) pulled the beats apart mid-blend; that happens
        // after the handoff instead (`returnToOwnTempo`).
        transitionTask?.cancel()
        transitionTask = nil
        return true
    }

    /// After a non-mix blend, eases the now-solo track from the blend rate back to its own tempo.
    /// In a mix every track stays on the mix's single reference tempo, so nothing ramps.
    private func returnToOwnTempo(after plan: TransitionPlan?) {
        tempoReturnTask?.cancel()
        tempoReturnTask = nil
        guard let plan, plan.style == .beatmatchedBlend, !isMixQueue,
              abs(plan.blendRate - 1) > 0.0005, plan.overlapSeconds > 0,
              let overlapBeats = plan.overlapBeats, overlapBeats > 0 else { return }
        let beats = max(16, min(plan.rateRampBeats ?? 32, 32))
        let bpm = max(1, Double(overlapBeats) / plan.overlapSeconds * 60)
        let ramp = AudioPlayer.transitionRateRamp(start: plan.blendRate, end: 1, beats: beats, bpm: bpm)
        let rampedPlayer = player
        tempoReturnTask = Task { [weak self] in
            var previousOffset = 0.0
            for point in ramp.dropFirst() {
                try? await Task.sleep(nanoseconds: UInt64(max(0, point.offset - previousOffset) * 1_000_000_000))
                guard !Task.isCancelled, let self, self.player === rampedPlayer, rampedPlayer.rate > 0 else { return }
                rampedPlayer.rate = Float(point.rate)
                previousOffset = point.offset
            }
        }
    }

    private var isMixQueue: Bool {
        if case .mix = queueSource { return true }
        return false
    }

    func finishCrossfade(to nextIndex: Int, row: TrackRow) {
        guard !crossfadeCompletionInFlight,
              let nextPlayer = crossfadePlayer,
              queue.indices.contains(nextIndex) else {
            return
        }
        crossfadeCompletionInFlight = true
        defer { crossfadeCompletionInFlight = false }
        let finishedPlan = transitionPlan
        // Drop any alignment nudge: the incoming track carries on at its planned rate.
        let plannedRate = crossfadeTargetRate
        if nextPlayer.rate > 0, nextPlayer.rate != plannedRate { nextPlayer.rate = plannedRate }
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
        scheduleTransitionPlan()
        returnToOwnTempo(after: finishedPlan)
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
        transitionTicker?.cancel()
        transitionTicker = nil
        transitionLateStartPosition = nil
        lastTransitionDriftCheck = -.infinity
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
