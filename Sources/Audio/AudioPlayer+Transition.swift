import Foundation
import AVFoundation

extension AudioPlayer {
    /// Publishes the planned edge for the currently playing mix queue. The
    /// existing AVPlayer crossfade remains the transport-safe executor, while
    /// the mix plan supplies the edge style, overlap, and countdown shown to
    /// the user. This keeps playback and the preview on one source of truth.
    func scheduleTransitionPlan() {
        guard case .mix(let mix) = queueSource,
              let currentID = currentTrack?.track.id,
              let nextID = queue.indices.contains(index + 1) ? queue[index + 1].track.id : nil,
              let nextStep = mix.steps.first(where: { $0.trackID == nextID }) else {
            transitionPlan = nil
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
        let currentBPM = mix.steps.first(where: { $0.trackID == currentID })?.effectiveBPM ?? bpm
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
}
