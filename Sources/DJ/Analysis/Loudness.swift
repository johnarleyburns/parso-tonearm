import Foundation
import Accelerate
import ParsoAudioCore

/// BS.1770-4 / EBU R128 loudness (§20).
///
/// Phase 5b of the audio-engine unification: the hand-rolled K-weighting /
/// gating / true-peak DSP that used to live here has been replaced by
/// `ParsoAudioCore.LoudnessAnalyzer` (libebur128). `LoudnessAnalyzer` is now a
/// thin mapping shim: it bridges the analysis `PCMBuffer` into the core buffer,
/// runs the shared measurement against a −18 LUFS DJ-headroom target, and maps
/// the result back into the `LoudnessResult` shape the `loudness` GRDB table and
/// the `NormalizationPlanner` already expect — `replayGainDB` (= gain to the
/// −18 LUFS target) and `dynamicRangeDB` (crest factor: true peak − overall RMS)
/// are the two fields the core result does not carry directly.
public enum LoudnessAnalyzer {

    public static let workingSampleRate: Double = AudioDecoder.workingSampleRate

    /// Target for `replayGainDB` (§20.1): −18 LUFS for DJ headroom.
    public static let replayGainTargetLUFS: Double = -18

    /// The mapped Stage-1 loudness result. Field-for-field identical to the
    /// pre-Phase-5b type so `AnalysisCoordinator.persist` and the `loudness`
    /// schema are unchanged.
    public struct LoudnessResult: Equatable, Sendable {
        public var integratedLUFS: Double?
        public var truePeakDBTP: Double?
        public var replayGainDB: Double?
        public var dynamicRangeDB: Double?
        public var loudnessRangeLU: Double?
        public var version: Int

        public init(integratedLUFS: Double? = nil,
                    truePeakDBTP: Double? = nil,
                    replayGainDB: Double? = nil,
                    dynamicRangeDB: Double? = nil,
                    loudnessRangeLU: Double? = nil,
                    version: Int = AnalysisVersions.loudness) {
            self.integratedLUFS = integratedLUFS
            self.truePeakDBTP = truePeakDBTP
            self.replayGainDB = replayGainDB
            self.dynamicRangeDB = dynamicRangeDB
            self.loudnessRangeLU = loudnessRangeLU
            self.version = version
        }
    }

    /// Measure loudness over the canonical 48 kHz analysis buffer.
    public static func analyze(_ pcm: PCMBuffer) -> LoudnessResult {
        let measured = bridge(pcm).map {
            ParsoAudioCore.LoudnessAnalyzer(targetLUFS: replayGainTargetLUFS).measure($0)
        }
        return map(measured, pcm: pcm)
    }

    /// Map a `ParsoAudioCore.LoudnessResult` (already measured against the −18
    /// LUFS target) plus the source buffer into the shim result. Used by
    /// `AnalyzePipeline.run` to avoid a second K-weighting pass.
    static func map(_ core: ParsoAudioCore.LoudnessResult?, pcm: PCMBuffer) -> LoudnessResult {
        let integrated = core.flatMap { $0.integratedLUFS.isFinite ? $0.integratedLUFS : nil }
        let truePeak = core.flatMap { $0.truePeakDBTP.isFinite ? $0.truePeakDBTP : nil }
        let replayGain = core.flatMap { $0.gainToTargetDB.isFinite ? $0.gainToTargetDB : nil }
        let lra = core.flatMap { $0.loudnessRangeLU.isFinite ? $0.loudnessRangeLU : nil }

        // Crest-factor DR: true peak − overall RMS, in dB (a "how punchy" hint).
        var dynamicRange: Double?
        if let truePeak, let base = pcm.mono.baseAddress, pcm.frameCount > 0 {
            var rms: Float = 0
            vDSP_rmsqv(base, 1, &rms, vDSP_Length(pcm.frameCount))
            if rms > 0 { dynamicRange = truePeak - 20 * log10(Double(rms)) }
        }

        return LoudnessResult(integratedLUFS: integrated,
                              truePeakDBTP: truePeak,
                              replayGainDB: replayGain,
                              dynamicRangeDB: dynamicRange,
                              loudnessRangeLU: lra,
                              version: AnalysisVersions.loudness)
    }

    /// Copy the deinterleaved analysis channels into a `ParsoAudioCore.PCMBuffer`
    /// (the shape libebur128 measures). `nil` for an empty buffer.
    static func bridge(_ pcm: PCMBuffer) -> ParsoAudioCore.PCMBuffer? {
        guard pcm.frameCount > 0, pcm.channelCount > 0 else { return nil }
        let core = ParsoAudioCore.PCMBuffer(
            format: AudioFormat(sampleRate: pcm.sampleRate, channelCount: pcm.channelCount),
            capacity: pcm.frameCount)
        for c in 0..<pcm.channelCount {
            let dst = core.channel(c)
            let src = pcm.channels[c]
            for i in 0..<pcm.frameCount { dst[i] = src[i] }
        }
        return core
    }
}
