import Foundation
import UIKit
import AVFoundation
import CoreImage
import TonearmCore

/// Tags plus an already-bounded cover thumbnail for one local file.
struct LocalFileMetadata: Sendable {
    var artwork: DownsampledArtwork?
    var artist: String?
    var album: String?
    var title: String?
}

actor ArtworkService {
    static let shared: ArtworkService = {
        let service = ArtworkService()
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
                                               object: nil, queue: nil) { _ in
            Task { await ArtworkService.shared.purgeForMemoryWarning() }
        }
        return service
    }()

    private let memCache: NSCache<NSString, PlatformImage> = {
        let c = NSCache<NSString, PlatformImage>()
        c.countLimit = 100
        c.totalCostLimit = 50 * 1024 * 1024
        return c
    }()

    private static let notFoundSentinel = PlatformImage()

    /// Bump to wipe stale disk/mem caches on next launch (e.g. after fixing
    /// cover-resolution logic so old waveform images re-resolve).
    static let cacheGeneration = 2

    private let diskCacheDir: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Tonearm/artwork_cache")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// A SEPARATE, small in-memory cache for downscaled list-row thumbnails
    /// — never the same cache as `memCache` above, which holds full-resolution
    /// covers. A SwiftUI `List` rendering thousands of track rows must never
    /// decode/hold a full-size cover just to paint a 36pt icon (user's
    /// explicit ask: "cache a SMALL version... so we don't slow down the
    /// scroll... be smart about SwiftUI list implementation with images").
    /// Small entries, so this can comfortably hold far more of them than
    /// `memCache` without the memory cost of full covers.
    private let thumbnailMemCache: NSCache<NSString, PlatformImage> = {
        let c = NSCache<NSString, PlatformImage>()
        c.countLimit = 1000
        c.totalCostLimit = 24 * 1024 * 1024
        return c
    }()

    private let thumbnailDiskCacheDir: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Tonearm/artwork_thumb_cache")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 15
        return URLSession(configuration: cfg)
    }()

    typealias LocalFileLoader = @Sendable (Asset) async -> LocalFileMetadata?

    private let localLoader: LocalFileLoader
    private let localFlights = SingleFlight<LocalFileMetadata>()

    private init() { localLoader = Self.liveLocalLoader }

    /// Test seam: inject the metadata loader (no Files-provider grant needed).
    init(localLoader: @escaping LocalFileLoader) { self.localLoader = localLoader }

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
        if let contents = try? FileManager.default.contentsOfDirectory(at: thumbnailDiskCacheDir,
                                                                       includingPropertiesForKeys: nil) {
            for url in contents {
                try? FileManager.default.removeItem(at: url)
            }
        }
        memCache.removeAllObjects()
        thumbnailMemCache.removeAllObjects()
        UserDefaults.standard.set(Self.cacheGeneration, forKey: key)
    }

    func artwork(forIdentifier identifier: String) async -> PlatformImage? {
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
                AppLogger.artwork.error("Cover download failed for \(identifier, privacy: .public)/\(coverFilename, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return nil
            }

            guard imageData.count > 2048, let image = PlatformImage(data: imageData) else {
            AppLogger.artwork.debug("Artwork data too small or invalid for \(identifier, privacy: .public) (\(imageData.count) bytes)")
                return nil
            }

            let w = image.size.width, h = image.size.height
            if w > 0, h > 0, max(w, h) / min(w, h) >= 2.0 {
            AppLogger.artwork.debug("Artwork has extreme aspect for \(identifier, privacy: .public) (\(Int(w))×\(Int(h)))")
                memCache.setObject(Self.notFoundSentinel, forKey: key)
                return nil
            }

            if let cgImage = image.tonearmCGImage, SpectrogramDetector().isSpectrogram(cgImage) {
            AppLogger.artwork.debug("Artwork looks like a spectrogram for \(identifier, privacy: .public) (\(Int(w))×\(Int(h)))")
                memCache.setObject(Self.notFoundSentinel, forKey: key)
                return nil
            }

            store(image, forKey: key)
            writeDiskCache(image, key: identifier)
            return image
        } catch {
            AppLogger.artwork.error("Artwork fetch failed for \(identifier, privacy: .public): \(error.localizedDescription, privacy: .public)")
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

    /// A small, persistently-cached thumbnail for list-row icons — derived
    /// from whatever `artwork(forTrackRow:)` already resolves (custom art,
    /// embedded tags, IA/Jamendo remote artwork, iTunes fallback — every
    /// source that method already handles), never a second network fetch.
    /// Cached separately from the full-resolution image, keyed by track id
    /// AND `maxDimension` (a Now Playing-sized request and a 36pt row icon
    /// must never collide on one cache entry). `maxDimension` is in points;
    /// the actual pixel size scales for the device's screen scale so the
    /// thumbnail still looks sharp, never blurry, at its real render size.
    func thumbnail(forTrackRow row: TrackRow, maxDimension: CGFloat) async -> PlatformImage? {
        let trackId = row.track.id ?? -1
        let screenScale = await resolvedScreenScale()
        let pixelDimension = maxDimension * screenScale
        let cacheKey = "track-\(trackId)-\(Int(pixelDimension))" as NSString

        if let cached = thumbnailMemCache.object(forKey: cacheKey) {
            return cached === Self.notFoundSentinel ? nil : cached
        }
        if let onDisk = readThumbnailDiskCache(key: cacheKey as String) {
            thumbnailMemCache.setObject(onDisk, forKey: cacheKey, cost: thumbnailCost(onDisk))
            return onDisk
        }
        guard let full = await artwork(forTrackRow: row) else {
            thumbnailMemCache.setObject(Self.notFoundSentinel, forKey: cacheKey)
            return nil
        }
        let thumb = Self.downsampled(full, maxPixelDimension: pixelDimension)
        thumbnailMemCache.setObject(thumb, forKey: cacheKey, cost: thumbnailCost(thumb))
        writeThumbnailDiskCache(thumb, key: cacheKey as String)
        return thumb
    }

    private var memoizedScreenScale: CGFloat?
    private var observingSceneChanges = false

    /// Screen scale is MainActor-isolated, so it is resolved with a hop once and memoized;
    /// cache hits never leave this actor. The memo is dropped whenever a scene connects or
    /// disconnects (the only time the sharpest connected screen can change). The sharpest
    /// connected screen wins.
    private func resolvedScreenScale() async -> CGFloat {
        if let memoizedScreenScale { return memoizedScreenScale }
        if !observingSceneChanges {
            observingSceneChanges = true
            for name in [UIScene.didActivateNotification, UIScene.didDisconnectNotification, UIScene.willConnectNotification] {
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                    Task { await self?.invalidateScreenScale() }
                }
            }
        }
        let scale = await MainActor.run { () -> CGFloat in
            UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.screen.scale }
                .max() ?? UITraitCollection.current.displayScale
        }
        memoizedScreenScale = scale
        return scale
    }

    private func invalidateScreenScale() {
        memoizedScreenScale = nil
    }

    private func thumbnailCost(_ image: PlatformImage) -> Int {
        Int(image.size.width * image.size.height * image.platformScale * image.platformScale * 4)
    }

    /// Fast, correct-orientation downscale — cheap relative to the
    /// list-scroll cost this exists to avoid, since it runs once per track
    /// and is cached forever after (both in memory and on disk), never per
    /// frame. The renderer keeps list thumbnails independent from full-size
    /// artwork.
    private static func downsampled(_ image: PlatformImage, maxPixelDimension: CGFloat) -> PlatformImage {
        let scale = image.platformScale
        let pixelSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        guard pixelSize.width > 0, pixelSize.height > 0 else { return image }
        let downscale = min(1, maxPixelDimension / max(pixelSize.width, pixelSize.height))
        guard downscale < 1 else { return image }
        let targetPointSize = CGSize(width: image.size.width * downscale, height: image.size.height * downscale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: targetPointSize, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetPointSize))
        }
    }

    private func thumbnailDiskCacheURL(key: String) -> URL {
        let hash = key.utf8.reduce(UInt64(14695981039346656037)) {
            ($0 ^ UInt64($1)) &* 1099511628211
        }
        return thumbnailDiskCacheDir.appendingPathComponent(String(format: "%016llx.jpg", hash))
    }

    private func readThumbnailDiskCache(key: String) -> PlatformImage? {
        let url = thumbnailDiskCacheURL(key: key)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attrs[.modificationDate] as? Date,
              Date().timeIntervalSince(modified) < 30 * 86400,
              let data = try? Data(contentsOf: url) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return PlatformImage(data: data)
    }

    private func writeThumbnailDiskCache(_ image: PlatformImage, key: String) {
        guard let data = image.tonearmJPEGData(compressionQuality: 0.8) else { return }
        try? data.write(to: thumbnailDiskCacheURL(key: key))
    }

    func artwork(forTrackRow row: TrackRow) async -> PlatformImage? {
        await trackArtwork(forTrackRow: row)?.image
    }

    /// Resolves a track's artwork and reports whether the match is strong enough to
    /// be remembered as a source's representative cover. Embedded art and IA covers
    /// are always persistable; iTunes fallbacks are persistable only on a strong
    /// (artist + album/track aligned) match.
    func trackArtwork(forTrackRow row: TrackRow) async -> (image: PlatformImage, persistable: Bool)? {
        let trackId = row.track.id ?? -1

        // 0. Custom user-attached artwork (highest priority, persistable).
        if let customId = try? await LibraryStore.shared.customArtworkId(for: trackId),
           !customId.isEmpty,
           let image = await ArtworkStore.shared.image(id: customId) {
            return (image, true)
        }

        // 0a. Album-level custom artwork (falls back before source-level and
        // before the remote/embedded/iTunes/generated chain).
        if let albumId = row.album?.id,
           let customId = try? await LibraryStore.shared.albumCustomArtworkId(for: albumId),
           !customId.isEmpty,
           let image = await ArtworkStore.shared.image(id: customId) {
            return (image, true)
        }

        // 0b. Source-level custom artwork.
        if let sourceId = row.source?.id,
           let customId = try? await LibraryStore.shared.sourceCustomArtworkId(for: sourceId),
           !customId.isEmpty,
           let image = await ArtworkStore.shared.image(id: customId) {
            return (image, true)
        }

        let isRemote = row.asset?.kind == .remote
        if let asset = row.asset,
           let result = await remoteProviderArtwork(asset: asset) {
            return result
        }

        // 1. IA identifier cover (strong).
        if let id = row.album?.artworkId, !id.isEmpty {
            if let image = await artwork(forIdentifier: id) { return (image, true) }
        }

        // 1a. Embedded ID3/MP4 tag artwork, read straight from an already-complete local cache
        // file — covers any remote provider that doesn't supply its own artwork metadata
        // (Jellyfin items with no server-side image tag; Dropbox/Google Drive/pCloud/OneDrive/
        // Box, which have no artwork concept at all today). Only attempted once the track is
        // already fully cached (`AudioCache.cachedFileURL` returns nil otherwise), so this never
        // costs an extra network round-trip just to peek at tags — the same reasoning that keeps
        // step 2 below local-file-only.
        if isRemote, let asset = row.asset,
           let result = await remoteCachedEmbeddedArtwork(asset: asset, trackId: trackId) {
            return result
        }

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
                if Task.isCancelled { return nil }
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

    private func remoteProviderArtwork(asset: Asset) async -> (image: PlatformImage, persistable: Bool)? {
        // `transientArtwork` (never persisted — most provider artwork needs
        // auth headers/expiring URLs) takes priority when a live browse
        // session set it; `persistedArtworkURL` is the fallback for a
        // genuinely-imported row, real fix for "none of the Jamendo artwork
        // is loading" (see that field's doc comment).
        let url: URL?
        let artworkId: String?
        if let transient = asset.transientArtwork, let transientURL = transient.url {
            url = transientURL
            artworkId = transient.id
        } else if let persisted = asset.persistedArtworkURL, let persistedURL = URL(string: persisted) {
            url = persistedURL
            artworkId = nil
        } else {
            url = nil
            artworkId = nil
        }
        guard let url else { return nil }
        let key: String
        if let artworkId,
           !artworkId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            key = artworkId
        } else {
            // Imported IA/Jamendo rows can legitimately have a URL without a
            // provider artwork id.  The URL is still a stable cache key; never
            // force-unwrap the optional id on this path.
            key = "remote-artwork-\(url.absoluteString)"
        }
        if let cached = memCache.object(forKey: key as NSString) {
            return cached === Self.notFoundSentinel ? nil : (cached, true)
        }
        if let image = readDiskCache(key: key) {
            store(image, forKey: key as NSString)
            return (image, true)
        }

        var request = URLRequest(url: url)
        for (field, value) in asset.transientArtwork?.headers ?? [:] {
            request.setValue(value, forHTTPHeaderField: field)
        }
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let image = PlatformImage(data: data) else {
            memCache.setObject(Self.notFoundSentinel, forKey: key as NSString)
            return nil
        }
        store(image, forKey: key as NSString)
        writeDiskCache(image, key: key)
        return (image, true)
    }

    /// Reads embedded ID3/MP4 tag artwork from an already-complete local cache file for a
    /// remote track whose provider supplied no artwork of its own (`remoteProviderArtwork`
    /// already returned nil by the time this runs). Mirrors `liveLocalLoader`'s embedded-cover
    /// decode below, but points at the streaming cache's blob instead of a security-scoped
    /// local-file bookmark — no `LocalAssetResolver` lease is needed since this file is already
    /// owned by the app's own cache, not an imported external URL.
    private func remoteCachedEmbeddedArtwork(asset: Asset, trackId: Int64) async -> (image: PlatformImage, persistable: Bool)? {
        guard let remoteStr = asset.remoteURL, let remoteURL = URL(string: remoteStr),
              let fileURL = AudioCache.cachedFileURL(forRemoteEmbeddedArtwork: remoteURL) else { return nil }

        let key = "remote-embedded-\(trackId)" as NSString
        if let cached = memCache.object(forKey: key) {
            return cached === Self.notFoundSentinel ? nil : (cached, true)
        }
        if let onDisk = readDiskCache(key: key as String) {
            store(onDisk, forKey: key)
            return (onDisk, true)
        }

        let avAsset = AVURLAsset(url: fileURL)
        guard let metadata = try? await avAsset.load(.commonMetadata) else { return nil }
        for item in metadata {
            guard item.commonKey == .commonKeyArtwork,
                  let data = try? await item.load(.dataValue),
                  let art = EmbeddedArtworkDownsampler.downsample(data) else { continue }
            let image = Self.platformImage(from: art.image)
            store(image, forKey: key)
            writeDiskCache(image, key: key as String)
            return (image, true)
        }
        memCache.setObject(Self.notFoundSentinel, forKey: key)
        return nil
    }

    /// External iTunes artwork lookup for a track, keyed and cached separately from
    /// embedded/IA art so a miss on one path doesn't block the other.
    private func iTunesArtwork(trackId: Int64, artist: String?, album: String?,
                              title: String?) async -> (image: PlatformImage, persistable: Bool)? {
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
              data.count > 2048, let image = PlatformImage(data: data) else {
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

    /// Single-flight entry point for local metadata + embedded artwork: every
    /// surface (player, Now Playing, system playback, lists) joining the same
    /// asset shares one `AVURLAsset` pass and one bounded artwork decode.
    func loadLocalFile(asset: Asset) async
        -> (image: PlatformImage?, artist: String?, album: String?, title: String?) {
        let key = "local-asset-\(asset.id ?? asset.trackId)"
        let loader = localLoader
        let result = await localFlights.value(for: key) { await loader(asset) }
        // A cancelled caller must not publish a stale result into caches/UI.
        guard let result, !Task.isCancelled else { return (nil, nil, nil, nil) }
        return (result.artwork.map { Self.platformImage(from: $0.image) }, result.artist, result.album, result.title)
    }

    /// Drops thumbnails and cancels in-flight local work on memory pressure.
    func purgeForMemoryWarning() async {
        memCache.removeAllObjects()
        thumbnailMemCache.removeAllObjects()
        await localFlights.cancelAll()
        LocalPlaybackDiagnostics.shared.record(.memoryWarning, loadID: 0)
    }

    private static func platformImage(from cg: CGImage) -> PlatformImage {
        UIImage(cgImage: cg)
    }

    /// Live loader: scoped access for the duration of the pass only, metadata
    /// via one `AVURLAsset`, embedded cover through the bounded downsampler.
    static let liveLocalLoader: LocalFileLoader = { asset in
        let diag = LocalPlaybackDiagnostics.shared
        let id = diag.makeLoadID()
        diag.record(.metadataStart, loadID: id)
        // The lease is local to this call, so it never touches the player's own scope.
        guard let resolved = try? LocalAssetResolver.live.resolve(asset) else {
            diag.record(.metadataError, loadID: id)
            return LocalFileMetadata()
        }
        defer { resolved.lease?.release() }

        let avAsset = AVURLAsset(url: resolved.url)
        guard let metadata = try? await avAsset.load(.commonMetadata) else {
            diag.record(.metadataError, loadID: id)
            return LocalFileMetadata()
        }

        var result = LocalFileMetadata()
        for item in metadata {
            if Task.isCancelled { diag.record(.cancelled, loadID: id); return nil }
            guard let commonKey = item.commonKey else { continue }
            switch commonKey {
            case .commonKeyArtwork:
                guard let data = try? await item.load(.dataValue) else { continue }
                diag.record(.artworkDecodeStart, loadID: id, values: ["bytes": data.count])
                if let art = EmbeddedArtworkDownsampler.downsample(data) {
                    result.artwork = art
                    diag.record(.artworkDecodeEnd, loadID: id, values: [
                        "srcW": art.sourceWidth, "srcH": art.sourceHeight,
                        "outW": art.image.width, "outH": art.image.height,
                        "target": LocalArtworkLimits.maxThumbnailPixel])
                } else {
                    diag.record(.artworkRejected, loadID: id, values: ["bytes": data.count])
                }
            case .commonKeyArtist:
                result.artist = try? await item.load(.stringValue)
            case .commonKeyAlbumName:
                result.album = try? await item.load(.stringValue)
            case .commonKeyTitle:
                result.title = try? await item.load(.stringValue)
            default:
                break
            }
        }
        diag.record(.metadataEnd, loadID: id)
        return result
    }

    @MainActor
    static func dominantColor(from image: PlatformImage) -> PlatformColor {
        guard let cgImage = image.tonearmCGImage else { return .systemBlue }
        let c = ArtworkColorSampler.averageColor(of: cgImage)
        return PlatformColor(
            red: CGFloat(c.red) / 255,
            green: CGFloat(c.green) / 255,
            blue: CGFloat(c.blue) / 255,
            alpha: 1
        )
    }

    private func store(_ image: PlatformImage, forKey key: NSString) {
        let cost = Int(image.size.width * image.size.height * 4)
        memCache.setObject(image, forKey: key, cost: cost)
    }

    private func diskCacheURL(key: String) -> URL {
        let hash = key.utf8.reduce(UInt64(14695981039346656037)) {
            ($0 ^ UInt64($1)) &* 1099511628211
        }
        return diskCacheDir.appendingPathComponent(String(format: "%016llx.jpg", hash))
    }

    private func readDiskCache(key: String) -> PlatformImage? {
        let url = diskCacheURL(key: key)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attrs[.modificationDate] as? Date,
              Date().timeIntervalSince(modified) < 7 * 86400,
              let data = try? Data(contentsOf: url) else { return nil }
        // Renew the entry's lifetime on access so artwork stays cached as long as
        // its music keeps being played, rather than expiring out from under it.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return PlatformImage(data: data)
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
        if let contents = try? FileManager.default.contentsOfDirectory(at: thumbnailDiskCacheDir,
                                                                       includingPropertiesForKeys: nil) {
            for url in contents {
                try? FileManager.default.removeItem(at: url)
            }
        }
        memCache.removeAllObjects()
        thumbnailMemCache.removeAllObjects()
    }

    private func writeDiskCache(_ image: PlatformImage, key: String) {
        guard let data = image.tonearmJPEGData(compressionQuality: 0.85) else { return }
        try? data.write(to: diskCacheURL(key: key))
    }
}
