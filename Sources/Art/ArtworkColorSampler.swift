import CoreGraphics
import CoreImage

/// UIKit-free average-color sampling shared by `ArtworkService`. Uses a single
/// reused `CIContext` (creating one per call is expensive).
public enum ArtworkColorSampler {
    private static let sharedContext = CIContext()

    public static func averageColor(of image: CGImage) -> (red: UInt8, green: UInt8, blue: UInt8) {
        let fallback: (red: UInt8, green: UInt8, blue: UInt8) = (0, 122, 255)
        let ciImage = CIImage(cgImage: image)
        guard let filter = CIFilter(
            name: "CIAreaAverage",
            parameters: [
                kCIInputImageKey: ciImage,
                kCIInputExtentKey: CIVector(cgRect: ciImage.extent)
            ]
        ), let output = filter.outputImage else { return fallback }
        var pixel = [UInt8](repeating: 0, count: 4)
        sharedContext.render(
            output,
            toBitmap: &pixel,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: nil
        )
        return (pixel[0], pixel[1], pixel[2])
    }

    /// True when the image has no alpha channel and so fully covers anything behind it.
    public static func isOpaque(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return true
        default: return false
        }
    }
}
