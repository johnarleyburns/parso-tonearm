import XCTest
import UIKit
@testable import Tonearm

final class SpectrogramDetectorTests: XCTestCase {

    private let detector = SpectrogramDetector()

    // MARK: - Helpers

    /// Creates a UIImage with raw RGBA bytes (20×20 avoids downsampling distortion
    /// since the detector resamples to 20×20 internally).
    private func makeImage(pixelRGBA: (Int, Int) -> (UInt8, UInt8, UInt8)) -> UIImage {
        let w = 20, h = 20
        let size = w * h * 4
        var bytes = [UInt8](repeating: 255, count: size)
        for y in 0..<h {
            for x in 0..<w {
                let idx = (y * w + x) * 4
                let (r, g, b) = pixelRGBA(x, y)
                bytes[idx]     = r
                bytes[idx + 1] = g
                bytes[idx + 2] = b
                bytes[idx + 3] = 255
            }
        }
        let ctx = CGContext(
            data: &bytes,
            width: w, height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return UIImage(cgImage: ctx.makeImage()!)
    }

    // MARK: - Spectrogram detections

    func testDetectsGrayscaleSmoothGradient() {
        // A grayscale gradient with ≤16 distinct levels (at 20×20 resolution)
        // has entropy < 4.0 → spectrogram. Using 8 bands across the vertical axis.
        let img = makeImage { _, y in
            let v = UInt8((y / 3) * 32)
            return (v, v, v)
        }
        XCTAssertTrue(detector.isSpectrogram(img),
                       "Grayscale gradient with few bands should be detected as spectrogram")
    }

    func testDetectsNearGrayscaleWithLowEntropy() {
        // Few distinct brightness bands (near-gray) → low entropy.
        let img = makeImage { _, y in
            let v = UInt8((y / 5) * 60)
            return (v, UInt8(max(0, Int(v) - 8)), UInt8(min(255, Int(v) + 8)))
        }
        XCTAssertTrue(detector.isSpectrogram(img),
                       "Near-grayscale image with few bands (low entropy) should be spectrogram")
    }

    func testDetectsGrayscaleWithFewBands() {
        // Simulates a spectrogram: few horizontal brightness bands.
        let img = makeImage { _, y in
            let band = y / 4
            let v = UInt8(50 + (band % 5) * 40)
            return (v, v, v)
        }
        XCTAssertTrue(detector.isSpectrogram(img),
                       "Grayscale image with few brightness bands (spectrogram-like) should be detected")
    }

    // MARK: - Non-spectrogram rejections

    func testRejectsColorPhoto() {
        // Bright, distinct colors scattered across the image. Each 2×2 block
        // has a different saturated color so no averaging to gray.
        let colors: [(UInt8, UInt8, UInt8)] = [
            (255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 255, 0),
            (255, 0, 255), (0, 255, 255), (255, 128, 0), (128, 0, 255),
            (0, 128, 255), (128, 255, 0)
        ]
        let img = makeImage { x, y in
            let idx = (x / 2 + y / 2 * 10) % colors.count
            return colors[idx]
        }
        XCTAssertFalse(detector.isSpectrogram(img),
                        "Colorful block image should not be detected as spectrogram")
    }

    func testRejectsBWCrispPhoto() {
        // Scattered grayscale with many distinct brightness values → high entropy.
        let img = makeImage { x, y in
            let v = UInt8((x * 13 + y * 17) % 256)
            return (v, v, v)
        }
        XCTAssertFalse(detector.isSpectrogram(img),
                        "Grayscale photo with many distinct levels (high entropy) should not be spectrogram")
    }

    func testRejectsGrayscalePhotoWithDetail() {
        // Grayscale image with many brightness levels scattered randomly.
        let img = makeImage { x, y in
            let v = UInt8((x * 13 + y * 17 + (x ^ y) * 7) % 256)
            return (v, v, v)
        }
        XCTAssertFalse(detector.isSpectrogram(img),
                        "Grayscale photo with detail (high entropy) should not be spectrogram")
    }

    // MARK: - Edge cases (low entropy = treated like spectrogram)

    func testSolidBlackIsRejectedBecauseLowEntropy() {
        let img = makeImage { _, _ in (0, 0, 0) }
        XCTAssertTrue(detector.isSpectrogram(img),
                       "Solid black has zero entropy and should be rejected")
    }

    func testSolidWhiteIsRejectedBecauseLowEntropy() {
        let img = makeImage { _, _ in (255, 255, 255) }
        XCTAssertTrue(detector.isSpectrogram(img),
                       "Solid white has zero entropy and should be rejected")
    }

    // MARK: - Configurable thresholds

    func testCustomEntropyThreshold() {
        // With a very strict entropy threshold (1.0), only near-empty images
        // are flagged. The scattered grayscale pattern should pass.
        let strict = SpectrogramDetector(entropyThreshold: 1.0)
        let img = makeImage { x, y in
            let v = UInt8((x * 13 + y * 17) % 256)
            return (v, v, v)
        }
        XCTAssertFalse(strict.isSpectrogram(img),
                        "Scattered grayscale should pass with strict entropy threshold")
    }

    func testPermissiveGrayThreshold() {
        // With grayThreshold = 1.0, the gray check always passes → only entropy matters.
        // A colorful photo has high entropy and should still pass.
        let permissive = SpectrogramDetector(grayThreshold: 1.0)
        let colors: [(UInt8, UInt8, UInt8)] = [
            (255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 255, 0),
            (255, 0, 255), (0, 255, 255), (255, 128, 0), (128, 0, 255),
        ]
        let img = makeImage { x, y in
            let idx = (x / 2 + y / 2 * 10) % colors.count
            return colors[idx]
        }
        XCTAssertFalse(permissive.isSpectrogram(img),
                        "Colorful photo has high entropy, bypassing gray check")
    }
}
