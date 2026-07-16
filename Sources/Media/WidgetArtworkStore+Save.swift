import Foundation
import UIKit

/// The UIKit half of `WidgetArtworkStore`: downscales and JPEG-encodes the now-
/// playing artwork into the shared App Group directory. Kept app-side so Core
/// (the snapshot builder) stays host-compilable.
extension WidgetArtworkStore {
    @discardableResult
    static func save(image: UIImage, for artworkID: String) -> String? {
        guard let dir = artworkDirectory() else { return nil }
        let size = image.size
        let scale = min(1, min(targetSize / size.width, targetSize / size.height))
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)

        UIGraphicsBeginImageContextWithOptions(newSize, true, 1)
        defer { UIGraphicsEndImageContext() }
        image.draw(in: CGRect(origin: .zero, size: newSize))
        guard let downscaled = UIGraphicsGetImageFromCurrentImageContext(),
              let data = downscaled.jpegData(compressionQuality: compressionQuality) else {
            return nil
        }

        let name = filename(for: artworkID)
        let url = dir.appendingPathComponent(name)
        do {
            try data.write(to: url, options: .atomic)
            return name
        } catch {
            print("WidgetArtworkStore: failed to write artwork: \(error)")
            return nil
        }
    }
}
