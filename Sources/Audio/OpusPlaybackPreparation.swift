#if !os(watchOS)
import Foundation

/// First-class Ogg-Opus support. AVFoundation cannot demux Ogg, so a `.opus`
/// file (local, Internet Archive, or a cloud provider) is downloaded/opened,
/// remuxed to a CAF Opus file the player can decode, and then played from that
/// CAF. The remux itself is the existing pure-Swift `OpusRemuxer`.
enum OpusPlaybackPreparation {
    /// True when the asset's *currently playable* source is Opus. A mixed
    /// Internet Archive item whose cold-play URL is FLAC/MP3 is deliberately
    /// false: it keeps its existing cold-play behavior and only upgrades to
    /// Opus through the separate `opusRemoteURL` prefetch path.
    static func isOpusAsset(_ asset: Asset) -> Bool {
        if let path = asset.relPath, path.lowercased().hasSuffix(".opus") { return true }
        // Cloud assets keep the provider's own node path even when the
        // resolved URL is extensionless (Google Drive `files/<id>?alt=media`,
        // signed OneDrive/Dropbox URLs). The node path is the stable hint.
        if let nodePath = asset.remoteNodePath, nodePath.lowercased().hasSuffix(".opus") {
            return true
        }
        if let raw = asset.remoteURL, let url = URL(string: raw),
           url.pathExtension.lowercased() == "opus" { return true }
        // Deliberately not bare `audio/ogg`: that is usually Ogg Vorbis, which
        // the Opus remuxer cannot convert. Only an explicit Opus type counts.
        if let mime = asset.remoteContentType?.lowercased(), mime.contains("opus") { return true }
        return false
    }

    /// Remote Opus source, if the asset exposes one directly. Local bookmark /
    /// relPath assets return nil here because they must be resolved while the
    /// security scope is held; the player resolves those itself.
    static func remoteSourceURL(for asset: Asset) -> URL? {
        if isOpusAsset(asset), let raw = asset.remoteURL, let url = URL(string: raw) {
            return url
        }
        if let raw = asset.opusRemoteURL, let url = URL(string: raw) { return url }
        if let raw = asset.remoteURL, let url = URL(string: raw),
           url.pathExtension.lowercased() == "opus" { return url }
        return nil
    }

    /// Ensures a playable CAF exists for `source`, downloading a remote Opus
    /// blob into `cacheKey` first when necessary. Returns the CAF URL.
    @discardableResult
    static func prepare(source: URL, cacheKey: String,
                        headers: [String: String]) async throws -> URL {
        let caf = AudioCache.cafURL(forRemoteOpus: source)
        if FileManager.default.fileExists(atPath: caf.path) { return caf }

        let input: URL
        if source.isFileURL {
            input = source
        } else if let cached = AudioCache.playableCompleteBlobURL(for: source) {
            input = cached
        } else {
            var request = URLRequest(url: source)
            for (name, value) in headers {
                request.setValue(value, forHTTPHeaderField: name)
            }
            let (temporary, response) = try await URLSession.shared.download(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
            let destination = AudioCache.fileURL(for: cacheKey)
            try? FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporary, to: destination)
            input = destination
            if let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path),
               let bytes = attributes[.size] as? Int64 {
                await AudioCache.shared.setContentLength(bytes, for: cacheKey)
            }
        }

        try FileManager.default.createDirectory(
            at: caf.deletingLastPathComponent(), withIntermediateDirectories: true)
        // The raw Ogg blob is unplayable on its own; once the CAF exists it is
        // dead weight. A user's original local file must never be deleted.
        let cafURL = try await OpusRemuxer.shared.remux(
            opusFileURL: input, cacheKey: cacheKey, outputURL: caf,
            deleteSourceOnSuccess: !source.isFileURL)
        // `OpusRemuxer` returns immediately when another task already owns the
        // same key. In that case the CAF is not on disk yet, so wait for the
        // owner to finish instead of handing AVFoundation a missing file.
        try await waitForCAF(cafURL)
        if let attributes = try? FileManager.default.attributesOfItem(atPath: cafURL.path),
           let bytes = attributes[.size] as? Int64 {
            await AudioCache.shared.recordDerivedBytes(
                bytes, name: AudioCache.cafArtifactName, for: cacheKey)
        }
        return cafURL
    }

    /// Waits (up to ~10s) for a CAF another remux task is already producing.
    private static func waitForCAF(_ caf: URL) async throws {
        let manager = FileManager.default
        guard !manager.fileExists(atPath: caf.path) else { return }
        for _ in 0..<200 {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(50))
            if manager.fileExists(atPath: caf.path) { return }
        }
        throw URLError(.timedOut)
    }
}
#endif
