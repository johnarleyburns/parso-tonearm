import AVFoundation
import Foundation

// MARK: - Gain smoothing

/// A one-pole smoothed gain (§35.4): `current` ramps toward `target` each
/// sample so fader, EQ and crossfader moves never click. Pure value; only the
/// render thread mutates it; the control side changes only the target via
/// `RTCommand`s.
public struct SmoothedGain: Sendable {
    public var target: Float
    public private(set) var current: Float
    private let coefficient: Float

    public init(value: Float = 1, timeConstantMillis: Float = 5, sampleRate: Double = 48_000) {
        current = value
        target = value
        coefficient = 1 - exp(-1 / (Float(sampleRate) * timeConstantMillis / 1000))
    }

    /// Advance one sample toward the target and return the current gain.
    @inline(__always)
    public mutating func next() -> Float {
        current += (target - current) * coefficient
        return current
    }
}

// MARK: - 3-band isolator EQ (§35.2)

/// A direct-form-1 biquad (RBJ cookbook conventions). Coefficients are the
/// prewarped bilinear forms, normalized so the transfer function is
/// `y = b0·x + b1·x1 + b2·x2 − a1·y1 − a2·y2`. Pure value; the per-channel
/// state lives inside the `LinkwitzRiley` that owns it.
public struct Biquad: Sendable {
    public var b0: Float, b1: Float, b2: Float
    public var a1: Float, a2: Float
    private var x1: Float = 0, x2: Float = 0
    private var y1: Float = 0, y2: Float = 0

    public init(b0: Float, b1: Float, b2: Float, a1: Float, a2: Float) {
        self.b0 = b0
        self.b1 = b1
        self.b2 = b2
        self.a1 = a1
        self.a2 = a2
    }

    @inline(__always)
    public mutating func process(_ x: Float) -> Float {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1
        x1 = x
        y2 = y1
        y1 = y
        return y
    }
}

/// A Linkwitz–Riley 2-stage crossover (LR4, 24 dB/oct) splitting the input
/// into complementary low and high bands whose sum is magnitude-flat at every
/// frequency (§35.2). Two cascaded 2nd-order Butterworth biquads per band
/// (each −6 dB at the split) sum to an exact all-pass, so unity EQ gain is a
/// transparent pass-through. Coefficients are precomputed for the given
/// sample rate; the render thread only recurses.
public struct LinkwitzRiley: Sendable {
    public let splitHz: Float
    public let sampleRate: Double
    private var lpStage1: Biquad
    private var lpStage2: Biquad
    private var hpStage1: Biquad
    private var hpStage2: Biquad

    public init(splitHz: Float, sampleRate: Double) {
        self.splitHz = splitHz
        self.sampleRate = sampleRate
        let w0 = 2 * Float.pi * splitHz / Float(sampleRate)
        let alpha = sin(w0) / sqrt(2) // Q = 1/√2 → Butterworth
        let cosw = cos(w0)
        let a0 = 1 + alpha
        let a1 = (-2 * cosw) / a0
        let a2 = (1 - alpha) / a0
        let lpB0 = (1 - cosw) / (2 * a0)
        let lpB1 = (1 - cosw) / a0
        let hpB0 = (1 + cosw) / (2 * a0)
        let hpB1 = -(1 + cosw) / a0
        lpStage1 = Biquad(b0: lpB0, b1: lpB1, b2: lpB0, a1: a1, a2: a2)
        lpStage2 = Biquad(b0: lpB0, b1: lpB1, b2: lpB0, a1: a1, a2: a2)
        hpStage1 = Biquad(b0: hpB0, b1: hpB1, b2: hpB0, a1: a1, a2: a2)
        hpStage2 = Biquad(b0: hpB0, b1: hpB1, b2: hpB0, a1: a1, a2: a2)
    }

    /// Split one sample into complementary low and high bands.
    @inline(__always)
    public mutating func split(_ x: Float) -> (lo: Float, hi: Float) {
        let l1 = lpStage1.process(x)
        let h1 = hpStage1.process(x)
        return (lpStage2.process(l1), hpStage2.process(h1))
    }
}

/// The channel's 3-band isolator EQ (§35.2): a low/mid crossover at 200 Hz
/// and a mid/high crossover at 2 kHz; each band scaled by a smoothed gain and
/// summed. Unity at 12 o'clock is transparent; the kill end stop is −∞ dB; the
/// boost end stop is +6 dB.
public struct ThreeBandEQ: Sendable {
    public static let lowMidHz: Float = 200
    public static let midHighHz: Float = 2_000

    private var lowMid: LinkwitzRiley
    private var midHigh: LinkwitzRiley
    private var gLow = SmoothedGain()
    private var gMid = SmoothedGain()
    private var gHigh = SmoothedGain()

    public init(sampleRate: Double) {
        lowMid = LinkwitzRiley(splitHz: Self.lowMidHz, sampleRate: sampleRate)
        midHigh = LinkwitzRiley(splitHz: Self.midHighHz, sampleRate: sampleRate)
        gLow = SmoothedGain(sampleRate: sampleRate)
        gMid = SmoothedGain(sampleRate: sampleRate)
        gHigh = SmoothedGain(sampleRate: sampleRate)
    }

    /// Set the per-band linear gains; the one-pole ramps smooth the move.
    public mutating func setGains(low: Float, mid: Float, high: Float) {
        gLow.target = low
        gMid.target = mid
        gHigh.target = high
    }

    @inline(__always)
    public mutating func process(_ x: Float) -> Float {
        let (lo, hiA) = lowMid.split(x)
        let (mid, hi) = midHigh.split(hiA)
        return lo * gLow.next() + mid * gMid.next() + hi * gHigh.next()
    }

    /// Map an isolator-EQ knob position (−1 kill … 0 unity … +1 max boost) to a
    /// linear gain (§35.2): the positive half is a +6 dB boost at full travel;
    /// the negative half falls to a −40 dB floor and kills at the end stop.
    public static func knobToGain(_ knob: Float) -> Float {
        let x = min(max(knob, -1), 1)
        if x >= 0 { return powf(10, x * 6 / 20) }
        if x <= -0.95 { return 0 }
        return powf(10, x * 40 / 20)
    }
}

// MARK: - Sweep filter (§35.3)

/// The channel's color filter: a resonant state-variable filter whose single
/// knob sweeps low-pass (knob < 0) through a centre detent where the filter is
/// **hard-bypassed** (knob ≈ 0) to high-pass (knob > 0). Just off centre the
/// cutoff sits near-transparent (12 kHz); full travel drops it to 300 Hz.
public struct SweepFilter: Sendable {
    /// Below this |knob| the filter is a hard bypass.
    public static let centerBypass: Float = 0.001
    public static let maxCutoffHz: Float = 12_000
    public static let minCutoffHz: Float = 300
    /// The high-pass side's transparent end: below the audible band, so a knob
    /// just off centre colours the sound rather than emptying it.
    public static let hpMinCutoffHz: Float = 20
    /// The high-pass side's far end. Held to an eighth of the sample rate: this
    /// is a Chamberlin state-variable filter, whose coefficient goes unstable
    /// as the cutoff approaches a sixth of the sample rate — a corner up at
    /// 12 kHz does not filter, it produces NaN.
    public static let hpMaxCutoffHz: Float = 6_000

    public let sampleRate: Double
    public private(set) var knob: Float = 0
    private var freq: Float
    private let q: Float = 1.0
    private var low: Float = 0
    private var band: Float = 0
    private var bypassed = true

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
        freq = Self.freqCoefficient(cutoffHz: Self.maxCutoffHz, sampleRate: sampleRate)
    }

    /// The filter cutoff for a knob position (−1 … 1).
    ///
    /// **The two sides sweep in opposite directions**, because "transparent"
    /// means opposite things for a low-pass and a high-pass. Turning left, the
    /// low-pass corner falls from 12 kHz (everything through) to 300 Hz (dark);
    /// turning right, the high-pass corner *rises* from 20 Hz (everything
    /// through) to 6 kHz (only the top left). Both therefore start neutral at
    /// the centre detent and reach maximum effect at the extremes, which is what
    /// §35.3's "low-pass left, neutral centre, high-pass right" describes and
    /// what a hand trained on any club mixer expects.
    ///
    /// Sharing one curve across both sides — as this did — inverts the
    /// high-pass: a knob nudged just off centre jumped to a 12 kHz high-pass,
    /// removing very nearly everything, and sweeping further *restored* content
    /// until full-right was the mildest setting on that side.
    public static func cutoffHz(forKnob knob: Float) -> Float {
        let k = min(max(knob, -1), 1)
        let magnitude = min(abs(k), 1)
        guard magnitude > centerBypass else { return k < 0 ? maxCutoffHz : hpMinCutoffHz }
        if k < 0 {
            return maxCutoffHz * powf(minCutoffHz / maxCutoffHz, magnitude)
        }
        return hpMinCutoffHz * powf(hpMaxCutoffHz / hpMinCutoffHz, magnitude)
    }

    private static func freqCoefficient(cutoffHz: Float, sampleRate: Double) -> Float {
        2 * sin(Float.pi * cutoffHz / Float(sampleRate))
    }

    public mutating func setKnob(_ knob: Float) {
        self.knob = knob
        if abs(knob) < Self.centerBypass {
            low = 0
            band = 0
            bypassed = true
        } else {
            bypassed = false
            freq = Self.freqCoefficient(cutoffHz: Self.cutoffHz(forKnob: knob),
                                        sampleRate: sampleRate)
        }
    }

    @inline(__always)
    public mutating func process(_ x: Float) -> Float {
        if bypassed { return x }
        low += freq * band
        let high = x - low - q * band
        band += freq * high
        return knob < 0 ? low : high
    }
}

// MARK: - Crossfader (§35.4)

/// The crossfader blend curve (§35.4).
public enum CrossfaderCurve: Float, Sendable, CaseIterable {
    /// Equal-power blend: `gA² + gB² == 1` at every position.
    case constantPower = 0
    /// Equal-amplitude blend: `gA + gB == 1`.
    case linear = 1
    /// Hard cut with a small overlap for scratch-style chops.
    case sharp = 2
}

/// The two channel gains for a crossfader position `x ∈ [−1, 1]` (§35.4):
/// `x = −1` is deck A full, `x = +1` is deck B full.
public func crossfaderGains(_ x: Float, _ curve: CrossfaderCurve) -> (a: Float, b: Float) {
    switch curve {
    case .constantPower:
        let t = (x + 1) * 0.25 * .pi // x∈[-1,1] → [0, π/2]
        return (cos(t), sin(t))
    case .linear:
        return ((1 - x) * 0.5, (x + 1) * 0.5)
    case .sharp:
        return (x < 0.4 ? 1 : 0, x > -0.4 ? 1 : 0) // hard cut with small overlap
    }
}

// MARK: - Master limiter (§35.5)

/// The master brickwall limiter (§35.5, FR-ENG-7): a lookahead limiter with a
/// delay line and soft-knee gain reduction that **provably never lets the
/// output exceed `ceiling`** in magnitude.
///
/// Each output sample is delayed `lookaheadFrames` and scaled by a gain
/// computed from the peak of the current lookahead window, so gain reduction
/// starts before a transient reaches the output. Attack is instant (the gain
/// snaps down the moment the window requires it); release ramps slowly, so a
/// loud passage pumps gently instead of clicking. The soft knee interpolates
/// the gain in dB between `kneeStart` and `kneeEnd`, keeping `gain ≤
/// ceiling/peak` everywhere, which makes the ceiling bound exact. All state
/// lives in a pre-allocated delay line — the render thread never allocates.
public final class LookaheadLimiter: @unchecked Sendable {
    public let ceiling: Float
    public let lookaheadFrames: Int
    public let sampleRate: Double

    private let delayLine: UnsafeMutablePointer<Float>
    private let delayLength: Int
    private var writeIndex = 0
    private var gain: Float = 1
    private let releaseCoefficient: Float
    private let kneeStart: Float
    private let kneeEnd: Float
    private let kneeGainDb: Float

    public init(ceiling: Float = 0.95, lookaheadFrames: Int, sampleRate: Double = 48_000,
                releaseMillis: Float = 50, kneeDb: Float = 3) {
        precondition(ceiling > 0 && ceiling <= 1, "limiter ceiling must be within (0, 1]")
        self.ceiling = ceiling
        self.lookaheadFrames = lookaheadFrames
        self.sampleRate = sampleRate
        delayLength = lookaheadFrames + 1
        delayLine = .allocate(capacity: delayLength)
        delayLine.initialize(repeating: 0, count: delayLength)
        releaseCoefficient = 1 - exp(-1 / (Float(sampleRate) * releaseMillis / 1000))
        kneeGainDb = kneeDb
        kneeStart = ceiling * powf(10, -kneeDb / 20)
        kneeEnd = ceiling * powf(10, kneeDb / 20)
    }

    deinit {
        delayLine.deinitialize(count: delayLength)
        delayLine.deallocate()
    }

    /// Process one sample. The output lags the input by `lookaheadFrames` and
    /// never exceeds `ceiling` in magnitude.
    @inline(__always)
    public func process(_ x: Float) -> Float {
        delayLine[writeIndex] = x
        writeIndex = (writeIndex + 1) % delayLength

        var peak: Float = 0
        for i in 0..<delayLength {
            peak = max(peak, abs(delayLine[i]))
        }

        let required = requiredGain(forPeak: peak)
        if required < gain {
            gain = required
        } else {
            gain += (required - gain) * releaseCoefficient
        }

        return delayLine[writeIndex] * gain
    }

    /// The gain that keeps the whole current window at-or-under the ceiling:
    /// unity below the knee, a dB interpolation across the knee, and the hard
    /// `ceiling/peak` ratio above it.
    private func requiredGain(forPeak peak: Float) -> Float {
        if peak <= kneeStart { return 1 }
        if peak >= kneeEnd { return ceiling / peak }
        let t = (peak - kneeStart) / (kneeEnd - kneeStart)
        return powf(10, -(kneeGainDb * t) / 20)
    }
}

// MARK: - Graph wiring

/// The per-deck mixer chain (§35.1): EQ → filter → channel fader → **echo
/// send** → crossfader gain, one instance per output channel (each channel
/// carries its own filter and echo state). Pure value; only the render thread
/// mutates it; the control side changes targets through
/// `DeckState.apply`/`setCrossfaderGain`.
///
/// The echo sits **post-fader, pre-crossfader** (§35A.1, normative FR-TRANS-4):
/// an echo used as a transition must keep sounding after its source is removed,
/// so the tail survives a channel-fader cut while the incoming channel stays
/// dry. This is the whole design — a pre-fader echo dies with the fader and
/// Echo Out collapses into Fader Cut.
///
/// The chain is transparent until a mixer control is touched: the EQ is
/// bypassed until the first `setEQ`, the filter at its centre detent, the
/// fader at unity, the echo dry until enabled, and the crossfader until
/// positioned. An untouched deck is therefore a bit-exact pass-through, which
/// keeps the deck reader's frame-exactness assertions valid while the mixer is
/// in the path (§35.1).
struct DeckMixer {
    var eq: ThreeBandEQ
    /// True once a `setEQ` has armed the chain — the LR4's unity sum is an
    /// all-pass, so a neutral EQ is a hard bypass rather than a phase shift.
    var eqEngaged = false
    var filter: SweepFilter
    var fader: SmoothedGain
    /// The §35A post-fader echo send — one line per channel.
    var echo: BeatEchoLine
    var crossfaderGain: SmoothedGain

    init(sampleRate: Double, echoCapacity: Int, echoCrossfadeFrames: Int) {
        eq = ThreeBandEQ(sampleRate: sampleRate)
        filter = SweepFilter(sampleRate: sampleRate)
        fader = SmoothedGain(sampleRate: sampleRate)
        echo = BeatEchoLine(capacity: echoCapacity, sampleRate: sampleRate,
                            crossfadeFrames: echoCrossfadeFrames)
        crossfaderGain = SmoothedGain(sampleRate: sampleRate)
    }

    @inline(__always)
    mutating func process(_ x: Float) -> Float {
        var s = eqEngaged ? eq.process(x) : x
        s = filter.process(s)
        s = fader.next() * s
        s = echo.process(s)
        s = crossfaderGain.next() * s
        return s
    }
}

/// The master stage (§35.5): the crossfader position/curve and the master
/// limiter over the summed deck output. Created on the control side; the
/// render thread reads the position once per callback and runs the limiter.
///
/// The crossfader is **idle until the first `setCrossfader`** — until then
/// both decks pass at unity, which keeps an untouched two-deck mix at full
/// level. The limiter is absent (passthrough) when no ceiling is configured;
/// the offline deck-reader harness runs without it so its assertions stay
/// frame-exact, and the mixer tests configure it explicitly.
final class MasterStage: @unchecked Sendable {
    var crossfaderPosition: Float = 0
    var crossfaderCurve: CrossfaderCurve = .constantPower
    var crossfaderEngaged = false
    let limiters: [LookaheadLimiter]

    init(channelCount: Int, sampleRate: Double, ceiling: Float?, lookaheadFrames: Int) {
        if let ceiling {
            limiters = (0..<channelCount).map { _ in
                LookaheadLimiter(ceiling: ceiling, lookaheadFrames: lookaheadFrames,
                                 sampleRate: sampleRate)
            }
        } else {
            limiters = []
        }
    }

    /// The per-deck crossfader gains for the current position/curve, or unity
    /// for both decks while the crossfader is idle.
    func gains() -> (a: Float, b: Float) {
        guard crossfaderEngaged else { return (1, 1) }
        return crossfaderGains(crossfaderPosition, crossfaderCurve)
    }

    func apply(_ command: RTCommand) {
        switch command.tag {
        case .setCrossfader:
            crossfaderPosition = command.f0
            crossfaderCurve = CrossfaderCurve(rawValue: command.f1) ?? .constantPower
            crossfaderEngaged = true
        default:
            break
        }
    }

    /// Run the master limiter over the summed output in place.
    func limit(into list: UnsafeMutableAudioBufferListPointer, frames: Int) {
        guard !limiters.isEmpty else { return }
        for (c, m) in list.enumerated() where c < limiters.count {
            guard let data = m.mData else { continue }
            let p = data.assumingMemoryBound(to: Float.self)
            for i in 0..<frames {
                p[i] = limiters[c].process(p[i])
            }
        }
    }
}
