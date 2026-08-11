import Foundation
import Accelerate

/// BS.1770-4 / EBU R128 loudness measurements (§20), computed over the
/// canonical 48 kHz `PCMBuffer`. Pure and deterministic (NFR-DET-3): every
/// reduction is a fixed vDSP call, no fast-math, no parallel reordering.
public enum LoudnessAnalyzer {

    public static let workingSampleRate: Double = AudioDecoder.workingSampleRate

    /// Target for `replayGainDB` (§20.1): −18 LUFS for DJ headroom.
    public static let replayGainTargetLUFS: Double = -18

    public static func analyze(_ pcm: PCMBuffer) -> LoudnessResult {
        let kWeighted = pcm.channels.map { Self.kWeightFilter(Array($0)) }
        let integrated = Self.integratedLUFS(kWeighted)
        let truePeak = Self.truePeakDBTP(kWeighted)
        let lra = Self.loudnessRangeLU(kWeighted)
        let crest = Self.crestFactorDB(pcm, truePeakDBTP: truePeak)

        var replayGain: Double?
        if let integrated { replayGain = replayGainTargetLUFS - integrated }

        return LoudnessResult(integratedLUFS: integrated,
                              truePeakDBTP: truePeak,
                              replayGainDB: replayGain,
                              dynamicRangeDB: crest,
                              loudnessRangeLU: lra,
                              version: AnalysisVersions.loudness)
    }

    // MARK: - Result

    public struct LoudnessResult: Equatable, Sendable {
        public var integratedLUFS: Double?
        public var truePeakDBTP: Double?
        public var replayGainDB: Double?
        public var dynamicRangeDB: Double?
        public var loudnessRangeLU: Double?
        public var version: Int
    }

    // MARK: - K-weighting (BS.1770-4 two-stage pre-filter)

    /// BS.1770-4 K-weighting: a high-shelf "head" filter followed by a high-pass
    /// (RBJ biquad coefficients, as in ebur128), applied per channel with
    /// `vDSP_biquad`. Returns the filtered channel.
    static func kWeightFilter(_ samples: [Float]) -> [Float] {
        let fs = workingSampleRate

        // BS.1770-4 K-weighting filter coefficients ({b0,b1,b2,a1,a2} per
        // section, as vDSP_biquad_CreateSetup expects).
        let shelfF0 = 1681.974450955533
        let shelfG = 3.999843853973347
        let shelfQ = 0.7071752369554196
        let k1 = tan(Double.pi * shelfF0 / fs)
        let vh = pow(10, shelfG / 20)
        let vb = pow(vh, 0.4996667741545416)
        let a01 = 1 + k1 / shelfQ + k1 * k1
        let shelf = [
            (vh + vb * k1 / shelfQ + k1 * k1) / a01,
            2 * (k1 * k1 - vh) / a01,
            (vh - vb * k1 / shelfQ + k1 * k1) / a01,
            2 * (k1 * k1 - 1) / a01,
            (1 - k1 / shelfQ + k1 * k1) / a01,
        ]

        let hpF0 = 38.13547087602444
        let hpQ = 0.5003270373238773
        let k2 = tan(Double.pi * hpF0 / fs)
        let a02 = 1 + k2 / hpQ + k2 * k2
        let highPass = [
            1 / a02,
            -2 / a02,
            1 / a02,
            2 * (k2 * k2 - 1) / a02,
            (1 - k2 / hpQ + k2 * k2) / a02,
        ]

        let coefficients = shelf + highPass
        guard let setup = vDSP_biquad_CreateSetup(coefficients, 2) else {
            // Cannot build the filter setup; fall back to identity so analysis
            // degrades rather than crashes (§46.2 guards).
            return samples
        }
        defer { vDSP_biquad_DestroySetup(setup) }

        var output = [Float](repeating: 0, count: samples.count)
        if !samples.isEmpty {
            // vDSP_biquad's delay line is `2 * (sections + 1)` floats (the
            // header's pseudocode indexes Delay[2*s] and Delay[2*s+1] for
            // s in 0...sections); allocate the safe size and zero it.
            var delay = [Float](repeating: 0, count: 2 * (2 + 1))
            samples.withUnsafeBufferPointer { input in
                output.withUnsafeMutableBufferPointer { out in
                    vDSP_biquad(setup, &delay, input.baseAddress!, 1,
                                out.baseAddress!, 1, vDSP_Length(samples.count))
                }
            }
        }
        return output
    }

    // MARK: - Integrated loudness with absolute + relative gating

    /// ITU-R BS.1770-4 block: 400 ms, 75% overlap → 100 ms hop.
    static func blockMeanSquares(_ channel: [Float]) -> [Double] {
        let blockSamples = Int(0.4 * workingSampleRate)
        let hop = blockSamples / 4
        guard blockSamples > 0, channel.count >= blockSamples else { return [] }

        var means: [Double] = []
        means.reserveCapacity(channel.count / hop)
        var mean: Float = 0
        var i = 0
        while i + blockSamples <= channel.count {
            channel.withUnsafeBufferPointer { buf in
                vDSP_measqv(buf.baseAddress!.advanced(by: i), 1, &mean,
                            vDSP_Length(blockSamples))
            }
            means.append(Double(mean))
            i += hop
        }
        return means
    }

    /// Channel weights per BS.1770 (L/R = 1.0; our analysis decodes ≤ 2 channels).
    static func channelWeight(for index: Int) -> Double { 1.0 }

    static func integratedLUFS(_ kWeighted: [[Float]]) -> Double? {
        let blocks = kWeighted.map { blockMeanSquares($0) }

        // Per-block loudness (weighted sum across channels).
        let frameCount = blocks.first?.count ?? 0
        guard frameCount > 0 else { return nil }

        var blockLoudness: [Double] = []
        blockLoudness.reserveCapacity(frameCount)
        for i in 0..<frameCount {
            let weighted = blocks.indices.reduce(0.0) { acc, c in
                acc + channelWeight(for: c) * blocks[c][i]
            }
            blockLoudness.append(-0.691 + 10 * log10(max(weighted, 1e-15)))
        }

        // Absolute gate: −70 LUFS.
        let absoluteGated = blockLoudness.filter { $0 >= -70 }
        guard !absoluteGated.isEmpty else { return nil }

        // Relative gate: −10 LU below the ungated mean.
        let ungated = absoluteGated.reduce(0.0, +) / Double(absoluteGated.count)
        let gateThreshold = ungated - 10
        let relativeGated = absoluteGated.filter { $0 >= gateThreshold }
        guard !relativeGated.isEmpty else { return nil }

        let mean = relativeGated.reduce(0.0, +) / Double(relativeGated.count)
        return mean
    }

    // MARK: - True peak (4x oversampling, polyphase FIR)

    static func sinc(_ x: Double) -> Double {
        guard abs(x) > 1e-12 else { return 1 }
        let px = Double.pi * x
        return sin(px) / px
    }

    /// 4x polyphase interpolation kernel (windowed sinc), normalised to DC gain 4.
    static func makeInterpolationKernel(upsampleFactor: Int = 4, taps: Int = 64) -> [Float] {
        let center = Double(taps - 1) / 2
        var kernel = [Float](repeating: 0, count: taps)
        for k in 0..<taps {
            let x = (Double(k) - center) / Double(upsampleFactor)
            kernel[k] = Float(sinc(x))
        }
        // Hamming window.
        for k in 0..<taps {
            let w = 0.54 - 0.46 * cos(2 * Double.pi * Double(k) / Double(taps - 1))
            kernel[k] *= Float(w)
        }
        // Normalise to DC gain == upsampleFactor (compensates zero-stuffing).
        let sum = kernel.reduce(0, +)
        if sum > 0 {
            for i in kernel.indices { kernel[i] *= Float(upsampleFactor) / sum }
        }
        return kernel
    }

    static func truePeakDBTP(_ kWeighted: [[Float]]) -> Double? {
        let factor = 4
        let kernel = makeInterpolationKernel(upsampleFactor: factor)
        let half = kernel.count / 2
        var maxAbs: Float = 0

        for channel in kWeighted {
            let n = channel.count
            guard n > 0 else { continue }
            let upCount = n * factor
            // vDSP_conv reads A at indices up to N+P-2, so the input is
            // zero-padded to N+P-1 elements; the output is N elements long.
            var upsampled = [Float](repeating: 0, count: upCount + kernel.count - 1)
            for i in 0..<n { upsampled[i * factor] = channel[i] }
            var filtered = [Float](repeating: 0, count: upCount)
            vDSP_conv(upsampled, 1, kernel, 1, &filtered, 1,
                      vDSP_Length(upCount), vDSP_Length(kernel.count))
            // Correlation with a symmetric kernel: the output is aligned so the
            // valid steady-state region is the middle, away from the edges.
            for i in stride(from: half, to: half + upCount - kernel.count + 1, by: 1) {
                let a = abs(filtered[i])
                if a > maxAbs { maxAbs = a }
            }
        }
        guard maxAbs > 0 else { return nil }
        return 20 * log10(Double(maxAbs))
    }

    // MARK: - LRA (10th–95th percentile of short-term loudness) & crest DR

    /// Short-term loudness: 3 s windows (EBU R128), 75% overlap.
    static func shortTermLoudness(_ kWeighted: [[Float]]) -> [Double] {
        let windowSamples = Int(3.0 * workingSampleRate)
        let hop = windowSamples / 4
        guard windowSamples > 0 else { return [] }

        var results: [Double] = []
        var i = 0
        while true {
            var weighted: Double = 0
            var valid = true
            for (c, channel) in kWeighted.enumerated() {
                guard i + windowSamples <= channel.count else {
                    valid = false
                    break
                }
                var mean: Float = 0
                channel.withUnsafeBufferPointer { buf in
                    vDSP_measqv(buf.baseAddress!.advanced(by: i), 1, &mean,
                                vDSP_Length(windowSamples))
                }
                weighted += channelWeight(for: c) * Double(mean)
            }
            guard valid else { break }
            if weighted > 0 {
                results.append(-0.691 + 10 * log10(weighted))
            }
            i += hop
            if i + windowSamples > kWeighted.first?.count ?? 0 { break }
        }
        return results
    }

    static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = max(0, min(sorted.count - 1, Int((p / 100) * Double(sorted.count))))
        return sorted[index]
    }

    static func loudnessRangeLU(_ kWeighted: [[Float]]) -> Double? {
        let short = shortTermLoudness(kWeighted)
        guard short.count > 0 else { return nil }
        let p95 = percentile(short, 95)
        let p10 = percentile(short, 10)
        let lra = p95 - p10
        return lra.isFinite && lra > 0 ? lra : 0
    }

    /// Crest-factor DR: true peak − overall RMS, in dB (a "how punchy" hint).
    static func crestFactorDB(_ pcm: PCMBuffer, truePeakDBTP: Double?) -> Double? {
        var rms: Float = 0
        pcm.mono.withUnsafeBufferPointer { buf in
            vDSP_rmsqv(buf.baseAddress!, 1, &rms, vDSP_Length(pcm.frameCount))
        }
        guard rms > 0, let peak = truePeakDBTP else { return nil }
        let rmsDB = 20 * log10(Double(rms))
        return peak - rmsDB
    }
}
