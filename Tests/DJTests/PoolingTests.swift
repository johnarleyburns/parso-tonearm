import XCTest
import Accelerate

@testable import TonearmDJ

/// §27.4 pooling: mean baseline + attention softmax over salience.
final class PoolingTests: XCTestCase {

    private func pseudoVector(_ text: String, seed: String = "pool-test") -> [Float] {
        DeterministicFakeSemanticModel.pseudoEmbedding(
            from: Data(text.utf8), seed: Data(seed.utf8), dims: 512)
    }

    private func distance(_ a: [Float], _ b: [Float]) -> Float {
        sqrt(zip(a, b).reduce(0) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) })
    }

    func testMeanPoolingIsNormalizedMean() {
        let a: [Float] = [1, 0]
        let b: [Float] = [0, 1]
        let pooled = Pooling.mean([a, b])
        XCTAssertEqual(pooled[0], 1 / sqrt(2), accuracy: 1e-6)
        XCTAssertEqual(pooled[1], 1 / sqrt(2), accuracy: 1e-6)
        var norm: Float = 0
        vDSP_dotpr(pooled, 1, pooled, 1, &norm, vDSP_Length(2))
        XCTAssertEqual(sqrt(norm), 1.0, accuracy: 1e-6)
    }

    func testMeanSingleWindowIsTheWindow() {
        let v = pseudoVector("solo")
        XCTAssertEqual(Pooling.mean([v]), v)
    }

    func testAttentionIsUniformForIdenticalWindows() {
        let v = pseudoVector("uniform")
        // Identical windows → centroid == each window → uniform salience → pooled ≈ v.
        let pooled = Pooling.attention([v, v, v], energy: [1, 2, 3])
        XCTAssertEqual(pooled.count, 512)
        for i in 0..<512 {
            XCTAssertEqual(pooled[i], v[i], accuracy: 1e-5, "dim \(i)")
        }
    }

    func testAttentionEnergyDominatesSalience() {
        let quiet = pseudoVector("ambient intro pad fading in")
        let loud = pseudoVector("drop section, dense drums and bass")
        let pooled = Pooling.attention([quiet, loud], energy: [0.01, 10.0])
        // The loud window should dominate the pooled vector.
        XCTAssertLessThan(distance(pooled, loud), distance(pooled, quiet))
    }

    func testAttentionWithoutEnergyDeemphasizesCentroidOutliers() {
        let typical = pseudoVector("typical section")
        let outlier = pseudoVector("ten seconds of silence and noise")
        let pooled = Pooling.attention([typical, typical, outlier], energy: nil)
        // Outlier is far from the centroid → down-weighted → pooled stays near the
        // two typical windows.
        XCTAssertLessThan(distance(pooled, typical), distance(pooled, outlier))
    }

    func testAttentionDeterministic() {
        let a = pseudoVector("a")
        let b = pseudoVector("b")
        let first = Pooling.attention([a, b], energy: [0.5, 0.7])
        let second = Pooling.attention([a, b], energy: [0.5, 0.7])
        XCTAssertEqual(first, second)
    }

    func testPoolDispatchesByStrategy() {
        let a = pseudoVector("a")
        let b = pseudoVector("b")
        XCTAssertEqual(Pooling.pool([a, b], strategy: .mean), Pooling.mean([a, b]))
        XCTAssertEqual(Pooling.pool([a, b], strategy: .attention),
                       Pooling.attention([a, b], energy: nil))
    }

    func testEmptyWindowsPoolToEmpty() {
        XCTAssertEqual(Pooling.mean([]), [])
        XCTAssertEqual(Pooling.attention([], energy: nil), [])
    }
}
