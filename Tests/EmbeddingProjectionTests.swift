import XCTest
@testable import TonearmCore

final class EmbeddingProjectionTests: XCTestCase {
    /// Unit vectors near an 8-dimensional subspace of a 64-dimensional space.
    private func vectors(count: Int) -> [[Float]] {
        var seed: UInt64 = 42
        func random() -> Float {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Float(Double(seed >> 11) / Double(1 << 53)) - 0.5
        }
        let basis = (0..<8).map { _ in (0..<64).map { _ in random() } }
        return (0..<count).map { _ in
            var v = [Float](repeating: 0, count: 64)
            for b in basis { let w = random(); for i in 0..<64 { v[i] += w * b[i] } }
            for i in 0..<64 { v[i] += 0.001 * random() }
            let norm = v.map { $0 * $0 }.reduce(0, +).squareRoot()
            return v.map { $0 / norm }
        }
    }

    private func cosine(_ a: [Float], _ b: [Float]) -> Float {
        zip(a, b).map(*).reduce(0, +) / (a.map { $0 * $0 }.reduce(0, +).squareRoot() * b.map { $0 * $0 }.reduce(0, +).squareRoot())
    }

    func testProjectionKeepsVectorsInTheirSubspace() throws {
        let data = vectors(count: 300)
        let projection = try XCTUnwrap(EmbeddingProjection.fit(data, dimensions: 8))
        XCTAssertEqual(projection.components.count, 8 * 64)
        for v in data.prefix(20) {
            XCTAssertGreaterThan(cosine(projection.reconstruct(projection.project(v)), v), 0.999)
        }
        let decoded = try XCTUnwrap(EmbeddingProjection(sourceDimensions: 64, dimensions: 8, encoded: projection.encoded))
        XCTAssertEqual(decoded, projection)
    }

    func testStarterShipsProjectedEmbeddingsAndReadsThemInFull() throws {
        let data = vectors(count: 60)
        let tracks = data.enumerated().map { index, vector -> BuiltInMoodTrack in
            let (bytes, scale) = EmbeddingProjection.quantize(vector)
            return BuiltInMoodTrack(
                id: "jamendo-\(index)", title: "T\(index)", artist: "A", genre: "House", license: "cc-by",
                licenseURL: nil, durationSec: 200, streamURL: "https://example.com/\(index).mp3", artworkURL: nil,
                dimensions: 64, scale: scale, quantizedVector: bytes, bpm: 120, key: "8A", energy: 0.5,
                analysisScopeSeconds: 60)
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("starter-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        try StarterLibraryWriter.create(at: url, tracks: tracks, meta: [:], embeddingDimensions: 8)
        let starter = try StarterLibrary(url: url)
        XCTAssertEqual(starter.projection?.dimensions, 8)
        let read = try starter.tracks()
        XCTAssertEqual(read.count, 60)
        for track in read {
            let original = data[Int(track.id.dropFirst("jamendo-".count))!]
            XCTAssertEqual(track.dimensions, 64, "the library gets full embeddings")
            XCTAssertEqual(track.quantizedVector.count, 64)
            let rebuilt = EmbeddingProjection.dequantize(track.quantizedVector, scale: track.scale)
            XCTAssertGreaterThan(cosine(rebuilt, original), 0.99)
        }
    }
}
