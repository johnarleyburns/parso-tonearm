import CoreGraphics
import Foundation

#if canImport(UIKit)
import UIKit
#endif

public struct SpectrogramDetector {
    private let sampleSize: Int
    private let grayThreshold: Double
    private let entropyThreshold: Double
    private let channelTolerance: Int

    public init(sampleSize: Int = 20,
                grayThreshold: Double = 0.85,
                entropyThreshold: Double = 4.0,
                channelTolerance: Int = 25) {
        self.sampleSize = sampleSize
        self.grayThreshold = grayThreshold
        self.entropyThreshold = entropyThreshold
        self.channelTolerance = channelTolerance
    }

    #if canImport(UIKit)
    public func isSpectrogram(_ image: UIImage) -> Bool {
        guard let cgImage = image.cgImage else { return false }
        return isSpectrogram(cgImage)
    }
    #endif

    public func isSpectrogram(_ cgImage: CGImage) -> Bool {
        guard let context = CGContext(
            data: nil,
            width: sampleSize,
            height: sampleSize,
            bitsPerComponent: 8,
            bytesPerRow: sampleSize * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: sampleSize, height: sampleSize))
        guard let data = context.data else { return false }

        let pixels = data.bindMemory(to: UInt8.self, capacity: sampleSize * sampleSize * 4)
        let totalPixels = sampleSize * sampleSize

        let (grayRatio, entropy) = analyze(pixels, count: totalPixels)

        guard grayRatio > grayThreshold else { return false }
        return entropy < entropyThreshold
    }

    private func analyze(_ pixels: UnsafeMutablePointer<UInt8>, count: Int) -> (grayRatio: Double, entropy: Double) {
        var grayCount = 0
        var histogram = [Int](repeating: 0, count: 256)
        let tolerance = channelTolerance

        for i in 0..<count {
            let idx = i * 4
            let r = Int(pixels[idx])
            let g = Int(pixels[idx + 1])
            let b = Int(pixels[idx + 2])

            if abs(r - g) < tolerance,
               abs(r - b) < tolerance,
               abs(g - b) < tolerance {
                grayCount += 1
            }

            let brightness = (r + g + b) / 3
            histogram[min(255, brightness)] += 1
        }

        let grayRatio = Double(grayCount) / Double(count)

        var entropy: Double = 0
        let pixelCount = Double(count)
        for bucket in histogram {
            guard bucket > 0 else { continue }
            let p = Double(bucket) / pixelCount
            entropy -= p * log2(p)
        }

        return (grayRatio, entropy)
    }
}
