import Foundation
import AVFoundation

extension AudioPlayer {
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
