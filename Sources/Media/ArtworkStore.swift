import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

actor ArtworkStore {
    static let shared = ArtworkStore()

    private let dir: URL
    private var memory = NSCache<NSString, PlatformImage>()

    init() {
        let base = try? FileManager.default.url(for: .applicationSupportDirectory,
                                                in: .userDomainMask, appropriateFor: nil, create: true)
        dir = (base ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appendingPathComponent("Tonearm/Artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    @discardableResult
    func store(_ data: Data) -> String? {
        guard let image = PlatformImage(data: data) else { return nil }
        let downscaled = image.downscaled(maxDimension: 1024)
        guard let jpeg = downscaled.tonearmJPEGData(compressionQuality: 0.82) else { return nil }
        let id = UUID().uuidString
        let url = dir.appendingPathComponent("\(id).jpg")
        try? jpeg.write(to: url)
        return id
    }

    func image(id: String) -> PlatformImage? {
        if let cached = memory.object(forKey: id as NSString) { return cached }
        let url = dir.appendingPathComponent("\(id).jpg")
        guard let img = PlatformImage(contentsOfFile: url.path) else { return nil }
        memory.setObject(img, forKey: id as NSString)
        return img
    }

    func fileURL(id: String) -> URL { dir.appendingPathComponent("\(id).jpg") }

    func fileURLIfPresent(id: String) -> URL? {
        let url = fileURL(id: id)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Persists a deterministic watch derivative under its content address while keeping the
    /// phone's existing custom-art lookup path (`<id>.jpg`) intact.
    func storeWatchVariant(_ data: Data, artworkID: String) -> Bool {
        guard PlatformImage(data: data) != nil else { return false }
        do { try data.write(to: fileURL(id: artworkID), options: .atomic); return true }
        catch { return false }
    }

    func delete(id: String) {
        memory.removeObject(forKey: id as NSString)
        let url = dir.appendingPathComponent("\(id).jpg")
        try? FileManager.default.removeItem(at: url)
    }
}

extension PlatformImage {
    func downscaled(maxDimension: CGFloat) -> PlatformImage {
        let maxSide = max(size.width, size.height)
        guard maxSide > maxDimension else { return self }
        let scale = maxDimension / maxSide
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        #if os(macOS)
        return PlatformImage(size: newSize, flipped: false) { rect in
            self.draw(in: rect, from: .zero, operation: .copy, fraction: 1)
            return true
        }
        #else
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: newSize))
        }
        #endif
    }

    /// Cross-platform JPEG encode — `NSImage` has no `jpegData(compressionQuality:)`
    /// the way `UIImage` does, so macOS routes through `NSBitmapImageRep`.
    func tonearmJPEGData(compressionQuality: CGFloat) -> Data? {
        #if os(macOS)
        guard let tiff = tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: compressionQuality])
        #else
        return jpegData(compressionQuality: compressionQuality)
        #endif
    }
}
