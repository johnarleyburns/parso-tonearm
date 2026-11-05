#if !os(watchOS)
import Foundation
import AVFoundation
import ParsoAudioStreaming
import Combine
import Network

extension AudioPlayer {
    // MARK: - Prefetch (FR-3.5)

    func prefetchNext() {
        guard prefetchDepth > 0 else { return }
        let upcoming = Array(queue.dropFirst(index + 1).prefix(prefetchDepth))
        let upcomingIds = Set(upcoming.compactMap { $0.track.id })
        // Skipping a track cancels its in-flight fetch: tear down any prefetch
        // loader that is no longer in the upcoming window (T3.5).
        for (trackId, loader) in prefetchLoaders where !upcomingIds.contains(trackId) {
            loader.shutdown()
            prefetchLoaders.removeValue(forKey: trackId)
            prefetchedURLs.removeValue(forKey: trackId)
        }
        for row in upcoming {
            guard let trackId = row.track.id,
                  let asset = row.asset, asset.kind == .remote,
                  asset.transientRemoteSupportsByteRanges,
                  let urlString = remoteURLString(for: asset), let remote = URL(string: urlString) else { continue }
            guard playbackDecision(for: asset) != .skipWiFiOnly else { continue }
            if prefetchLoaders[trackId] != nil { continue }  // already prefetching
            prefetchedURLs[trackId] = remote
            let loader = CachingResourceLoader(originalURL: remote, store: AudioCache.shared, config: AudioCache.loaderConfig(headers: asset.transientRemoteHeaders))
            prefetchLoaders[trackId] = loader
            loader.warm(upTo: 2 * 1024 * 1024)  // warm 2 MB to seed near-gapless
            // "Opus when ready" (T2.4): fetch the Opus derivative and remux it to
            // CAF so the NEXT play/repeat of this track upgrades to Opus. Cold play
            // above stays on the instant FLAC/MP3 — no added latency on the tap.
            if let opusString = asset.opusRemoteURL, let opusURL = URL(string: opusString) {
                prefetchOpusAndRemux(opusURL)
            }
            // Cache the artwork alongside its music so prefetched tracks are
            // fully available offline, not just their audio bytes.
            bridge.prefetchArtwork(for: row)
        }
    }

    /// Downloads a complete Opus derivative into the stream cache and remuxes it
    /// to a sibling CAF. Skips work when a CAF already exists or the key was
    /// already marked unavailable. Fire-and-forget; failures fall back silently.
#if !os(watchOS)
    func prefetchOpusAndRemux(_ opusURL: URL) {
        let caf = AudioCache.cafURL(forRemoteOpus: opusURL)
        guard !FileManager.default.fileExists(atPath: caf.path) else { return }
        let key = AudioCache.key(for: opusURL)
        Task.detached(priority: .background) {
            if await OpusRemuxer.shared.isUnavailable(key) { return }
            // Touch the store so its on-disk roots (blobs/ and derived/) exist.
            _ = await AudioCache.shared.currentLimit()
            let dest = AudioCache.fileURL(for: key)
            do {
                let (tmp, response) = try await URLSession.shared.download(from: opusURL)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return }
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                       withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: tmp, to: dest)
                let bytes = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64) ?? nil
                if let b = bytes { await AudioCache.shared.setContentLength(b, for: key) }
                try FileManager.default.createDirectory(at: caf.deletingLastPathComponent(),
                                                       withIntermediateDirectories: true)
                let cafURL = try await OpusRemuxer.shared.remux(opusFileURL: dest, cacheKey: key, outputURL: caf)
                let cafSize = (try? FileManager.default.attributesOfItem(atPath: cafURL.path)[.size] as? Int64) ?? nil
                await AudioCache.shared.recordDerivedBytes(cafSize ?? 0, name: AudioCache.cafArtifactName, for: key)
            } catch {
                await OpusRemuxer.shared.markUnavailable(key)
            }
        }
    }
#endif
}
#endif
