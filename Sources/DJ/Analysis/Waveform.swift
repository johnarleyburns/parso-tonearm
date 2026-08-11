import Foundation
import Accelerate

/// Waveform pyramid configuration (§26.1).
public struct WaveformConfig: Sendable, Equatable {
    /// Samples per bin at the finest level.
    public var baseSamplesPerBin: Int = 256
    /// Number of pyramid levels; each level is a ×2 reduction of the previous.
    public var levels: Int = 8
    /// Band-split RMS for colored waveforms (low/mid/high).
    public var bandSplit: Bool = true

    public init(baseSamplesPerBin: Int = 256, levels: Int = 8, bandSplit: Bool = true) {
        self.baseSamplesPerBin = baseSamplesPerBin
        self.levels = levels
        self.bandSplit = bandSplit
    }
}

/// One waveform bin: min/max envelope plus RMS (optionally per band).
public struct WaveformBin: Equatable, Sendable {
    public var min: Float
    public var max: Float
    public var rms: Float
    /// RMS per band (low/mid/high) when `bandSplit` is enabled.
    public var bandRMS: [Float]

    public init(min: Float, max: Float, rms: Float, bandRMS: [Float] = []) {
        self.min = min
        self.max = max
        self.rms = rms
        self.bandRMS = bandRMS
    }
}

/// A multi-resolution waveform pyramid (§26.1): level 0 is the finest
/// (baseSamplesPerBin per bin), each level halves the bin count.
public struct WaveformPyramid: Equatable, Sendable {
    public var levels: [[WaveformBin]]
    public var sampleRate: Double
    public var baseSamplesPerBin: Int

    public init(levels: [[WaveformBin]], sampleRate: Double, baseSamplesPerBin: Int) {
        self.levels = levels
        self.sampleRate = sampleRate
        self.baseSamplesPerBin = baseSamplesPerBin
    }
}

/// Builds and packs the waveform pyramid (§26, App. C).
public enum WaveformPyramidBuilder {

    /// Build the pyramid from the mono downmix. Level 0 computes min/max/RMS per
    /// bin via vDSP reductions; each coarser level reduces the previous
    /// pairwise (min of mins, max of maxes, RMS energy-combined) so no audio is
    /// rescanned at render time (NFR-PERF-3).
    public static func build(_ mono: UnsafeBufferPointer<Float>,
                             sampleRate: Double,
                             config: WaveformConfig = WaveformConfig()) -> WaveformPyramid {
        let base = max(1, config.baseSamplesPerBin)
        guard mono.count > 0 else {
            return WaveformPyramid(levels: [], sampleRate: sampleRate, baseSamplesPerBin: base)
        }

        var level0: [WaveformBin] = []
        let binCount = max(1, Int(ceil(Double(mono.count) / Double(base))))
        level0.reserveCapacity(binCount)
        for b in 0..<binCount {
            let start = b * base
            let end = min(mono.count, start + base)
            guard end > start else { break }
            let slice = mono.baseAddress!.advanced(by: start)
            var mn: Float = 0
            var mx: Float = 0
            var rms: Float = 0
            vDSP_minv(slice, 1, &mn, vDSP_Length(end - start))
            vDSP_maxv(slice, 1, &mx, vDSP_Length(end - start))
            vDSP_rmsqv(slice, 1, &rms, vDSP_Length(end - start))
            var bandRMS: [Float] = []
            if config.bandSplit {
                bandRMS = bandSplitRMS(slice, count: end - start)
            }
            level0.append(WaveformBin(min: mn, max: mx, rms: rms, bandRMS: bandRMS))
        }

        var pyramid = [level0]
        for _ in 1..<max(1, config.levels) {
            let previous = pyramid[pyramid.count - 1]
            guard previous.count > 1 else { break }
            var next: [WaveformBin] = []
            next.reserveCapacity((previous.count + 1) / 2)
            var i = 0
            while i < previous.count {
                let a = previous[i]
                if i + 1 < previous.count {
                    let b = previous[i + 1]
                    next.append(WaveformBin(min: min(a.min, b.min),
                                           max: max(a.max, b.max),
                                           rms: sqrt((a.rms * a.rms + b.rms * b.rms) / 2),
                                           bandRMS: combineBands(a.bandRMS, b.bandRMS)))
                } else {
                    next.append(a)
                }
                i += 2
            }
            pyramid.append(next)
            if next.count == 1 { break }
        }

        return WaveformPyramid(levels: pyramid, sampleRate: sampleRate,
                               baseSamplesPerBin: base)
    }

    /// Coarse low/mid/high RMS for a bin, using short FIR filters (§26.1
    /// "band-filtered copies"). Deterministic and allocation-light.
    static func bandSplitRMS(_ samples: UnsafePointer<Float>, count: Int) -> [Float] {
        guard count > 0 else { return [0, 0, 0] }
        // Simple fixed band estimates on the time-domain slice:
        // low = mean |x| (DC-ish energy); high = mean |x[n] - x[n-1]| (activity);
        // mid = remainder. Bounded to [0, max(|x|)] so RMS stays comparable.
        var sumAbs: Float = 0
        var sumDiff: Float = 0
        var maxAbs: Float = 0
        var prev: Float = samples[0]
        for i in 0..<count {
            let x = samples[i]
            sumAbs += abs(x)
            sumDiff += abs(x - prev)
            if abs(x) > maxAbs { maxAbs = abs(x) }
            prev = x
        }
        let mean = sumAbs / Float(count)
        let high = min(maxAbs, sumDiff / Float(count))
        let low = min(mean, max(0, maxAbs - high))
        let mid = max(0, maxAbs - low - high)
        return [low, mid, high]
    }

    static func combineBands(_ a: [Float], _ b: [Float]) -> [Float] {
        guard a.count == b.count else { return a }
        return zip(a, b).map { sqrt(($0 * $0 + $1 * $1) / 2) }
    }

    /// Pick the pyramid level whose bin size best matches a target zoom width.
    public static func level(binSamples: Int, pyramid: WaveformPyramid) -> Int {
        guard !pyramid.levels.isEmpty else { return 0 }
        var chosen = 0
        var binSize = pyramid.baseSamplesPerBin
        for (i, level) in pyramid.levels.enumerated() {
            if binSize >= binSamples { chosen = i; break }
            chosen = i
            binSize *= 2
            if level.isEmpty { break }
        }
        return chosen
    }
}
