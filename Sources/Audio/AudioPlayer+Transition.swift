import Foundation
import AVFoundation
import OSLog

extension AudioPlayer {
    private static let transitionLog = Logger(subsystem: "guru.parso.platterhead", category: "transition")

    /// Resolves the exact stored grids for the current edge and runs the same
    /// planner used by Mix Preview. There is deliberately no BPM/key/overlap
    /// fallback based on a step number: an unavailable grid is reported as a
    /// plain fade with an honest preparation reason.
    func scheduleTransitionPlan() {
        transitionPlanningTask?.cancel()
        // The mix decks plan their own blends from the audio and publish them.
        guard mixDecks == nil else { return }
        guard smartTransitionsEnabled else {
            transitionPlan = nil
            transitionPrepState = .cancelled
            return
        }
        let globalTransitions = UserDefaults.standard.bool(forKey: "smartTransitionsEverywhere")
        guard let current = currentTrack, let currentID = current.track.id,
              let next = queue.indices.contains(index + 1) ? queue[index + 1] : nil,
              let nextID = queue.indices.contains(index + 1) ? queue[index + 1].track.id : nil else {
            transitionPlan = nil
            transitionPrepState = .ready
            return
        }

        let mix: MixPlan?
        if case .mix(let queuedMix) = queueSource {
            mix = queuedMix
        } else if globalTransitions {
            mix = nil
        } else {
            transitionPlan = nil
            transitionPrepState = .ready
            return
        }

        if mix != nil && mix?.steps.first(where: { $0.trackID == nextID }) == nil {
            guard globalTransitions else {
                transitionPlan = nil
                transitionPrepState = .ready
                return
            }
        }

        if let stored = mix?.transitionPlans.first(where: {
            $0.fromTrackID == currentID && $0.toTrackID == nextID
        }) {
            transitionPlan = stored
            transitionPrepState = .ready
            return
        }

            transitionPlan = nil
            transitionPrepState = .notPrepared
        let context = TransitionPlanningContext(
            fromTrackID: currentID, toTrackID: nextID,
            fromDuration: duration > 0 ? duration : (current.track.durationSec ?? 0),
            toDuration: next.track.durationSec ?? 0,
            sameAlbumInOrder: CrossfadeCurve.suppressesForGaplessAlbum(
                current: CrossfadeCurve.AlbumContinuity(
                    albumID: current.album?.id, sourceID: current.source?.id,
                    albumTitle: current.album?.title, albumArtist: current.album?.artist,
                    discNumber: current.track.discNo, trackNumber: current.track.trackNo),
                next: CrossfadeCurve.AlbumContinuity(
                    albumID: next.album?.id, sourceID: next.source?.id,
                    albumTitle: next.album?.title, albumArtist: next.album?.artist,
                    discNumber: next.track.discNo, trackNumber: next.track.trackNo)),
            incomingBuffered: true)
        transitionPlanningTask = Task { [weak self] in
            let fromPayload = try? await LibraryStore.shared.transitionPrepPayload(trackId: currentID)
            let toPayload = try? await LibraryStore.shared.transitionPrepPayload(trackId: nextID)
            guard !Task.isCancelled, let self else { return }
            var resolved = TransitionPlanner.plan(from: fromPayload, to: toPayload, context: context)
            if resolved.style == .plainCrossfade {
                resolved.overlapSeconds = max(resolved.overlapSeconds, self.normalizedCrossfadeSeconds)
            }
            self.transitionPlan = resolved
            self.transitionPrepState = fromPayload != nil && toPayload != nil ? .ready : .notPrepared
        }
    }

    /// Starts a real two-item audition instead of seeking the unrelated live
    /// queue. The outgoing edge is cued ten seconds before its analyzed exit;
    /// the normal transition executor then loads, aligns, and blends the
    /// incoming item using the same stored plan shown in the sheet.
    public func auditionTransition(outgoing: TrackRow, incoming: TrackRow,
                                   plan: TransitionPlan) {
        let outgoingID = outgoing.track.id ?? plan.fromTrackID
        let incomingID = incoming.track.id ?? plan.toTrackID
        let steps = [
            MixStep(trackID: outgoingID, position: 0,
                    effectiveBPM: outgoing.track.durationSec ?? 0),
            MixStep(trackID: incomingID, position: 1,
                    effectiveBPM: incoming.track.durationSec ?? 0)
        ]
        let source = MixPlan(steps: steps, excluded: [], summary: MixSummary(),
                             request: MixRequest(candidates: []), transitionPlans: [plan])
        play(tracks: [outgoing, incoming], startAt: 0, source: .mix(source))
        if let mixDecks {
            // The decks plan this pair from its audio; audition their blend.
            mixDecks.auditionNextBlend()
            return
        }
        transitionPlan = plan
        transitionPrepState = .ready
        Task { [weak self] in
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard !Task.isCancelled, let self,
                      self.currentTrack?.id == outgoing.id else { return }
                if self.duration > 0 || self.player.currentItem != nil {
                    self.seek(to: max(0, plan.exitTime - 10))
                    self.resumePlayback()
                    return
                }
            }
        }
    }

    /// Shared math used by the executor and by deterministic tests. Host time
    /// is expressed in the same timescale as AVAudioTime's sample timeline.
    static func transitionHostTime(exitSeconds: Double, currentItemTime: CMTime,
                                   timebase: CMTimebase, hostTime: CMTime) -> CMTime {
        let offset = max(0, exitSeconds - max(0, currentItemTime.seconds))
        let rate = max(0.001, CMTimebaseGetRate(timebase))
        return hostTime + CMTime(seconds: offset / rate, preferredTimescale: 600)
    }

    static func transitionRateRamp(start: Double, end: Double, beats: Int,
                                   bpm: Double) -> [(offset: Double, rate: Double)] {
        guard beats > 0, bpm > 0 else { return [(0, end)] }
        let beatSeconds = 60 / bpm
        return (0...beats).map { index in
            let fraction = Double(index) / Double(beats)
            return (Double(index) * beatSeconds, start + (end - start) * fraction)
        }
    }

    static func shouldDowngradeTransition(isRemote: Bool, likelyBufferedByExit: Bool) -> Bool {
        isRemote && !likelyBufferedByExit
    }

    /// Configure an item for beat-matched playback. AVPlayer's regular
    /// buffering policy is intentionally disabled here: the transition
    /// scheduler owns the hand-over deadline and will downgrade a remote edge
    /// when it cannot meet it.
    static func configureTransitionItem(_ item: AVPlayerItem) {
        // Mix transitions are key-tempo transitions: changing rate must not
        // shift the musical key.
        item.audioTimePitchAlgorithm = .spectral
        item.preferredForwardBufferDuration = 20
        item.automaticallyPreservesTimeOffsetFromLive = false
    }

    /// Returns the rate that puts a mix track on the plan's single reference
    /// BPM. `spectral` time pitch preserves the analyzed musical key while the
    /// source is sped up to that rate.
    func mixPlaybackRate(for trackID: Int64) -> Float {
        guard case .mix(let mix) = queueSource,
              let step = mix.steps.first(where: { $0.trackID == trackID }),
              let sourceBPM = step.sourceBPM,
              sourceBPM.isFinite, sourceBPM > 0,
              step.effectiveBPM.isFinite, step.effectiveBPM > 0 else { return 1 }
        return Self.mixPlaybackRate(referenceBPM: step.effectiveBPM, sourceBPM: sourceBPM)
    }

    static func mixPlaybackRate(referenceBPM: Double, sourceBPM: Double) -> Float {
        guard referenceBPM.isFinite, referenceBPM > 0,
              sourceBPM.isFinite, sourceBPM > 0 else { return 1 }
        return Float(referenceBPM / sourceBPM)
    }

    func publishTransition(_ plan: TransitionPlan?) {
        transitionPlan = plan
    }

    func cancelTransition() {
        transitionTask?.cancel()
        transitionTask = nil
        transitionPlanningTask?.cancel()
        transitionPlanningTask = nil
        transitionPlan = nil
        transitionPrepState = .ready
    }

    /// The current AVPlayer crossfade remains the safe fallback. This seam is
    /// where planned items are attached once the device alignment gate passes.
    func applyTransitionFallback(_ plan: TransitionPlan) {
        publishTransition(plan)
        guard plan.style != .gapless else { return }
        crossfadeSeconds = max(crossfadeSeconds, plan.overlapSeconds)
    }

    func logTransitionDrift(_ driftSeconds: Double, trackID: Int64) {
#if DEBUG
        Self.transitionLog.debug("transition alignment track=\(trackID, privacy: .public) drift=\(driftSeconds, privacy: .public)s")
#endif
    }
}
