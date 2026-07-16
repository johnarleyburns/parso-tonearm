import Foundation

/// User-facing Pro Audio state (parametric EQ, crossfeed, convolution, bit-perfect
/// request). A pure value: no UI frameworks, no AVFoundation, no I/O. The realtime
/// DSP (`ProAudioKernel`) and the paywall status label (`BitPerfectOutputPlan`) are
/// both derived from this single source of truth so the sliders actually drive the
/// audio instead of a status string.
public struct ProAudioSettings: Equatable, Codable {
    /// Parametric EQ cascade applied after the 10-band graphic EQ.
    public var parametricBands: [ParametricEQBand]
    /// Symmetric crossfeed amount in dB (the mixed-in opposite channel level).
    public var crossfeedDB: Double
    public var crossfeedEnabled: Bool
    /// Number of taps for the (box-filter) convolution stage. 0 == off.
    public var convolutionTaps: Int
    /// Whether the user has requested bit-perfect output. Honoured only when every
    /// stage is transparent and the hardware rate matches the source.
    public var bitPerfectRequested: Bool

    public static let `default` = ProAudioSettings(
        parametricBands: [],
        crossfeedDB: -12,
        crossfeedEnabled: false,
        convolutionTaps: 0,
        bitPerfectRequested: true
    )

    public static let convolutionSampleRate: Double = 48_000
    public static let maxConvolutionTaps = 1_024

    /// A normalized box-filter impulse response of `convolutionTaps` taps. A crude
    /// but audible low-pass so moving the control provably changes the sound.
    public var convolutionImpulseResponse: [Double] {
        guard convolutionTaps > 0 else { return [] }
        let count = min(convolutionTaps, Self.maxConvolutionTaps)
        return Array(repeating: 1.0 / Double(count), count: count)
    }

    public func convolutionPlan() -> ConvolutionPlan {
        ConvolutionPlan.make(
            impulseResponse: convolutionImpulseResponse,
            maxTaps: min(convolutionTaps, Self.maxConvolutionTaps),
            blockSize: 512,
            normalize: false
        )
    }

    public var crossfeedMatrix: CrossfeedMatrix {
        crossfeedEnabled ? CrossfeedMatrix.symmetric(crossfeedDB: crossfeedDB) : .identity
    }

    public func eqCascade(sampleRate: Double = ProAudioSettings.convolutionSampleRate) -> ParametricEQCascade {
        ParametricEQCascade(bands: parametricBands, sampleRate: sampleRate)
    }

    /// True when every stage passes samples through unchanged.
    public var isTransparent: Bool {
        eqCascade().isTransparent
            && crossfeedMatrix.isTransparent
            && convolutionPlan().isTransparent
    }

    /// Builds the paywall-facing plan from the REAL hardware/source rates, never
    /// from view `@State`.
    public func bitPerfectPlan(hardwareSampleRate: Double,
                        sourceSampleRate: Double,
                        replayGainActive: Bool) -> BitPerfectOutputPlan {
        let matches = sourceSampleRate <= 0
            || abs(hardwareSampleRate - sourceSampleRate) < 0.5
        return BitPerfectOutputPlan(
            requested: bitPerfectRequested,
            sampleRateMatchesHardware: matches,
            eqCascade: eqCascade(),
            crossfeed: crossfeedMatrix,
            convolution: convolutionPlan(),
            replayGainEnabled: replayGainActive
        )
    }
}

/// Thin UserDefaults adapter for Pro Audio state. Persistence stays here; product
/// rules stay in the pure `ProAudioSettings` value.
public enum ProAudioSettingsPersistence {
    private static let settingsKey = "proaudio.settings.payload"

    public static func load(defaults: UserDefaults = .standard) -> ProAudioSettings {
        guard let data = defaults.data(forKey: settingsKey),
              let settings = try? JSONDecoder().decode(ProAudioSettings.self, from: data) else {
            return .default
        }
        return settings
    }

    public static func save(_ settings: ProAudioSettings, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: settingsKey)
    }
}

/// Realtime Pro Audio DSP kernel. Pure (Foundation only) so it can be unit-tested
/// offline and driven from the audio thread without allocation. All heap sizing
/// (biquad cascades, FIR ring buffers) happens in `init`; `process*` runs pure
/// arithmetic on pre-allocated storage.
///
/// Signal chain (canonical order):
/// 10-band EQ -> parametric cascade -> convolution -> crossfeed -> ReplayGain.
/// ReplayGain stays last so a fully-transparent chain nulls bit-exactly.
public struct ProAudioKernel {
    private var eq: EQEngine
    private var parametric: [Biquad]
    private let convTaps: [Double]
    private var convHistory: [[Double]]
    private var convIndex: [Int]
    private let crossfeed: CrossfeedMatrix
    public var replayGain: Double

    /// True when nothing in the chain (including ReplayGain) alters the signal.
    public let isTransparent: Bool

    public init(eqGains: [Double],
         eqBypassed: Bool,
         settings: ProAudioSettings,
         replayGain: Double,
         sampleRate: Double = ProAudioSettings.convolutionSampleRate) {
        self.eq = EQEngine(sampleRate: sampleRate, gains: eqGains, bypassed: eqBypassed)
        let cascade = ProAudioSettings(
            parametricBands: settings.parametricBands,
            crossfeedDB: settings.crossfeedDB,
            crossfeedEnabled: settings.crossfeedEnabled,
            convolutionTaps: settings.convolutionTaps,
            bitPerfectRequested: settings.bitPerfectRequested
        ).eqCascade(sampleRate: sampleRate)
        self.parametric = cascade.coefficients.map { Biquad(coefficients: $0) }
        let plan = settings.convolutionPlan()
        self.convTaps = plan.isTransparent ? [] : plan.taps
        let historySize = max(self.convTaps.count, 1)
        self.convHistory = [[Double](repeating: 0, count: historySize),
                            [Double](repeating: 0, count: historySize)]
        self.convIndex = [0, 0]
        self.crossfeed = settings.crossfeedMatrix
        self.replayGain = replayGain

        self.isTransparent = eq.isTransparent
            && parametric.isEmpty
            && convTaps.isEmpty
            && crossfeed.isTransparent
            && replayGain == 1
    }

    public mutating func reset() {
        eq.reset()
        for i in parametric.indices { parametric[i].reset() }
        for c in convHistory.indices {
            for i in convHistory[c].indices { convHistory[c][i] = 0 }
            convIndex[c] = 0
        }
    }

    private mutating func perChannel(_ sample: Double, channel: Int) -> Double {
        var s = eq.process(sample, channel: channel)
        for i in parametric.indices {
            s = parametric[i].process(s, channel: channel)
        }
        if !convTaps.isEmpty {
            s = convolve(s, channel: channel)
        }
        return s
    }

    private mutating func convolve(_ sample: Double, channel: Int) -> Double {
        let n = convTaps.count
        let c = min(channel, 1)
        convHistory[c][convIndex[c]] = sample
        var acc = 0.0
        var idx = convIndex[c]
        for tap in 0..<n {
            acc += convTaps[tap] * convHistory[c][idx]
            idx -= 1
            if idx < 0 { idx = n - 1 }
        }
        convIndex[c] = (convIndex[c] + 1) % n
        return acc
    }

    /// Processes a stereo (or mono, when `stereo == false`) frame. Bit-exact
    /// passthrough when transparent.
    public mutating func processStereo(left: Double, right: Double, stereo: Bool) -> (left: Double, right: Double) {
        guard !isTransparent else { return (left, right) }
        var l = perChannel(left, channel: 0)
        var r = stereo ? perChannel(right, channel: 1) : right
        if stereo, !crossfeed.isTransparent {
            let mixed = crossfeed.apply(left: l, right: r)
            l = mixed.left
            r = mixed.right
        }
        if replayGain != 1 {
            l *= replayGain
            if stereo { r *= replayGain }
        }
        return (l, r)
    }

    /// Offline stereo render for tests.
    public mutating func renderStereo(_ frames: [(Double, Double)]) -> [(Double, Double)] {
        frames.map { frame in
            let out = processStereo(left: frame.0, right: frame.1, stereo: true)
            return (out.left, out.right)
        }
    }
}
