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

    /// Bump to wipe stale disk/mem caches on next launch (e.g. after fixing
    /// cover-resolution logic so old waveform images re-resolve).
    static let cacheGeneration = 2

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

    /// User setting (FR): when false, no external iTunes artwork lookups occur.
    private var artworkLookupEnabled = true

    func setArtworkLookupEnabled(_ enabled: Bool) {
        artworkLookupEnabled = enabled
    }

    /// Purges the on-disk artwork cache and empties the in-memory cache if the
    /// stored generation doesn't match the current one, then stores the current
    /// generation so the wipe only happens once per bump.
    func migrateCacheIfNeeded() {
        let key = "artworkCacheGeneration"
        let stored = UserDefaults.standard.integer(forKey: key)
        guard stored < Self.cacheGeneration else { return }

        if let contents = try? FileManager.default.contentsOfDirectory(at: diskCacheDir,
                                                                       includingPropertiesForKeys: nil) {
            for url in contents {
                try? FileManager.default.removeItem(at: url)
            }
        }
        memCache.removeAllObjects()
        UserDefaults.standard.set(Self.cacheGeneration, forKey: key)
    }

    func artwork(forIdentifier identifier: String) async -> UIImage? {
        let key = identifier as NSString

        if let cached = memCache.object(forKey: key) {
            return cached === Self.notFoundSentinel ? nil : cached
        }

        if let image = readDiskCache(key: identifier) {
            store(image, forKey: key)
            return image
        }

        // Metadata-driven cover resolution: fetch the IA metadata files list
        // and let IACoverPicker select the genuine cover, distinguishing real
        // album art from auto-generated waveform/spectrogram/thumbnail images.
        guard let metaURL = URL(string: "https://archive.org/metadata/\(identifier)") else {
            memCache.setObject(Self.notFoundSentinel, forKey: key)
            return nil
        }

        do {
            let metaData = try await IAClient.shared.data(from: metaURL)
            let response = try JSONDecoder().decode(IAMetadataResponse.self, from: metaData)
            guard let files = response.files,
                  let coverFilename = IACoverPicker.pickCoverFilename(files: files) else {
                memCache.setObject(Self.notFoundSentinel, forKey: key)
                return nil
            }

            let encoded = identifier.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? identifier
            let fileEncoded = coverFilename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? coverFilename
            guard let coverURL = URL(string: "https://archive.org/download/\(encoded)/\(fileEncoded)") else {
                return nil
            }

            let imageData: Data
            do {
                imageData = try await IAClient.shared.data(from: coverURL)
            } catch {
                print("[ArtworkService] cover download error for \(identifier)/\(coverFilename): \(error.localizedDescription)")
                return nil
            }

            guard imageData.count > 2048, let image = UIImage(data: imageData) else {
                print("[ArtworkService] data too small or invalid image for: \(identifier) (\(imageData.count) bytes)")
                return nil
            }

            let w = image.size.width, h = image.size.height
            if w > 0, h > 0, max(w, h) / min(w, h) >= 2.0 {
                print("[ArtworkService] extreme aspect for: \(identifier) (\(Int(w))×\(Int(h)))")
                memCache.setObject(Self.notFoundSentinel, forKey: key)
                return nil
            }

            if SpectrogramDetector().isSpectrogram(image) {
                print("[ArtworkService] probable spectrogram for: \(identifier) (\(Int(w))×\(Int(h)))")
                memCache.setObject(Self.notFoundSentinel, forKey: key)
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

    /// Returns the first identifier (in order) that resolves to a real cover,
    /// skipping IA "image not available" placeholders. Used to pick a
    /// representative image for list/collection/source tiles.
    func firstAvailableIdentifier(_ identifiers: [String]) async -> String? {
        for id in identifiers where !id.isEmpty {
            if await artwork(forIdentifier: id) != nil {
                return id
            }
        }
        return nil
    }

    func artwork(forTrackRow row: TrackRow) async -> UIImage? {
        await trackArtwork(forTrackRow: row)?.image
    }

    /// Resolves a track's artwork and reports whether the match is strong enough to
    /// be remembered as a source's representative cover. Embedded art and IA covers
    /// are always persistable; iTunes fallbacks are persistable only on a strong
    /// (artist + album/track aligned) match.
    func trackArtwork(forTrackRow row: TrackRow) async -> (image: UIImage, persistable: Bool)? {
        // 1. IA identifier cover (strong).
        if let id = row.album?.artworkId, !id.isEmpty {
            if let image = await artwork(forIdentifier: id) { return (image, true) }
        }

        let trackId = row.track.id ?? -1
        let isRemote = row.asset?.kind == .remote

        // For IA tracks the album row carries real artist/title; for local files the
        // album is a placeholder ("Local Files"/folder), so ignore it and rely on
        // embedded tags harvested below.
        var tagArtist: String? = isRemote ? row.album?.artist : nil
        var tagAlbum: String? = isRemote ? row.album?.title : nil
        var tagTitle: String? = row.track.title

        // 2. Local embedded artwork (strong), harvesting tags for a later iTunes query.
        if let asset = row.asset, !isRemote {
            let trackKey = "local-\(trackId)"
            if let cached = memCache.object(forKey: trackKey as NSString) {
                if cached !== Self.notFoundSentinel { return (cached, true) }
            } else if let image = readDiskCache(key: trackKey) {
                store(image, forKey: trackKey as NSString)
                return (image, true)
            } else {
                let local = await loadLocalFile(asset: asset)
                tagArtist = local.artist ?? tagArtist
                tagAlbum = local.album ?? tagAlbum
                tagTitle = local.title ?? tagTitle
                if let image = local.image {
                    store(image, forKey: trackKey as NSString)
                    writeDiskCache(image, key: trackKey)
                    return (image, true)
                } else {
                    memCache.setObject(Self.notFoundSentinel, forKey: trackKey as NSString)
                }
            }
        }

        // 3. iTunes fallback (persistable only when strong).
        if let result = await iTunesArtwork(trackId: trackId, artist: tagArtist,
                                            album: tagAlbum, title: tagTitle) {
            return result
        }
        return nil
    }

    /// External iTunes artwork lookup for a track, keyed and cached separately from
    /// embedded/IA art so a miss on one path doesn't block the other.
    private func iTunesArtwork(trackId: Int64, artist: String?, album: String?,
                              title: String?) async -> (image: UIImage, persistable: Bool)? {
        guard artworkLookupEnabled else { return nil }
        let key = "itunes-\(trackId)"

        if let cached = memCache.object(forKey: key as NSString) {
            return cached === Self.notFoundSentinel ? nil : (cached, false)
        }
        if let image = readDiskCache(key: key) {
            store(image, forKey: key as NSString)
            return (image, false)
        }

        guard let match = await ArtworkSearchClient.shared.artwork(artist: artist, album: album,
                                                                   trackTitle: title) else {
            memCache.setObject(Self.notFoundSentinel, forKey: key as NSString)
            return nil
        }
        guard let data = try? await ArtworkSearchClient.shared.imageData(from: match.artworkURL),
              data.count > 2048, let image = UIImage(data: data) else {
            memCache.setObject(Self.notFoundSentinel, forKey: key as NSString)
            return nil
        }
        let w = image.size.width, h = image.size.height
        if w > 0, h > 0, max(w, h) / min(w, h) >= 2.0 {
            memCache.setObject(Self.notFoundSentinel, forKey: key as NSString)
            return nil
        }

        store(image, forKey: key as NSString)
        writeDiskCache(image, key: key)
        return (image, match.isStrong)
    }

    /// Loads a local file's embedded artwork and common tags (artist/album/title) in
    /// a single metadata pass.
    private func loadLocalFile(asset: Asset) async
        -> (image: UIImage?, artist: String?, album: String?, title: String?) {
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

        guard let fileURL = url else { return (nil, nil, nil, nil) }

        let needsScopedAccess = asset.bookmark != nil
        if needsScopedAccess { _ = fileURL.startAccessingSecurityScopedResource() }
        defer { if needsScopedAccess { fileURL.stopAccessingSecurityScopedResource() } }

        let avAsset = AVURLAsset(url: fileURL)
        guard let metadata = try? await avAsset.load(.commonMetadata) else {
            return (nil, nil, nil, nil)
        }

        var image: UIImage?
        var artist: String?
        var album: String?
        var title: String?
        for item in metadata {
            guard let commonKey = item.commonKey else { continue }
            switch commonKey {
            case .commonKeyArtwork:
                if let data = try? await item.load(.dataValue) { image = UIImage(data: data) }
            case .commonKeyArtist:
                artist = try? await item.load(.stringValue)
            case .commonKeyAlbumName:
                album = try? await item.load(.stringValue)
            case .commonKeyTitle:
                title = try? await item.load(.stringValue)
            default:
                break
            }
        }
        return (image, artist, album, title)
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
        // Renew the entry's lifetime on access so artwork stays cached as long as
        // its music keeps being played, rather than expiring out from under it.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return UIImage(data: data)
    }

    /// Purges the on-disk and in-memory artwork caches. Call alongside clearing
    /// the streaming cache so artwork and its music are cleared together.
    func clearAll() {
        if let contents = try? FileManager.default.contentsOfDirectory(at: diskCacheDir,
                                                                       includingPropertiesForKeys: nil) {
            for url in contents {
                try? FileManager.default.removeItem(at: url)
            }
        }
        memCache.removeAllObjects()
    }

    private func writeDiskCache(_ image: UIImage, key: String) {
        guard let data = image.jpegData(compressionQuality: 0.85) else { return }
        try? data.write(to: diskCacheURL(key: key))
    }
}
