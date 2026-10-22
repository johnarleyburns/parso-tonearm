#if !os(watchOS)
import Foundation

/// Converts the durable catalog recipe into renderer coordinates. The player
/// calls this only after both referenced catalog tracks are blend-eligible;
/// no waveform analysis belongs on this path.
extension CatalogEdgePlan {
    func boundedOverlap(sampleRate: Double, outgoingZeroFrame: Int64,
                        incomingTotalFrames: Int64, minimumBufferedFrames: Int) -> BoundedOverlapPlan? {
        guard isRenderable, incomingTotalFrames > 0 else { return nil }
        let start = outgoingZeroFrame + Int64((blendStartSeconds * sampleRate).rounded())
        let duration = max(1, Int(((blendEndSeconds - blendStartSeconds) * sampleRate).rounded()))
        let incoming = Int64((incomingOffsetSeconds * sampleRate).rounded())
        guard incoming >= 0 && incoming < incomingTotalFrames else { return nil }
        return BoundedOverlapPlan(startClock: start, fadeFrames: duration,
                                  incomingStartFrame: incoming, incomingTotalFrames: incomingTotalFrames,
                                  incomingTempo: tempo, incomingGain: Float(incomingGain),
                                  minIncomingBufferedFrames: minimumBufferedFrames)
    }
}
#endif
