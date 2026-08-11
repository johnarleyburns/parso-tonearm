import XCTest

@testable import TonearmDJ

final class FakeEmbeddingTests: XCTestCase {

    private func makeSpec() throws -> EmbeddingModelSpec {
        let filterBank = try EmbeddingModelSpec.loadMelFilterBank(
            from: DJFixtures.url("mel_filterbank_slaney_64", ext: "bin"))
        return EmbeddingModelSpec.musicCLAP(melFilterBank: filterBank)
    }

    func testEmbedTextIsDeterministic() async throws {
        let model = DeterministicFakeSemanticModel(spec: try makeSpec())
        let a = try await model.embedText("dark driving bassline")
        let b = try await model.embedText("dark driving bassline")
        XCTAssertEqual(a, b, "same seed + same text -> identical vector")
    }

    func testEmbedTextUnitNorm() async throws {
        let model = DeterministicFakeSemanticModel(spec: try makeSpec())
        let v = try await model.embedText("warm ambient pad chords")
        XCTAssertEqual(v.count, 512)
        let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
        XCTAssertEqual(norm, 1.0, accuracy: 1e-5)
    }

    func testDifferentSeedChangesVector() async throws {
        let spec = try makeSpec()
        let a = DeterministicFakeSemanticModel(spec: spec, seed: Data("seed-a".utf8))
        let b = DeterministicFakeSemanticModel(spec: spec, seed: Data("seed-b".utf8))
        let va = try await a.embedText("same text")
        let vb = try await b.embedText("same text")
        XCTAssertNotEqual(va, vb)
    }

    func testDifferentTextChangesVector() async throws {
        let model = DeterministicFakeSemanticModel(spec: try makeSpec())
        let a = try await model.embedText("dark driving bassline")
        let b = try await model.embedText("warm ambient pad chords")
        XCTAssertNotEqual(a, b)
    }

    func testEmbedAudioHashesContent() async throws {
        let model = DeterministicFakeSemanticModel(spec: try makeSpec())
        let zero = [Float](repeating: 0, count: 1_001 * 64)
        let one = [Float](repeating: 1, count: 1_001 * 64)
        let a = try await model.embedAudio(logMel: zero)
        let b = try await model.embedAudio(logMel: one)
        XCTAssertNotEqual(a, b)
        let sumSquares = a.reduce(0) { $0 + $1 * $1 }
        let norm = sqrt(sumSquares)
        XCTAssertEqual(norm, 1.0, accuracy: 1e-5)
    }

    func testEmbedderSerializesWindows() async throws {
        let model = DeterministicFakeSemanticModel(spec: try makeSpec())
        let embedder = CLAPEmbedder(model: model)
        let frameCount = 1_001 * 64
        let windowLength = 480_000
        let hop = 240_000
        var windows: [Preprocess.MelWindow] = []
        for i in 0..<3 {
            let start = i * hop
            windows.append(Preprocess.MelWindow(
                startSample: Int64(start),
                endSample: Int64(start + windowLength),
                logMel: [Float](repeating: Float(i), count: frameCount),
                frames: 1_001, melBins: 64))
        }
        let vectors = try await embedder.embedWindows(windows)
        XCTAssertEqual(vectors.count, 3)
        XCTAssertTrue(vectors.allSatisfy { $0.count == 512 })
        for v in vectors {
            let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
            XCTAssertEqual(norm, 1.0, accuracy: 1e-5)
        }
        let text = try await embedder.embedText("more like this")
        XCTAssertEqual(text.count, 512)
    }
}
