import XCTest
import Accelerate

@testable import TonearmDJ

/// §16.6 quantization gate (plan §5 2.3): int8 must keep recall@10 ≥ 0.95
/// against exact f32 cosine ground truth on a synthetic corpus. A pure
/// measurement commit — no production code changes. Also pins determinism
/// (NFR-DET-3) and the version-stable quantization contract.
final class RecallGateTests: XCTestCase {

    /// A deterministic SplitMix64 RNG (NFR-DET-3): same seed → same corpus,
    /// independent of platform randomness.
    private struct SplitMix64 {
        private var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func unitFloat() -> Float {
            Float(Double(next() >> 11) / Double(1 << 53)) * 2 - 1
        }
    }

    /// A random L2-normalized unit vector.
    private func unitVector(_ rng: inout SplitMix64, dims: Int) -> [Float] {
        let raw = (0..<dims).map { _ in rng.unitFloat() }
        var norm: Float = 0
        vDSP_dotpr(raw, 1, raw, 1, &norm, vDSP_Length(dims))
        let inv = 1 / sqrt(norm)
        var scaled = raw
        vDSP_vsmul(raw, 1, [inv], &scaled, 1, vDSP_Length(dims))
        return scaled
    }

    /// Build an in-memory `vectors.i8` matrix (Float32 scale LE + raw Int8[dims],
    /// §15.7) exactly as `VectorStoreTierA.appendRow` lays it out.
    private func matrixBytes(corpus: [[Float]]) -> Data {
        var data = Data()
        data.reserveCapacity(corpus.count * VectorMatrixScanner.rowBytes(dims: corpus[0].count))
        for vector in corpus {
            let (int8, scale) = VectorQuantization.quantize(vector)
            var scaleLE = Float(scale)
            withUnsafeBytes(of: &scaleLE) { data.append(contentsOf: $0) }
            data.append(VectorQuantization.data(int8))
        }
        return data
    }

    /// Exact f32 cosine ranking (≈ dot for unit vectors) — the §16.6 ground truth.
    private func exactTopK(query: [Float], corpus: [[Float]], k: Int) -> [Int] {
        var scores: [(row: Int, cosine: Float)] = []
        scores.reserveCapacity(corpus.count)
        for (row, vector) in corpus.enumerated() {
            var dot: Float = 0
            vDSP_dotpr(vector, 1, query, 1, &dot, vDSP_Length(vector.count))
            scores.append((row, dot))
        }
        return scores.sorted { $0.cosine > $1.cosine }.prefix(k).map(\.row)
    }

    // MARK: - The gate

    /// recall@10 of the int8 scan vs exact f32 cosine must be ≥ 0.95 (§16.6).
    func testInt8RecallAt10MeetsGate() throws {
        let dims = 512
        let rows = 1_000
        let queries = 200
        let k = 10

        var rng = SplitMix64(seed: 0x4D2_3B14_2E16_7C21)
        let corpus = (0..<rows).map { _ in unitVector(&rng, dims: dims) }
        let matrix = matrixBytes(corpus: corpus)

        var hits = 0
        for q in 0..<queries {
            var queryRNG = SplitMix64(seed: UInt64(0xA0A0_0000 + q))
            let query = unitVector(&queryRNG, dims: dims)
            let groundTruth = exactTopK(query: query, corpus: corpus, k: k)
            let approximate = VectorMatrixScanner.scan(
                matrix: matrix, dims: dims, query: query, rowMapping: nil,
                topK: k, isCancelled: { false }).map(\.rowID).map { Int($0) }
            hits += Set(groundTruth).intersection(approximate).count
        }
        let recall = Double(hits) / Double(queries * k)
        print("RECALL GATE: int8 recall@10 = \(String(format: "%.4f", recall)) "
            + "over \(rows) rows x \(queries) queries (dims \(dims))")
        XCTAssertGreaterThanOrEqual(recall, 0.95,
            "int8 recall@10 \(recall) < 0.95 → §16.6 fallback to f16")
    }

    // MARK: - Determinism (NFR-DET-3)

    /// Same input → identical bytes, every call.
    func testQuantizationIsDeterministic() throws {
        var rng = SplitMix64(seed: 0xDEAD_BEEF)
        let v = unitVector(&rng, dims: 512)
        let a = VectorQuantization.quantize(v)
        let b = VectorQuantization.quantize(v)
        let c = VectorQuantization.quantize(v)
        XCTAssertEqual(a.scale, b.scale)
        XCTAssertEqual(a.int8, b.int8)
        XCTAssertEqual(VectorQuantization.data(a.int8), VectorQuantization.data(c.int8))
    }

    /// The same matrix + query scanned twice returns the identical ordering.
    func testScanIsRepeatable() throws {
        let dims = 64
        var rng = SplitMix64(seed: 0xF00D)
        let corpus = (0..<200).map { _ in unitVector(&rng, dims: dims) }
        let matrix = matrixBytes(corpus: corpus)
        var qrng = SplitMix64(seed: 0xBEEF)
        let query = unitVector(&qrng, dims: dims)
        let first = VectorMatrixScanner.scan(matrix: matrix, dims: dims, query: query,
                                             rowMapping: nil, topK: 10, isCancelled: { false })
        let second = VectorMatrixScanner.scan(matrix: matrix, dims: dims, query: query,
                                              rowMapping: nil, topK: 10, isCancelled: { false })
        XCTAssertEqual(first.map(\.rowID), second.map(\.rowID))
        XCTAssertEqual(first.map(\.similarity), second.map(\.similarity))
    }

    // MARK: - Version stability

    /// Pin the quantization contract so a future change cannot silently shift
    /// semantics: dequantize(quantize(v)) must recover every element to within
    /// the per-row scale, the documented error bound (§16.6).
    func testDequantizeStaysWithinPinnedErrorBound() throws {
        var rng = SplitMix64(seed: 0xC0FFEE)
        let v = unitVector(&rng, dims: 512)
        let (int8, scale) = VectorQuantization.quantize(v)
        let back = VectorQuantization.dequantize(int8, scale: scale)
        XCTAssertGreaterThan(scale, 0)
        for i in 0..<v.count {
            XCTAssertEqual(back[i], v[i], accuracy: scale,
                           "dim \(i) dequantized to \(back[i]), expected \(v[i])")
        }
    }
}
