import XCTest
import Accelerate

@testable import TonearmDJ

/// §16.6 quantization: symmetric per-row int8, scale = max/127, zero-point 0.
final class QuantizationTests: XCTestCase {

    /// A deterministic unit vector of `dims` dimensions.
    private func unitVector(dims: Int, phase: Double) -> [Float] {
        let raw = (0..<dims).map { Float(sin(phase + Double($0) * 0.13)) }
        let norm = sqrt(raw.reduce(0) { $0 + $1 * $1 })
        return raw.map { $0 / norm }
    }

    func testQuantizeScaleIsMaxOver127() {
        let v: [Float] = [0.4, -0.6, 0.2, 0.0]
        let (int8, scale) = Quantization.quantize(v)
        XCTAssertEqual(scale, Float(0.6 / 127), accuracy: 1e-6)
        // 0.4 / (0.6/127) = 84.67 → rounds to 85; 0.2 · 211.67 = 42.33 → 42.
        XCTAssertEqual(int8, [85, -127, 42, 0])
    }

    func testRoundTripPreservesUnitVectorWithinQuantizationError() {
        let unit = unitVector(dims: 512, phase: 1.0)
        let (int8, scale) = Quantization.quantize(unit)
        let back = Quantization.dequantize(int8, scale: scale)
        // Per-element rounding error is ≤ scale/2; maxAbs of a 512-D unit vector
        // is ≥ 1/√512, so the bound is tight but comfortably below 1e-3.
        XCTAssertGreaterThan(scale, 0)
        for i in 0..<512 {
            XCTAssertEqual(back[i], unit[i], accuracy: scale,
                           "dim \(i) dequantized to \(back[i]), expected \(unit[i])")
        }
        var norm: Float = 0
        vDSP_dotpr(back, 1, back, 1, &norm, vDSP_Length(back.count))
        XCTAssertEqual(sqrt(norm), 1.0, accuracy: 0.01)
    }

    func testSymmetricHasNoZeroPoint() {
        let a = unitVector(dims: 64, phase: 2.0)
        let b = a.map { -$0 }
        let (int8A, scaleA) = Quantization.quantize(a)
        let (int8B, scaleB) = Quantization.quantize(b)
        XCTAssertEqual(scaleA, scaleB, accuracy: 1e-6)
        for i in 0..<a.count {
            XCTAssertEqual(int8A[i], -int8B[i], "zero-point must be exactly 0")
        }
    }

    func testClampsToInt8Range() {
        let v: [Float] = [10_000, -10_000, 1e-30]
        let (int8, scale) = Quantization.quantize(v)
        XCTAssertEqual(int8[0], 127)
        XCTAssertEqual(int8[1], -127)
        XCTAssertEqual(int8[2], 0)
        XCTAssertEqual(scale, 10_000 / 127, accuracy: 1e-2)
    }

    func testAllZeroVectorYieldsZeroScale() {
        let (int8, scale) = Quantization.quantize([Float](repeating: 0, count: 32))
        XCTAssertEqual(scale, 0)
        XCTAssertTrue(int8.allSatisfy { $0 == 0 })
        let back = Quantization.dequantize(int8, scale: scale)
        XCTAssertTrue(back.allSatisfy { $0 == 0 })
    }

    func testDataLayoutIsRawInt8NoHeader() {
        let int8: [Int8] = [1, -2, 127, -128]
        let data = Quantization.data(int8)
        XCTAssertEqual(data, Data([1, 254, 127, 128]))
        let back = data.withUnsafeBytes { Array($0.bindMemory(to: Int8.self)) }
        XCTAssertEqual(back, int8)
    }
}
