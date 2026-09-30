import Foundation
import AVFoundation
import OSLog

extension AudioPlayer {
    private static let transitionLog = Logger(subsystem: "guru.parso.platterhead", category: "transition")

    /// Publishes the planned edge for the currently playing mix queue. The
    /// existing AVPlayer crossfade remains the transport-safe executor, while
    /// the mix plan supplies the edge style, overlap, and countdown shown to
    /// the user. This keeps playback and the preview on one source of truth.
    func scheduleTransitionPlan() {
        let globalTransitions = UserDefaults.standard.bool(forKey: "smartTransitionsEverywhere")
        guard let currentID = currentTrack?.track.id,
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

        guard let nextStep = mix?.steps.first(where: { $0.trackID == nextID }) else {
            guard globalTransitions else {
                transitionPlan = nil
                transitionPrepState = .ready
                return
            }
            transitionPlan = TransitionPlan(fromTrackID: currentID, toTrackID: nextID,
                                            style: .plainCrossfade,
                                            overlapSeconds: normalizedCrossfadeSeconds,
                                            confidence: 0.2,
                                            reasons: [.gridNotReady(.ready)])
            transitionPrepState = .ready
            return
        }

        let edge = nextStep.edgeIn
        let bpm = max(1, nextStep.effectiveBPM)
        let overlapBeats = max(4, min(32, edge?.flags.contains(.keyClash) == true ? 4 : 8))
        let overlapSeconds = min(30, Double(overlapBeats) * 60 / bpm)
        let style: TransitionStyle = edge?.flags.contains(.keyClash) == true
            ? .phraseFade : .beatmatchedBlend
        let delta = edge?.bpmDeltaPct
        let currentBPM = mix?.steps.first(where: { $0.trackID == currentID })?.effectiveBPM ?? bpm
        let blendRate = max(0.5, min(2, bpm / max(1, currentBPM)))
        transitionPlan = TransitionPlan(
            fromTrackID: currentID,
            toTrackID: nextID,
            style: style,
            exitTime: max(0, duration - overlapSeconds),
            entryTime: 0,
            overlapBeats: overlapBeats,
            overlapSeconds: overlapSeconds,
            blendRate: style == .beatmatchedBlend ? blendRate : 1,
            rateRampBeats: style == .beatmatchedBlend ? 16 : nil,
            keyRelation: edge?.key ?? .unknown,
            bpmDeltaPct: delta,
            confidence: edge == nil ? 0.4 : 0.8,
            reasons: edge.map { [.keyCompatible($0.key), .tempoMatched(pct: $0.bpmDeltaPct)] } ?? [])
        transitionPrepState = .ready
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

    /// The device executor uses a bounded one-beat correction after its first
    /// drift sample. Keeping this pure makes the safety limit testable without
    /// requiring an audio route or a real-time clock.
    static func transitionDriftCorrection(driftSeconds: Double) -> Double {
        guard driftSeconds.isFinite, abs(driftSeconds) > 0.015 else { return 0 }
        return driftSeconds > 0 ? -0.005 : 0.005
    }

    /// Configure an item for beat-matched playback. AVPlayer's regular
    /// buffering policy is intentionally disabled here: the transition
    /// scheduler owns the hand-over deadline and will downgrade a remote edge
    /// when it cannot meet it.
    static func configureTransitionItem(_ item: AVPlayerItem) {
        item.audioTimePitchAlgorithm = .timeDomain
        item.preferredForwardBufferDuration = 20
        item.automaticallyPreservesTimeOffsetFromLive = false
    }

    static func transitionAudioMix(for item: AVPlayerItem,
                                   fadeStart: CMTime,
                                   fadeDuration: CMTime,
                                   incoming: Bool,
                                   gainMatchDB: Double = 0) -> AVAudioMix? {
        guard let track = item.asset.tracks(withMediaType: .audio).first,
              fadeDuration.isValid, fadeDuration.seconds > 0 else { return nil }
        let params = AVMutableAudioMixInputParameters(track: track)
        let gain = Float(pow(10, gainMatchDB / 20))
        if incoming {
            params.setVolumeRamp(fromStartVolume: 0, toEndVolume: gain,
                                 timeRange: CMTimeRange(start: fadeStart, duration: fadeDuration))
        } else {
            params.setVolumeRamp(fromStartVolume: gain, toEndVolume: 0,
                                 timeRange: CMTimeRange(start: fadeStart, duration: fadeDuration))
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = [params]
        return mix
    }

    func publishTransition(_ plan: TransitionPlan?) {
        transitionPlan = plan
    }

    func cancelTransition() {
        transitionTask?.cancel()
        transitionTask = nil
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
