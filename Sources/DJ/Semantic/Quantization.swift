import Foundation
import Accelerate

/// Symmetric per-row int8 quantization of L2-normalized embedding vectors (§16.6).
///
/// Layout: `scale = max|v| / 127`, zero-point 0 — a unit vector maps into
/// [-127, 127] with no bias term, so the store can scan raw `Int8` rows with
/// `vDSP_vflt8` + `vDSP_dotpr` and dequantize by a single scalar multiply.
/// Pure and deterministic (NFR-DET-3): same input → identical bytes.
public enum Quantization {

    /// Quantize one L2-normalized vector. `scale == 0` for the all-zero vector
    /// (all `Int8` zero); the caller may still store it, dot products yield 0.
    public static func quantize(_ vector: [Float]) -> (int8: [Int8], scale: Float) {
        var maxAbs: Float = 0
        vDSP_maxmgv(vector, 1, &maxAbs, vDSP_Length(vector.count))
        guard vector.count > 0, maxAbs > 0 else {
            return ([Int8](repeating: 0, count: vector.count), 0)
        }
        let scale = maxAbs / 127
        var scaled = [Float](repeating: 0, count: vector.count)
        var invScale = 1 / scale
        vDSP_vsmul(vector, 1, &invScale, &scaled, 1, vDSP_Length(vector.count))
        var out = [Int8](repeating: 0, count: vector.count)
        for i in 0..<vector.count {
            out[i] = Int8(min(127, max(-127, scaled[i].rounded())))
        }
        return (out, scale)
    }

    /// Dequantize `scale * int8` back to Float. `scale == 0` → all zeros.
    public static func dequantize(_ int8: [Int8], scale: Float) -> [Float] {
        var out = [Float](repeating: 0, count: int8.count)
        guard int8.count > 0 else { return out }
        vDSP_vflt8(int8, 1, &out, 1, vDSP_Length(int8.count))
        if scale > 0 {
            var multiplier = scale
            vDSP_vsmul(out, 1, &multiplier, &out, 1, vDSP_Length(out.count))
        }
        return out
    }

    /// `Int8[dims]` → `Data`, little-endian row bytes (the `track_embedding.vector`
    /// BLOB layout, §15.7: raw `Int8[dims]`, no header).
    public static func data(_ int8: [Int8]) -> Data {
        int8.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}
