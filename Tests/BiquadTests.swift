import XCTest

@testable import Tonearm

final class BiquadTests: XCTestCase {
    func testCoefficientVectorsAgainstKnownCookbookReferences() {
        let cases: [(BiquadFilterType, Double, Double, Double, [Double])] = [
            (.peaking, 1_000, 6, 1, [
                1.043953086990, -1.895320723937, 0.867722284760,
                -1.895320723937, 0.911675371750,
            ]),
            (.lowShelf, 120, 4, 1, [
                1.002566363721, -1.980145180456, 0.977886396938,
                -1.980201935563, 0.980396005552,
            ]),
            (.highShelf, 8_000, -3, 1, [
                0.797556833919, -0.421284129525, 0.176526348310,
                -0.709104831844, 0.261903884547,
            ]),
            (.lowPass, 1_200, 0, 0.707, [
                0.005542633834, 0.011085267667, 0.005542633834,
                -1.778605022612, 0.800775557946,
            ]),
            (.highPass, 80, 0, 0.707, [
                0.992621440809, -1.985242881618, 0.992621440809,
                -1.985188454063, 0.985297309174,
            ]),
            (.notch, 60, 0, 10, [
                0.999607459104, -1.999153257712, 0.999607459104,
                -1.999153257712, 0.999214918209,
            ]),
        ]

        for (type, frequency, gain, q, expected) in cases {
            let coefficients = BiquadCoefficients.make(
                type: type,
                frequency: frequency,
                gainDB: gain,
                q: q,
                sampleRate: 48_000)
            assertCoefficients(coefficients, expected, type.rawValue)
        }
    }

    func testExtremeQAndNearNyquistStayFiniteAndStable() {
        for type in BiquadFilterType.allCases {
            for q in [0.05, 100.0] {
                let coefficients = BiquadCoefficients.make(
                    type: type,
                    frequency: 23_999,
                    gainDB: type.usesGain ? 6 : 0,
                    q: q,
                    sampleRate: 48_000)
                XCTAssertTrue(coefficients.vector.allSatisfy(\.isFinite), "\(type.rawValue) q \(q)")
                XCTAssertTrue(coefficients.isStable, "\(type.rawValue) q \(q)")
            }
        }
    }

    func testGainFiltersAtZeroDBAreExactlyUnity() {
        for type in [BiquadFilterType.peaking, .lowShelf, .highShelf] {
            let coefficients = BiquadCoefficients.make(
                type: type,
                frequency: 1_000,
                gainDB: 0,
                q: 1,
                sampleRate: 48_000)
            XCTAssertEqual(coefficients, .identity, type.rawValue)
            XCTAssertEqual(coefficients.magnitude(at: 1_000, sampleRate: 48_000), 1, accuracy: 1e-12)
        }
    }

    func testParametricCascadeTransparencyAndRuntimeBiquadBridge() {
        let transparent = ParametricEQCascade(
            bands: [
                ParametricEQBand(type: .peaking, frequency: 1_000, gainDB: 0, q: 1),
                ParametricEQBand(type: .lowShelf, frequency: 120, gainDB: 0, q: 1),
                ParametricEQBand(type: .notch, frequency: 60, q: 10, isEnabled: false),
            ],
            sampleRate: 48_000)
        XCTAssertTrue(transparent.isTransparent)
        XCTAssertTrue(transparent.isStable)

        let active = ParametricEQCascade(
            bands: [ParametricEQBand(type: .peaking, frequency: 1_000, gainDB: 3, q: 1)],
            sampleRate: 48_000)
        XCTAssertFalse(active.isTransparent)
        XCTAssertTrue(active.isStable)
        let runtime = Biquad(coefficients: active.coefficients[0])
        XCTAssertEqual(runtime.coefficients, active.coefficients[0])
    }

    func testCrossfeedMatrixIsSymmetricAndIdentityCanStayBitPerfect() {
        let identity = CrossfeedMatrix.identity
        XCTAssertTrue(identity.isTransparent)
        XCTAssertEqual(identity.apply(left: 1, right: -1).left, 1)
        XCTAssertEqual(identity.apply(left: 1, right: -1).right, -1)

        let matrix = CrossfeedMatrix.symmetric(crossfeedDB: -6)
        let mixed = matrix.apply(left: 1, right: 0)
        XCTAssertEqual(matrix.leftToRight, matrix.rightToLeft, accuracy: 1e-12)
        XCTAssertEqual(matrix.leftToLeft, matrix.rightToRight, accuracy: 1e-12)
        XCTAssertEqual(mixed.left, matrix.leftToLeft, accuracy: 1e-12)
        XCTAssertEqual(mixed.right, matrix.leftToRight, accuracy: 1e-12)
        XCTAssertFalse(matrix.isTransparent)
    }

    func testConvolutionSetupNormalizesLimitsAndReportsLatency() {
        let empty = ConvolutionPlan.make(
            impulseResponse: [],
            maxTaps: 16,
            blockSize: 0,
            normalize: true)
        XCTAssertEqual(empty, .identity)
        XCTAssertTrue(empty.isTransparent)

        let plan = ConvolutionPlan.make(
            impulseResponse: [2, 0.5, .nan, -1, .infinity, 0],
            maxTaps: 3,
            blockSize: 0,
            normalize: true)
        XCTAssertEqual(plan.taps, [1, 0.25, -0.5])
        XCTAssertEqual(plan.blockSize, 1)
        XCTAssertEqual(plan.latencyFrames, 1)
        XCTAssertFalse(plan.isTransparent)

        let identity = ConvolutionPlan.make(
            impulseResponse: [1, 0, 0],
            maxTaps: 3,
            blockSize: 128,
            normalize: false)
        XCTAssertTrue(identity.isTransparent)
    }

    func testBitPerfectOutputRequiresTransparentProcessingAndMatchedRate() {
        let transparentEQ = ParametricEQCascade(bands: [], sampleRate: 48_000)
        let activeEQ = ParametricEQCascade(
            bands: [ParametricEQBand(type: .peaking, frequency: 1_000, gainDB: 1, q: 1)],
            sampleRate: 48_000)

        let clean = BitPerfectOutputPlan(
            requested: true,
            sampleRateMatchesHardware: true,
            eqCascade: transparentEQ,
            crossfeed: .identity,
            convolution: .identity,
            replayGainEnabled: false)
        XCTAssertTrue(clean.canUseBitPerfect)
        XCTAssertEqual(clean.blockers, [])

        let blocked = BitPerfectOutputPlan(
            requested: true,
            sampleRateMatchesHardware: false,
            eqCascade: activeEQ,
            crossfeed: .symmetric(crossfeedDB: -9),
            convolution: ConvolutionPlan.make(
                impulseResponse: [0.5, 0.5],
                maxTaps: 2,
                blockSize: 128,
                normalize: false),
            replayGainEnabled: true)
        XCTAssertFalse(blocked.canUseBitPerfect)
        XCTAssertEqual(blocked.blockers, [
            .sampleRateMismatch,
            .parametricEQ,
            .crossfeed,
            .convolution,
            .replayGain,
        ])
    }

    private func assertCoefficients(_ coefficients: BiquadCoefficients,
                                    _ expected: [Double],
                                    _ label: String,
                                    file: StaticString = #filePath,
                                    line: UInt = #line) {
        let actual = coefficients.vector
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        for (index, pair) in zip(actual, expected).enumerated() {
            XCTAssertEqual(pair.0, pair.1, accuracy: 1e-9, "\(label)[\(index)]", file: file, line: line)
        }
    }
}

private extension BiquadCoefficients {
    var vector: [Double] {
        [b0, b1, b2, a1, a2]
    }
}
