import Foundation
import UIKit

enum WidgetArtworkStore {
    private static let targetSize: CGFloat = 180
    private static let compressionQuality: CGFloat = 0.7
    private static let artworkDir = "artwork"

    static func filename(for artworkID: String) -> String {
        let safe = artworkID.replacingOccurrences(of: "/", with: "_")
                     .replacingOccurrences(of: ":", with: "_")
                     .replacingOccurrences(of: " ", with: "_")
        let truncated = String(safe.prefix(120))
        return "\(truncated).jpg"
    }

    private static func containerURL() -> URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: WidgetSnapshotStore.appGroupIdentifier
        )
    }

    private static func artworkDirectory() -> URL? {
        guard let base = containerURL() else { return nil }
        let dir = base.appendingPathComponent(artworkDir)
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    static func imageURL(for filename: String) -> URL? {
        artworkDirectory()?.appendingPathComponent(filename)
    }

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

    static func prune(keeping filenames: Set<String>) {
        guard let dir = artworkDirectory(),
              let contents = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil) else { return }
        for url in contents where !filenames.contains(url.lastPathComponent) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
