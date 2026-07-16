import Foundation

/// A single biquad peaking-EQ section (Direct Form I), matched to one ISO band.
/// Coefficients follow the Audio EQ Cookbook (RBJ) peaking filter.
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

/// A 10-band graphic EQ: a cascade of peaking biquads at the ISO center
/// frequencies. When every band is at 0 dB (or the EQ is bypassed) the output is
/// bit-transparent — the null test in `EQTests` guards this.
public struct EQEngine {
    /// ISO 10-band centers (Hz), matching the mockup (screen 4).
    public static let bandFrequencies: [Double] = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    public static let bandCount = 10
    public static let defaultQ = 1.41

    public private(set) var gains: [Double]
    private var biquads: [Biquad]
    private let sampleRate: Double
    public var bypassed: Bool

    public init(sampleRate: Double = 48000, gains: [Double] = Array(repeating: 0, count: EQEngine.bandCount),
         bypassed: Bool = false) {
        self.sampleRate = sampleRate
        self.gains = gains
        self.bypassed = bypassed
        self.biquads = EQEngine.makeBiquads(gains: gains, sampleRate: sampleRate)
    }

    private static func makeBiquads(gains: [Double], sampleRate: Double) -> [Biquad] {
        zip(bandFrequencies, gains).map { freq, gain in
            if gain == 0 { return .identity }
            return .peaking(frequency: freq, gainDB: gain, q: defaultQ, sampleRate: sampleRate)
        }
    }

    public mutating func setGains(_ newGains: [Double]) {
        guard newGains.count == Self.bandCount else { return }
        gains = newGains
        biquads = Self.makeBiquads(gains: gains, sampleRate: sampleRate)
    }

    public mutating func reset() {
        for i in biquads.indices { biquads[i].reset() }
    }

    /// True when the EQ makes no change (bypassed or perfectly flat).
    public var isTransparent: Bool {
        bypassed || gains.allSatisfy { $0 == 0 }
    }

    /// Processes one sample through the cascade. When transparent, returns the
    /// input untouched (bit-exact) so bypass is provably lossless.
    public mutating func process(_ sample: Double, channel: Int) -> Double {
        guard !isTransparent else { return sample }
        var s = sample
        for i in biquads.indices {
            s = biquads[i].process(s, channel: channel)
        }
        return s
    }

    /// Offline render of a buffer (per channel), for testing / non-realtime use.
    public mutating func render(_ input: [Double], channel: Int = 0) -> [Double] {
        input.map { process($0, channel: channel) }
    }
}
