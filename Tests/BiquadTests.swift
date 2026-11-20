import Testing

@testable import TonearmCore

@Suite struct BiquadTests {
    @Test func testCoefficientVectorsAgainstKnownCookbookReferences() {
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

    @Test func testExtremeQAndNearNyquistStayFiniteAndStable() {
        for type in BiquadFilterType.allCases {
            for q in [0.05, 100.0] {
                let coefficients = BiquadCoefficients.make(
                    type: type,
                    frequency: 23_999,
                    gainDB: type.usesGain ? 6 : 0,
                    q: q,
                    sampleRate: 48_000)
                #expect(coefficients.vector.allSatisfy { $0.isFinite }, "\(type.rawValue) q \(q)")
                #expect(coefficients.isStable, "\(type.rawValue) q \(q)")
            }
        }
    }

    @Test func testGainFiltersAtZeroDBAreExactlyUnity() {
        for type in [BiquadFilterType.peaking, .lowShelf, .highShelf] {
            let coefficients = BiquadCoefficients.make(
                type: type,
                frequency: 1_000,
                gainDB: 0,
                q: 1,
                sampleRate: 48_000)
            #expect(coefficients == .identity, "\(type.rawValue)")
            #expect(abs(coefficients.magnitude(at: 1_000, sampleRate: 48_000) - 1) <= 1e-12)
        }
    }

    @Test func testParametricCascadeTransparencyAndRuntimeBiquadBridge() {
        let transparent = ParametricEQCascade(
            bands: [
                ParametricEQBand(type: .peaking, frequency: 1_000, gainDB: 0, q: 1),
                ParametricEQBand(type: .lowShelf, frequency: 120, gainDB: 0, q: 1),
                ParametricEQBand(type: .notch, frequency: 60, q: 10, isEnabled: false),
            ],
            sampleRate: 48_000)
        #expect(transparent.isTransparent)
        #expect(transparent.isStable)

        let active = ParametricEQCascade(
            bands: [ParametricEQBand(type: .peaking, frequency: 1_000, gainDB: 3, q: 1)],
            sampleRate: 48_000)
        #expect(!active.isTransparent)
        #expect(active.isStable)
        let runtime = Biquad(coefficients: active.coefficients[0])
        #expect(runtime.coefficients == active.coefficients[0])
    }

    @Test func testCrossfeedMatrixIsSymmetricAndIdentityCanStayBitPerfect() {
        let identity = CrossfeedMatrix.identity
        #expect(identity.isTransparent)
        #expect(identity.apply(left: 1, right: -1).left == 1)
        #expect(identity.apply(left: 1, right: -1).right == -1)

        let matrix = CrossfeedMatrix.symmetric(crossfeedDB: -6)
        let mixed = matrix.apply(left: 1, right: 0)
        #expect(abs(matrix.leftToRight - matrix.rightToLeft) <= 1e-12)
        #expect(abs(matrix.leftToLeft - matrix.rightToRight) <= 1e-12)
        #expect(abs(mixed.left - matrix.leftToLeft) <= 1e-12)
        #expect(abs(mixed.right - matrix.leftToRight) <= 1e-12)
        #expect(!matrix.isTransparent)
    }

    @Test func testConvolutionSetupNormalizesLimitsAndReportsLatency() {
        let empty = ConvolutionPlan.make(
            impulseResponse: [],
            maxTaps: 16,
            blockSize: 0,
            normalize: true)
        #expect(empty == .identity)
        #expect(empty.isTransparent)

        let plan = ConvolutionPlan.make(
            impulseResponse: [2, 0.5, .nan, -1, .infinity, 0],
            maxTaps: 3,
            blockSize: 0,
            normalize: true)
        #expect(plan.taps == [1, 0.25, -0.5])
        #expect(plan.blockSize == 1)
        #expect(plan.latencyFrames == 1)
        #expect(!plan.isTransparent)

        let identity = ConvolutionPlan.make(
            impulseResponse: [1, 0, 0],
            maxTaps: 3,
            blockSize: 128,
            normalize: false)
        #expect(identity.isTransparent)
    }

    @Test func testBitPerfectOutputRequiresTransparentProcessingAndMatchedRate() {
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
        #expect(clean.canUseBitPerfect)
        #expect(clean.blockers == [])

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
        #expect(!blocked.canUseBitPerfect)
        #expect(blocked.blockers == [
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
                                    sourceLocation: SourceLocation = #_sourceLocation) {
        let actual = coefficients.vector
        #expect(actual.count == expected.count, sourceLocation: sourceLocation)
        for (index, pair) in zip(actual, expected).enumerated() {
            #expect(abs(pair.0 - pair.1) <= 1e-9, "\(label)[\(index)]", sourceLocation: sourceLocation)
        }
    }
}

private extension BiquadCoefficients {
    var vector: [Double] {
        [b0, b1, b2, a1, a2]
    }
}
