import Testing
import CoreGraphics
@testable import TonearmCore

@Suite struct ArtworkColorSamplerTests {

    private func makeImage(width: Int, height: Int, color: (Int) -> (UInt8, UInt8, UInt8)) -> CGImage {
        var data = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = color(x)
                let i = (y * width + x) * 4
                data[i] = r; data[i + 1] = g; data[i + 2] = b; data[i + 3] = 255
            }
        }
        let provider = CGDataProvider(data: Data(data) as CFData)!
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent)!
    }

    private func assertClose(_ c: (red: UInt8, green: UInt8, blue: UInt8),
                             _ e: (Int, Int, Int), sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(abs(Int(c.red) - e.0) <= 8, sourceLocation: sourceLocation)
        #expect(abs(Int(c.green) - e.1) <= 8, sourceLocation: sourceLocation)
        #expect(abs(Int(c.blue) - e.2) <= 8, sourceLocation: sourceLocation)
    }

    @Test func testSolidRed() {
        let img = makeImage(width: 4, height: 4) { _ in (255, 0, 0) }
        assertClose(ArtworkColorSampler.averageColor(of: img), (255, 0, 0))
    }

    @Test func testHalfRedHalfBlueAveragesToMidpoint() {
        let img = makeImage(width: 4, height: 4) { x in x < 2 ? (255, 0, 0) : (0, 0, 255) }
        assertClose(ArtworkColorSampler.averageColor(of: img), (128, 0, 128))
    }

    @Test func testRepeatedCallsSucceed() {
        let img = makeImage(width: 4, height: 4) { _ in (255, 0, 0) }
        assertClose(ArtworkColorSampler.averageColor(of: img), (255, 0, 0))
        assertClose(ArtworkColorSampler.averageColor(of: img), (255, 0, 0))
    }

    @Test func testOpacityDetection() {
        let img = makeImage(width: 2, height: 2) { _ in (1, 2, 3) }
        #expect(ArtworkColorSampler.isOpaque(img))
    }
}
