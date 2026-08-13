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

    /// Samples covered by one bin at `level` (level 0 = `baseSamplesPerBin`,
    /// each level doubles). The renderer's zoom→level mapping (§26A.7).
    public func samplesPerBin(at level: Int) -> Double {
        Double(max(1, baseSamplesPerBin)) * pow(2.0, Double(max(0, level)))
    }
}

/// The §26A.2 band splitter: the **same 200 Hz / 2 kHz crossovers as the
/// mixer's three-band EQ** (§35.2), run statefully over a signal so the
/// pyramid's per-bin low/mid/high RMS is a genuine filtered measurement. A
/// waveform whose colours do not correspond to the EQ bands teaches the wrong
/// instrument (§26A.2) — this is the source of FR-WAVE-2's colours.
public struct WaveformBandSplit: Sendable {
    public static let lowMidHz: Float = ThreeBandEQ.lowMidHz
    public static let midHighHz: Float = ThreeBandEQ.midHighHz

    private var lowMid: LinkwitzRiley
    private var midHigh: LinkwitzRiley

    public init(sampleRate: Double) {
        lowMid = LinkwitzRiley(splitHz: Self.lowMidHz, sampleRate: sampleRate)
        midHigh = LinkwitzRiley(splitHz: Self.midHighHz, sampleRate: sampleRate)
    }

    /// Split one sample into the three complementary bands. The bands sum
    /// exactly to the input (LR4 is an all-pass splitter), so low + mid + high
    /// reconstruct the signal.
    @inline(__always)
    public mutating func split(_ x: Float) -> (lo: Float, mid: Float, hi: Float) {
        let (lo, hiA) = lowMid.split(x)
        let (mid, hi) = midHigh.split(hiA)
        return (lo, mid, hi)
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

        // §26A.2: the band split shares the mixer's 200 Hz / 2 kHz LR4
        // crossovers (§35.2), run **statefully over the whole signal** so a
        // bin's low/mid/high RMS is a genuine filtered measurement — the
        // waveform's colours ARE the EQ bands. The old time-domain estimate
        // mis-classified mid-band energy; FR-WAVE-2 has no other source.
        var bandBuffers: (low: [Float], mid: [Float], high: [Float])?
        if config.bandSplit {
            var splitter = WaveformBandSplit(sampleRate: sampleRate)
            var low = [Float](repeating: 0, count: mono.count)
            var mid = [Float](repeating: 0, count: mono.count)
            var high = [Float](repeating: 0, count: mono.count)
            for i in 0..<mono.count {
                let (lo, mi, hi) = splitter.split(mono[i])
                low[i] = lo
                mid[i] = mi
                high[i] = hi
            }
            bandBuffers = (low, mid, high)
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
            if let bands = bandBuffers {
                bandRMS = [rmsOfBand(bands.low, start, end),
                           rmsOfBand(bands.mid, start, end),
                           rmsOfBand(bands.high, start, end)]
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

    /// RMS over a band-filtered buffer slice — the per-bin band measurement
    /// (§26A.2). The band buffers are precomputed statefully over the whole
    /// signal, so a bin's values are genuine filtered energy, not an estimate.
    static func rmsOfBand(_ buffer: [Float], _ start: Int, _ end: Int) -> Float {
        let count = end - start
        guard count > 0 else { return 0 }
        return buffer.withUnsafeBufferPointer { bp in
            var rms: Float = 0
            vDSP_rmsqv(bp.baseAddress!.advanced(by: start), 1, &rms, vDSP_Length(count))
            return rms
        }
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
