import Foundation
import ParsoAudioPlayback

/// The 10-band graphic EQ is now shared: `parso-audio-engine`'s `GraphicEQ`
/// (`ParsoAudioPlayback`) is the RBJ peaking cascade both apps grew independently
/// (parso-audio-engine/docs/UNIFICATION_PLAN.md §3). Tonearm's default Q (1.41)
/// is `GraphicEQ.defaultQ`, so the sound is unchanged. The parametric `Biquad`
/// below and the Pro-Audio cascade in `ProAudioTools` stay app-side — only the
/// graphic EQ was duplicated.
public typealias EQEngine = GraphicEQ

public extension GraphicEQ {
    /// Historical Tonearm spelling of `isoBandFrequencies` (used by `EQView`).
    static var bandFrequencies: [Double] { isoBandFrequencies }
}

/// A single biquad section (Direct Form I) for the Pro-Audio parametric cascade,
/// following the Audio EQ Cookbook (RBJ). Extended in `ProAudioTools` with the
/// shelf/notch/pass filter types.
public struct Biquad {
    public var b0: Double = 1, b1: Double = 0, b2: Double = 0
    public var a1: Double = 0, a2: Double = 0

    // Per-channel state (up to 2 channels).
    private var x1 = [Double](repeating: 0, count: 2)
    private var x2 = [Double](repeating: 0, count: 2)
    private var y1 = [Double](repeating: 0, count: 2)
    private var y2 = [Double](repeating: 0, count: 2)

    /// Peaking EQ coefficients for a center frequency, gain (dB), Q and rate.
    public static func peaking(frequency: Double, gainDB: Double, q: Double, sampleRate: Double) -> Biquad {
        var bq = Biquad()
        let a = pow(10, gainDB / 40)
        let w0 = 2 * Double.pi * frequency / sampleRate
        let cosw0 = cos(w0)
        let alpha = sin(w0) / (2 * q)

        let b0 = 1 + alpha * a
        let b1 = -2 * cosw0
        let b2 = 1 - alpha * a
        let a0 = 1 + alpha / a
        let a1 = -2 * cosw0
        let a2 = 1 - alpha / a

        bq.b0 = b0 / a0
        bq.b1 = b1 / a0
        bq.b2 = b2 / a0
        bq.a1 = a1 / a0
        bq.a2 = a2 / a0
        return bq
    }

    /// Identity (unity) section — passes samples through unchanged.
    public static var identity: Biquad { Biquad() }

    public mutating func reset() {
        x1 = [0, 0]; x2 = [0, 0]; y1 = [0, 0]; y2 = [0, 0]
    }

    public mutating func process(_ x: Double, channel: Int) -> Double {
        let c = min(channel, 1)
        let y = b0 * x + b1 * x1[c] + b2 * x2[c] - a1 * y1[c] - a2 * y2[c]
        x2[c] = x1[c]; x1[c] = x
        y2[c] = y1[c]; y1[c] = y
        return y
    }
}

