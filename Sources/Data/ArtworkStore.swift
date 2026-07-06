import Foundation
import UIKit

actor ArtworkStore {
    static let shared = ArtworkStore()

    private let dir: URL
    private var memory = NSCache<NSString, UIImage>()

    init() {
        let base = try? FileManager.default.url(for: .applicationSupportDirectory,
                                                in: .userDomainMask, appropriateFor: nil, create: true)
        dir = (base ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appendingPathComponent("Tonearm/Artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    @discardableResult
    func store(_ data: Data) -> String? {
        guard let image = UIImage(data: data) else { return nil }
        let downscaled = image.downscaled(maxDimension: 1024)
        guard let jpeg = downscaled.jpegData(compressionQuality: 0.82) else { return nil }
        let id = UUID().uuidString
        let url = dir.appendingPathComponent("\(id).jpg")
        try? jpeg.write(to: url)
        return id
    }

    func image(id: String) -> UIImage? {
        if let cached = memory.object(forKey: id as NSString) { return cached }
        let url = dir.appendingPathComponent("\(id).jpg")
        guard let img = UIImage(contentsOfFile: url.path) else { return nil }
        memory.setObject(img, forKey: id as NSString)
        return img
    }
}

extension UIImage {
    func downscaled(maxDimension: CGFloat) -> UIImage {
        let maxSide = max(size.width, size.height)
        guard maxSide > maxDimension else { return self }
        let scale = maxDimension / maxSide
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}
