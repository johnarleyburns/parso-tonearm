import CoreGraphics
import Foundation

/// The thermal ladder for the **waveform display** (§26A.7). Distinct from the
/// analysis governor (`ThermalGovernor`, §43.7): this is purely "how much
/// detail does the DISPLAY draw" — one pyramid level coarser and halved ribbon
/// label density at `.serious`, never a dropped frame and never audio impact.
public enum WaveformThermal: Int, Sendable, Equatable {
    case nominal = 0
    case fair = 1
    case serious = 2
    case critical = 3

    /// §26A.7: at `.serious` (and `.critical`, which inherits the same shed)
    /// the renderer steps one pyramid level coarser and halves label density.
    public var degradesRendering: Bool { rawValue >= WaveformThermal.serious.rawValue }

    /// The device's current thermal state, mapped to the display ladder.
    public static var current: WaveformThermal {
        switch ProcessInfo.processInfo.thermalState {
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        case .nominal: return .nominal
        @unknown default: return .nominal
        }
    }
}

/// The §26A.2 frequency colouring. Each pyramid bin carries low/mid/high RMS
/// (§26.1 `bandSplit`, measured with the **same 200 Hz / 2 kHz crossovers as
/// the mixer's three-band EQ**, §35.2) and is drawn as three stacked
/// contributions normalised to the bin's total energy:
///
/// | Band | Split | Reads as |
/// |---|---|---|
/// | low  | < 200 Hz | blue/cyan — the band Bass Swap operates on |
/// | mid  | 200 Hz – 2 kHz | amber/orange — body, vocal, chords |
/// | high | > 2 kHz | pale/white — hats, air, transient detail |
///
/// Pure so AT-WAVE-2 (a bass/mid/treble-only signal puts its energy in the
/// expected band) is a model test, not a snapshot test.
public enum WaveformBand: Int, CaseIterable, Sendable {
    case low = 0
    case mid = 1
    case high = 2

    /// The index into `WaveformBin.bandRMS` (§26.1 `bandSplit` order).
    public var bandRMSIndex: Int { rawValue }

    /// The band carrying the most energy in a bin — the colour the bin reads
    /// as (§26A.2). `nil` when the bin carries no band data.
    public static func dominantBand(rms: [Float]) -> WaveformBand? {
        guard rms.count >= 3 else { return nil }
        var best = 0
        var bestValue = rms[0]
        for i in 1..<3 where rms[i] > bestValue {
            best = i
            bestValue = rms[i]
        }
        return WaveformBand(rawValue: best)
    }

    /// The three stacked contributions of a bin, normalised to the bin's total
    /// energy (§26A.2). A silent bin is all zeros — never NaN.
    public static func contributions(rms: [Float]) -> [Float] {
        guard rms.count >= 3 else { return [0, 0, 0] }
        let total = rms[0] + rms[1] + rms[2]
        guard total > 0 else { return [0, 0, 0] }
        return [rms[0] / total, rms[1] / total, rms[2] / total]
    }
}

/// §26A.7 pyramid-level selection — the renderer picks the **coarsest** level
/// whose bin width is ≤ 1 device pixel (never a finer one) and steps **one
/// level coarser** at `.serious`/`.critical`. Pure so AT-WAVE-7 is a model
/// test: given a zoom (`samplesPerPoint`) and a thermal state, the chosen
/// level is deterministic.
public enum WaveformLevelSelector {

    /// `samplesPerPoint` is the current zoom: samples per device pixel. The
    /// level chosen is the largest bin size that still fits within one pixel.
    public static func level(samplesPerPoint: Double,
                             thermal: WaveformThermal,
                             pyramid: WaveformPyramid) -> Int {
        guard !pyramid.levels.isEmpty else { return 0 }
        var chosen = 0
        var binSize = Double(pyramid.baseSamplesPerBin)
        for (index, level) in pyramid.levels.enumerated() {
            if binSize <= samplesPerPoint { chosen = index }
            binSize *= 2
            if level.isEmpty { break }
        }
        if thermal.degradesRendering {
            chosen = min(chosen + 1, pyramid.levels.count - 1)
        }
        return chosen
    }
}

/// Sample ↔ point geometry for the waveform canvases (§26A.6 — markers are
/// positioned from sample values, never from interpolated pixel time, so a
/// marker can never drift against the grid at high zoom). Pure so AT-WAVE-6
/// is a model test at every zoom level.
public enum WaveformGeometry {

    public static func x(sample: Int64,
                         windowStart: Double,
                         samplesPerPoint: Double) -> CGFloat {
        CGFloat((Double(sample) - windowStart) / max(samplesPerPoint, 1))
    }

    public static func x(sample: Double,
                         windowStart: Double,
                         samplesPerPoint: Double) -> CGFloat {
        CGFloat((sample - windowStart) / max(samplesPerPoint, 1))
    }

    public static func sample(atX x: CGFloat,
                              windowStart: Double,
                              samplesPerPoint: Double) -> Int64 {
        Int64((Double(x) * max(samplesPerPoint, 1)) + windowStart)
    }
}
