import Foundation

public enum BiquadFilterType: String, CaseIterable, Equatable, Codable {
    case peaking
    case lowShelf
    case highShelf
    case lowPass
    case highPass
    case notch

    public var usesGain: Bool {
        switch self {
        case .peaking, .lowShelf, .highShelf:
            return true
        case .lowPass, .highPass, .notch:
            return false
        }
    }
}

public struct BiquadCoefficients: Equatable {
    public var b0: Double
    public var b1: Double
    public var b2: Double
    public var a1: Double
    public var a2: Double

    public static let identity = BiquadCoefficients(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)

    public static func make(type: BiquadFilterType,
                     frequency: Double,
                     gainDB: Double = 0,
                     q: Double,
                     sampleRate: Double) -> BiquadCoefficients {
        let prepared = PreparedBiquadInput(
            type: type,
            frequency: frequency,
            gainDB: gainDB,
            q: q,
            sampleRate: sampleRate)
        if type.usesGain && prepared.gainDB == 0 { return .identity }

        switch type {
        case .peaking:
            return peaking(prepared)
        case .lowShelf:
            return lowShelf(prepared)
        case .highShelf:
            return highShelf(prepared)
        case .lowPass:
            return lowPass(prepared)
        case .highPass:
            return highPass(prepared)
        case .notch:
            return notch(prepared)
        }
    }

    public var isIdentity: Bool {
        self == .identity
    }

    public var isStable: Bool {
        abs(a2) < 1
            && 1 + a1 + a2 > 0
            && 1 - a1 + a2 > 0
    }

    public func magnitude(at frequency: Double, sampleRate: Double) -> Double {
        guard sampleRate > 0, frequency.isFinite else { return 0 }
        let omega = 2 * Double.pi * frequency / sampleRate
        let z1r = cos(omega)
        let z1i = -sin(omega)
        let z2r = cos(2 * omega)
        let z2i = -sin(2 * omega)
        let numerator = Complex(
            real: b0 + b1 * z1r + b2 * z2r,
            imaginary: b1 * z1i + b2 * z2i)
        let denominator = Complex(
            real: 1 + a1 * z1r + a2 * z2r,
            imaginary: a1 * z1i + a2 * z2i)
        guard denominator.magnitude > 0 else { return .infinity }
        return numerator.magnitude / denominator.magnitude
    }

    private static func peaking(_ input: PreparedBiquadInput) -> BiquadCoefficients {
        let a = pow(10, input.gainDB / 40)
        let alpha = sin(input.w0) / (2 * input.q)
        return normalized(
            b0: 1 + alpha * a,
            b1: -2 * input.cosw0,
            b2: 1 - alpha * a,
            a0: 1 + alpha / a,
            a1: -2 * input.cosw0,
            a2: 1 - alpha / a)
    }

    private static func lowShelf(_ input: PreparedBiquadInput) -> BiquadCoefficients {
        let a = pow(10, input.gainDB / 40)
        let alpha = shelfAlpha(input, amplitude: a)
        let beta = 2 * sqrt(a) * alpha
        return normalized(
            b0: a * ((a + 1) - (a - 1) * input.cosw0 + beta),
            b1: 2 * a * ((a - 1) - (a + 1) * input.cosw0),
            b2: a * ((a + 1) - (a - 1) * input.cosw0 - beta),
            a0: (a + 1) + (a - 1) * input.cosw0 + beta,
            a1: -2 * ((a - 1) + (a + 1) * input.cosw0),
            a2: (a + 1) + (a - 1) * input.cosw0 - beta)
    }

    private static func highShelf(_ input: PreparedBiquadInput) -> BiquadCoefficients {
        let a = pow(10, input.gainDB / 40)
        let alpha = shelfAlpha(input, amplitude: a)
        let beta = 2 * sqrt(a) * alpha
        return normalized(
            b0: a * ((a + 1) + (a - 1) * input.cosw0 + beta),
            b1: -2 * a * ((a - 1) + (a + 1) * input.cosw0),
            b2: a * ((a + 1) + (a - 1) * input.cosw0 - beta),
            a0: (a + 1) - (a - 1) * input.cosw0 + beta,
            a1: 2 * ((a - 1) - (a + 1) * input.cosw0),
            a2: (a + 1) - (a - 1) * input.cosw0 - beta)
    }

    private static func lowPass(_ input: PreparedBiquadInput) -> BiquadCoefficients {
        let alpha = sin(input.w0) / (2 * input.q)
        let oneMinusCos = 1 - input.cosw0
        return normalized(
            b0: oneMinusCos / 2,
            b1: oneMinusCos,
            b2: oneMinusCos / 2,
            a0: 1 + alpha,
            a1: -2 * input.cosw0,
            a2: 1 - alpha)
    }

    private static func highPass(_ input: PreparedBiquadInput) -> BiquadCoefficients {
        let alpha = sin(input.w0) / (2 * input.q)
        let onePlusCos = 1 + input.cosw0
        return normalized(
            b0: onePlusCos / 2,
            b1: -onePlusCos,
            b2: onePlusCos / 2,
            a0: 1 + alpha,
            a1: -2 * input.cosw0,
            a2: 1 - alpha)
    }

    private static func notch(_ input: PreparedBiquadInput) -> BiquadCoefficients {
        let alpha = sin(input.w0) / (2 * input.q)
        return normalized(
            b0: 1,
            b1: -2 * input.cosw0,
            b2: 1,
            a0: 1 + alpha,
            a1: -2 * input.cosw0,
            a2: 1 - alpha)
    }

    private static func shelfAlpha(_ input: PreparedBiquadInput, amplitude: Double) -> Double {
        let slope = min(max(input.q, 0.000_001), 1)
        let expression = max((amplitude + 1 / amplitude) * (1 / slope - 1) + 2, 0)
        return sin(input.w0) / 2 * sqrt(expression)
    }

    private static func normalized(b0: Double, b1: Double, b2: Double,
                                   a0: Double, a1: Double, a2: Double) -> BiquadCoefficients {
        guard a0.isFinite, abs(a0) > 0 else { return .identity }
        return BiquadCoefficients(
            b0: b0 / a0,
            b1: b1 / a0,
            b2: b2 / a0,
            a1: a1 / a0,
            a2: a2 / a0)
    }
}

public extension Biquad {
    init(coefficients: BiquadCoefficients) {
        self.init()
        b0 = coefficients.b0
        b1 = coefficients.b1
        b2 = coefficients.b2
        a1 = coefficients.a1
        a2 = coefficients.a2
    }

    var coefficients: BiquadCoefficients {
        BiquadCoefficients(b0: b0, b1: b1, b2: b2, a1: a1, a2: a2)
    }
}

public struct ParametricEQBand: Equatable, Identifiable, Codable {
    public var id: String
    public var type: BiquadFilterType
    public var frequency: Double
    public var gainDB: Double
    public var q: Double
    public var isEnabled: Bool

    public init(id: String = UUID().uuidString,
         type: BiquadFilterType,
         frequency: Double,
         gainDB: Double = 0,
         q: Double,
         isEnabled: Bool = true) {
        self.id = id
        self.type = type
        self.frequency = frequency
        self.gainDB = gainDB
        self.q = q
        self.isEnabled = isEnabled
    }

    public func coefficients(sampleRate: Double) -> BiquadCoefficients {
        guard isEnabled else { return .identity }
        return BiquadCoefficients.make(
            type: type,
            frequency: frequency,
            gainDB: gainDB,
            q: q,
            sampleRate: sampleRate)
    }
}

public struct ParametricEQCascade: Equatable {
    public var bands: [ParametricEQBand]
    public var sampleRate: Double

    public var coefficients: [BiquadCoefficients] {
        bands
            .map { $0.coefficients(sampleRate: sampleRate) }
            .filter { !$0.isIdentity }
    }

    public var isTransparent: Bool {
        coefficients.isEmpty
    }

    public var isStable: Bool {
        coefficients.allSatisfy(\.isStable)
    }
}

public struct CrossfeedMatrix: Equatable {
    public var leftToLeft: Double
    public var leftToRight: Double
    public var rightToLeft: Double
    public var rightToRight: Double

    public static let identity = CrossfeedMatrix(leftToLeft: 1, leftToRight: 0, rightToLeft: 0, rightToRight: 1)

    public static func symmetric(crossfeedDB: Double) -> CrossfeedMatrix {
        guard crossfeedDB.isFinite else { return .identity }
        let cross = min(max(pow(10, crossfeedDB / 20), 0), 1)
        guard cross > 0 else { return .identity }
        let direct = sqrt(max(0, 1 - cross * cross))
        return CrossfeedMatrix(leftToLeft: direct, leftToRight: cross,
                               rightToLeft: cross, rightToRight: direct)
    }

    public var isTransparent: Bool {
        self == .identity
    }

    public func apply(left: Double, right: Double) -> (left: Double, right: Double) {
        (
            left: leftToLeft * left + rightToLeft * right,
            right: leftToRight * left + rightToRight * right
        )
    }
}

public struct ConvolutionPlan: Equatable {
    public var taps: [Double]
    public var blockSize: Int
    public var latencyFrames: Int

    public static let identity = ConvolutionPlan(taps: [], blockSize: 0, latencyFrames: 0)

    public static func make(impulseResponse: [Double],
                     maxTaps: Int,
                     blockSize: Int,
                     normalize: Bool) -> ConvolutionPlan {
        let finiteTaps = impulseResponse.filter(\.isFinite)
        let limitedTaps = Array(finiteTaps.prefix(max(0, maxTaps)))
        guard !limitedTaps.isEmpty else { return .identity }
        let taps: [Double]
        if normalize, let peak = limitedTaps.map(abs).max(), peak > 1 {
            taps = limitedTaps.map { $0 / peak }
        } else {
            taps = limitedTaps
        }
        return ConvolutionPlan(
            taps: taps,
            blockSize: max(1, blockSize),
            latencyFrames: max(0, (taps.count - 1) / 2))
    }

    public var isTransparent: Bool {
        guard let first = taps.first else { return true }
        return first == 1 && taps.dropFirst().allSatisfy { $0 == 0 }
    }
}

public struct BitPerfectOutputPlan: Equatable {
    public enum Blocker: Equatable {
        case sampleRateMismatch
        case parametricEQ
        case crossfeed
        case convolution
        case replayGain
    }

    public var requested: Bool
    public var sampleRateMatchesHardware: Bool
    public var eqCascade: ParametricEQCascade
    public var crossfeed: CrossfeedMatrix
    public var convolution: ConvolutionPlan
    public var replayGainEnabled: Bool

    public var blockers: [Blocker] {
        var values: [Blocker] = []
        if !sampleRateMatchesHardware { values.append(.sampleRateMismatch) }
        if !eqCascade.isTransparent { values.append(.parametricEQ) }
        if !crossfeed.isTransparent { values.append(.crossfeed) }
        if !convolution.isTransparent { values.append(.convolution) }
        if replayGainEnabled { values.append(.replayGain) }
        return values
    }

    public var canUseBitPerfect: Bool {
        requested && blockers.isEmpty
    }
}

private struct PreparedBiquadInput {
    public var type: BiquadFilterType
    public var frequency: Double
    public var gainDB: Double
    public var q: Double
    public var sampleRate: Double
    public var w0: Double
    public var cosw0: Double

    public init(type: BiquadFilterType,
         frequency: Double,
         gainDB: Double,
         q: Double,
         sampleRate: Double) {
        let safeSampleRate = max(abs(sampleRate), 1)
        let nyquist = safeSampleRate / 2
        let safeFrequency = min(max(abs(frequency), 0.000_001), nyquist * 0.999_999)
        let safeW0 = 2 * Double.pi * safeFrequency / safeSampleRate
        self.type = type
        self.frequency = safeFrequency
        self.gainDB = gainDB.isFinite ? gainDB : 0
        self.q = max(abs(q), 0.000_001)
        self.sampleRate = safeSampleRate
        self.w0 = safeW0
        self.cosw0 = cos(safeW0)
    }
}

private struct Complex {
    public var real: Double
    public var imaginary: Double

    public var magnitude: Double {
        sqrt(real * real + imaginary * imaginary)
    }
}
