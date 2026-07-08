import Foundation
import UIKit
import AVFoundation

actor ArtworkService {
    static let shared = ArtworkService()

    private let memCache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 100
        c.totalCostLimit = 50 * 1024 * 1024
        return c
    }()

    private static let notFoundSentinel = UIImage()

    private let diskCacheDir: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Tonearm/artwork_cache")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 15
        return URLSession(configuration: cfg)
    }()

    private init() {}

    func artwork(forIdentifier identifier: String) async -> UIImage? {
        let key = identifier as NSString

        if let cached = memCache.object(forKey: key) {
            return cached === Self.notFoundSentinel ? nil : cached
        }

        if let image = readDiskCache(key: identifier) {
            store(image, forKey: key)
            return image
        }

        let encoded = identifier.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? identifier
        let urlString = "https://archive.org/services/img/\(encoded)"
        guard let url = URL(string: urlString) else {
            print("[ArtworkService] cannot build URL for identifier: \(identifier)")
            memCache.setObject(Self.notFoundSentinel, forKey: key)
            return nil
        }

        do {
            let (data, response) = try await session.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse else {
                print("[ArtworkService] non-HTTP response for: \(identifier)")
                return nil
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                print("[ArtworkService] HTTP \(httpResponse.statusCode) for: \(identifier)")
                if httpResponse.statusCode == 404 {
                    memCache.setObject(Self.notFoundSentinel, forKey: key)
                }
                return nil
            }

            if let finalURL = httpResponse.url, finalURL.lastPathComponent == "notfound.png" {
                print("[ArtworkService] notfound.png redirect for: \(identifier)")
                memCache.setObject(Self.notFoundSentinel, forKey: key)
                return nil
            }

            guard data.count > 2048, let image = UIImage(data: data) else {
                print("[ArtworkService] data too small or invalid image for: \(identifier) (\(data.count) bytes)")
                if httpResponse.statusCode != 200 || data.count < 100 {
                    memCache.setObject(Self.notFoundSentinel, forKey: key)
                }
                return nil
            }

            store(image, forKey: key)
            writeDiskCache(image, key: identifier)
            return image
        } catch {
            print("[ArtworkService] fetch error for \(identifier): \(error.localizedDescription)")
            return nil
        }
    }

    func artwork(forTrackRow row: TrackRow) async -> UIImage? {
        if let id = row.album?.artworkId, !id.isEmpty {
            return await artwork(forIdentifier: id)
        }

        guard let asset = row.asset else { return nil }

        let trackKey = "local-\(row.track.id ?? -1)"

        if let cached = memCache.object(forKey: trackKey as NSString) {
            return cached === Self.notFoundSentinel ? nil : cached
        }
        if let image = readDiskCache(key: trackKey) {
            store(image, forKey: trackKey as NSString)
            return image
        }

        let url: URL?
        if let bookmark = asset.bookmark, let (resolved, _) = BookmarkVault.resolve(bookmark) {
            url = resolved
        } else if let rel = asset.relPath {
            let base = try? FileManager.default.url(for: .applicationSupportDirectory,
                                                    in: .userDomainMask, appropriateFor: nil, create: true)
            url = base?.appendingPathComponent(rel)
        } else {
            url = nil
        }

        guard let fileURL = url else {
            memCache.setObject(Self.notFoundSentinel, forKey: trackKey as NSString)
            return nil
        }

        let needsScopedAccess = asset.bookmark != nil
        if needsScopedAccess { _ = fileURL.startAccessingSecurityScopedResource() }
        defer { if needsScopedAccess { fileURL.stopAccessingSecurityScopedResource() } }

        let avAsset = AVURLAsset(url: fileURL)
        guard let metadata = try? await avAsset.load(.commonMetadata),
              let item = metadata.first(where: { $0.commonKey == .commonKeyArtwork }),
              let data = try? await item.load(.dataValue),
              let image = UIImage(data: data) else {
            memCache.setObject(Self.notFoundSentinel, forKey: trackKey as NSString)
            return nil
        }

        store(image, forKey: trackKey as NSString)
        writeDiskCache(image, key: trackKey)
        return image
    }

    @MainActor
    static func dominantColor(from image: UIImage) -> UIColor {
        guard let ciImage = CIImage(image: image) else { return .systemBlue }
        let filter = CIFilter(
            name: "CIAreaAverage",
            parameters: [
                kCIInputImageKey: ciImage,
                kCIInputExtentKey: CIVector(cgRect: ciImage.extent)
            ]
        )
        guard let output = filter?.outputImage else { return .systemBlue }
        var pixel = [UInt8](repeating: 0, count: 4)
        CIContext().render(
            output,
            toBitmap: &pixel,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: nil
        )
        return UIColor(
            red: CGFloat(pixel[0]) / 255,
            green: CGFloat(pixel[1]) / 255,
            blue: CGFloat(pixel[2]) / 255,
            alpha: 1
        )
    }

    private func store(_ image: UIImage, forKey key: NSString) {
        let cost = Int(image.size.width * image.size.height * 4)
        memCache.setObject(image, forKey: key, cost: cost)
    }

    private func diskCacheURL(key: String) -> URL {
        let hash = key.utf8.reduce(UInt64(14695981039346656037)) {
            ($0 ^ UInt64($1)) &* 1099511628211
        }
        return diskCacheDir.appendingPathComponent(String(format: "%016llx.jpg", hash))
    }

    private func readDiskCache(key: String) -> UIImage? {
        let url = diskCacheURL(key: key)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attrs[.modificationDate] as? Date,
              Date().timeIntervalSince(modified) < 7 * 86400,
              let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    private func writeDiskCache(_ image: UIImage, key: String) {
        guard let data = image.jpegData(compressionQuality: 0.85) else { return }
        try? data.write(to: diskCacheURL(key: key))
    }
}
