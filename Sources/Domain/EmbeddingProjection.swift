import Foundation
import Accelerate

/// A principal-component projection of the CLAP embeddings, so the starter DB
/// ships fewer values per track: 128 instead of 512 kept the same nearest
/// neighbours for 97% of tracks (top-10 overlap) on the Mood Starter set, with
/// 98% of the variance.
///
/// The app never compares projected vectors: `reconstruct` rebuilds the full
/// vector (mean + components·z, L2-normalized), so the library, the vector
/// index and text queries keep working on 512-value embeddings.
public struct EmbeddingProjection: Sendable, Equatable {
    public let sourceDimensions: Int
    public let dimensions: Int
    /// `sourceDimensions` values.
    public let mean: [Float]
    /// `dimensions` orthonormal rows of `sourceDimensions` values, strongest first.
    public let components: [Float]

    public init(sourceDimensions: Int, dimensions: Int, mean: [Float], components: [Float]) {
        self.sourceDimensions = sourceDimensions
        self.dimensions = dimensions
        self.mean = mean
        self.components = components
    }

    /// The `dimensions` strongest principal components of `vectors`, by subspace
    /// iteration on their covariance.
    public static func fit(_ vectors: [[Float]], dimensions: Int, iterations: Int = 200) -> EmbeddingProjection? {
        guard let d = vectors.first?.count, d > 0, dimensions > 0, dimensions <= d, vectors.count > 1,
              vectors.allSatisfy({ $0.count == d }) else { return nil }
        let n = vectors.count, k = dimensions
        var mean = [Float](repeating: 0, count: d)
        for v in vectors { vDSP_vadd(mean, 1, v, 1, &mean, 1, vDSP_Length(d)) }
        var inverseCount = 1 / Float(n)
        vDSP_vsmul(mean, 1, &inverseCount, &mean, 1, vDSP_Length(d))
        // Centered data, n × d, then its covariance, d × d.
        var centered = [Float](repeating: 0, count: n * d)
        for (i, v) in vectors.enumerated() {
            centered.withUnsafeMutableBufferPointer { out in
                vDSP_vsub(mean, 1, v, 1, out.baseAddress! + i * d, 1, vDSP_Length(d))
            }
        }
        var transposed = [Float](repeating: 0, count: d * n)
        vDSP_mtrans(centered, 1, &transposed, 1, vDSP_Length(d), vDSP_Length(n))
        var covariance = [Float](repeating: 0, count: d * d)
        vDSP_mmul(transposed, 1, centered, 1, &covariance, 1, vDSP_Length(d), vDSP_Length(d), vDSP_Length(n))

        // Rows of `basis` span the subspace; deterministic start.
        var generator = SplitMix(seed: 0x5EED)
        var basis = (0..<(k * d)).map { _ in Float(generator.nextUnit() - 0.5) }
        orthonormalizeRows(&basis, rows: k, columns: d)
        var product = [Float](repeating: 0, count: k * d)
        for _ in 0..<iterations {
            vDSP_mmul(basis, 1, covariance, 1, &product, 1, vDSP_Length(k), vDSP_Length(d), vDSP_Length(d))
            basis = product
            orthonormalizeRows(&basis, rows: k, columns: d)
        }
        // Strongest first: order rows by their variance (Rayleigh quotient).
        vDSP_mmul(basis, 1, covariance, 1, &product, 1, vDSP_Length(k), vDSP_Length(d), vDSP_Length(d))
        let variance = (0..<k).map { row -> Float in
            var dot: Float = 0
            vDSP_dotpr(Array(basis[row * d..<(row + 1) * d]), 1, Array(product[row * d..<(row + 1) * d]), 1,
                       &dot, vDSP_Length(d))
            return dot
        }
        let order = (0..<k).sorted { variance[$0] > variance[$1] }
        let components = order.flatMap { basis[$0 * d..<($0 + 1) * d] }
        return EmbeddingProjection(sourceDimensions: d, dimensions: k, mean: mean, components: components)
    }

    /// The `dimensions` coordinates of `vector` in the projection.
    public func project(_ vector: [Float]) -> [Float] {
        guard vector.count == sourceDimensions else { return [] }
        var centered = [Float](repeating: 0, count: sourceDimensions)
        vDSP_vsub(mean, 1, vector, 1, &centered, 1, vDSP_Length(sourceDimensions))
        var out = [Float](repeating: 0, count: dimensions)
        vDSP_mmul(components, 1, centered, 1, &out, 1, vDSP_Length(dimensions), 1, vDSP_Length(sourceDimensions))
        return out
    }

    /// The full, L2-normalized vector for projected coordinates `z`.
    public func reconstruct(_ z: [Float]) -> [Float] {
        guard z.count == dimensions else { return [] }
        var out = [Float](repeating: 0, count: sourceDimensions)
        // out (1 × source) = z (1 × k) · components (k × source)
        vDSP_mmul(z, 1, components, 1, &out, 1, 1, vDSP_Length(sourceDimensions), vDSP_Length(dimensions))
        vDSP_vadd(out, 1, mean, 1, &out, 1, vDSP_Length(sourceDimensions))
        var norm: Float = 0
        vDSP_svesq(out, 1, &norm, vDSP_Length(sourceDimensions))
        guard norm > 0 else { return out }
        var inverse = 1 / norm.squareRoot()
        vDSP_vsmul(out, 1, &inverse, &out, 1, vDSP_Length(sourceDimensions))
        return out
    }

    /// int8 values and their scale (`value = int8 · scale`), as the CLAP embeddings are stored.
    public static func quantize(_ vector: [Float]) -> (data: Data, scale: Double) {
        let maxAbs = vector.map(abs).max() ?? 0
        guard maxAbs > 0 else { return (Data(repeating: 0, count: vector.count), 0) }
        let scale = maxAbs / 127
        let bytes = vector.map { UInt8(bitPattern: Int8(min(127, max(-127, ($0 / scale).rounded())))) }
        return (Data(bytes), Double(scale))
    }

    public static func dequantize(_ data: Data, scale: Double) -> [Float] {
        data.map { Float(Int8(bitPattern: $0)) * Float(scale) }
    }

    /// Little-endian Float32: mean, then components.
    public var encoded: Data {
        var data = Data(capacity: 4 * (mean.count + components.count))
        for value in mean + components { withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) } }
        return data
    }

    public init?(sourceDimensions: Int, dimensions: Int, encoded data: Data) {
        let count = sourceDimensions * (1 + dimensions)
        guard sourceDimensions > 0, dimensions > 0, data.count == 4 * count else { return nil }
        let values = (0..<count).map { i -> Float in
            let offset = data.startIndex + 4 * i
            let bits = UInt32(data[offset]) | UInt32(data[offset + 1]) << 8
                | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
            return Float(bitPattern: bits)
        }
        self.init(sourceDimensions: sourceDimensions, dimensions: dimensions,
                  mean: Array(values[0..<sourceDimensions]), components: Array(values[sourceDimensions...]))
    }

    private static func orthonormalizeRows(_ m: inout [Float], rows: Int, columns: Int) {
        m.withUnsafeMutableBufferPointer { buffer in
            let base = buffer.baseAddress!
            for i in 0..<rows {
                let row = base + i * columns
                for j in 0..<i {
                    let previous = base + j * columns
                    var dot: Float = 0
                    vDSP_dotpr(row, 1, previous, 1, &dot, vDSP_Length(columns))
                    var negative = -dot
                    vDSP_vsma(previous, 1, &negative, row, 1, row, 1, vDSP_Length(columns))
                }
                var norm: Float = 0
                vDSP_svesq(row, 1, &norm, vDSP_Length(columns))
                var inverse = norm > 0 ? 1 / norm.squareRoot() : 0
                vDSP_vsmul(row, 1, &inverse, row, 1, vDSP_Length(columns))
            }
        }
    }

    /// Deterministic pseudo-random numbers for the starting basis.
    private struct SplitMix {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func nextUnit() -> Double {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
        }
    }
}
