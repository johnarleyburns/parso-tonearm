#if !os(watchOS)
import Foundation
import AVFoundation
import ParsoAudioStreaming
import Combine
import Network

extension AudioPlayer {
    // MARK: - Loading

    func loadCurrent(autoplay: Bool) {
        guard let row = currentTrack, let asset = row.asset else { return }
        if let trackId = row.track.id { recordKeepPlayingHistory(trackId) }

        if let reason = asset.unsupportedReason {
            _ = reason
            next()
            return
        }

        let decision = playbackDecision(for: asset)
        if decision == .skipWiFiOnly {
            skipCurrentForWiFiOnly(row: row)
            return
        }

        cancelCrossfade(resetVolume: true)
        shutdownLoaders()

        if asset.kind == .builtIn {
            loadBuiltInAsset(asset, row: row, autoplay: autoplay)
            return
        }

        _ = stallModel.beginLoad()
        prefetchedURLs.removeAll()

        let built: (item: AVPlayerItem, loader: CachingResourceLoader?)?
        // Near-gapless (T2.5): consume the preloaded next item if it matches the
        // track we're loading, so the boundary swap avoids a fresh teardown/build.
        if let preItem = preloadedNextItem, preloadedNextTrackId == row.track.id {
            built = (preItem, preloadedNextLoader)
        } else {
            built = buildItem(for: asset)
        }
        preloadedNextItem = nil
        preloadedNextTrackId = nil
        preloadedNextLoader = nil

        guard let built else {
            next()
            return
        }
        if let loader = built.loader { loaders.append(loader) }
        let item = built.item

        item.preferredForwardBufferDuration = 120
        item.automaticallyPreservesTimeOffsetFromLive = false

        replaceItem(item)
        applyEQ(to: item, row: row)
        protectCacheKeys(for: asset)
        if autoplay {
            player.play()
            isPlaying = true
        }
        duration = row.track.durationSec ?? 0
        updateNowPlaying()
        prefetchNext()
        preloadNextItem()
        if autoplay, let trackId = row.track.id {
            Task { try? await LibraryStore.shared.recordPlay(trackId: trackId) }
        }
        maybeExtendKeepPlayingQueue()
    }

    /// Builds an `AVPlayerItem` (and its cache loader, if remote) for an asset,
    /// applying the "Opus when ready" policy (T2.4): if a remuxed `.caf` exists
    /// for the track's Opus derivative, play that local file; otherwise cold-play
    /// FLAC/MP3 via the caching resource loader. The loader is returned rather
    /// than attached, so callers (near-gapless preload) can own it.
    func buildItem(for asset: Asset) -> (item: AVPlayerItem, loader: CachingResourceLoader?)? {
        // Opus-when-ready: a remuxed CAF upgrades playback to Opus.
        if let opusString = asset.opusRemoteURL, let opusURL = URL(string: opusString) {
            let caf = AudioCache.cafURL(forRemoteOpus: opusURL)
            if FileManager.default.fileExists(atPath: caf.path) {
                return (AVPlayerItem(url: caf), nil)
            }
        }

        if asset.kind == .remote, let urlString = remoteURLString(for: asset), let remote = URL(string: urlString) {
            if !asset.transientRemoteSupportsByteRanges {
                return (directRemoteItem(url: remote, headers: asset.transientRemoteHeaders), nil)
            }
            let cacheURL = RemoteAudioURL.cacheURL(for: remote, scheme: AudioCache.scheme)
            let avAsset = AVURLAsset(url: cacheURL)
            let loader = CachingResourceLoader(originalURL: remote, store: AudioCache.shared, config: AudioCache.loaderConfig(headers: asset.transientRemoteHeaders))
            avAsset.resourceLoader.setDelegate(loader, queue: loaderQueue)
            return (AVPlayerItem(asset: avAsset), loader)
        } else if let bookmark = asset.bookmark, let (url, _) = BookmarkVault.resolve(bookmark) {
            _ = url.startAccessingSecurityScopedResource()
            return (AVPlayerItem(url: url), nil)
        } else if let rel = asset.relPath {
            let url = managedURL(rel)
            return (AVPlayerItem(url: url), nil)
        }
        return nil
    }

    func directRemoteItem(url: URL, headers: [String: String]) -> AVPlayerItem {
        guard !headers.isEmpty else { return AVPlayerItem(url: url) }
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        return AVPlayerItem(asset: asset)
    }

    func networkAssetKind(for asset: Asset) -> NetworkPolicy.AssetKind {
        asset.kind == .remote ? .remote : .local
    }

    func playbackDecision(for asset: Asset) -> PlaybackDecision {
        NetworkPolicy.decide(
            assetKind: networkAssetKind(for: asset),
            isCached: isFullyCached(asset),
            pathIsExpensive: pathIsExpensive,
            streamOnCellular: streamOnCellular
        )
    }

    func isFullyCached(_ asset: Asset) -> Bool {
        guard asset.kind == .remote,
              asset.transientRemoteSupportsByteRanges,
              let urlString = remoteURLString(for: asset),
              let remote = URL(string: urlString) else {
            return asset.kind != .remote
        }
        return AudioCache.completeCacheExists(for: remote)
    }

    func skipCurrentForWiFiOnly(row: TrackRow) {
        networkSkipMessage = "Skipped \(row.track.title): Wi-Fi only"
        guard repeatMode != .one else {
            player.pause()
            isPlaying = false
            updateNowPlaying()
            return
        }
        guard let nextIndex = NetworkPolicy.nextPlayableIndex(
            after: index,
            count: queue.count,
            repeatAll: repeatMode == .all,
            decisionAt: { candidate in
                guard queue.indices.contains(candidate),
                      let asset = queue[candidate].asset else {
                    return .skipWiFiOnly
                }
                return playbackDecision(for: asset)
            }
        ) else {
            player.pause()
            isPlaying = false
            updateNowPlaying()
            return
        }
        index = nextIndex
        loadCurrent(autoplay: true)
    }

    /// Preloads the upcoming track's `AVPlayerItem` (with its own cache loader)
    /// so the natural track boundary swaps to a ready item instead of tearing the
    /// player down and rebuilding (T2.5). No-op when there is no next track, when
    /// the next item is unsupported, or when it is already preloaded.
    func preloadNextItem() {
        guard !isAmbient, repeatMode != .one else { return }
        guard crossfadePlayer == nil else { return }
        guard let nextIndex = upcomingQueueIndex() else { return }
        guard queue.indices.contains(nextIndex) else { return }
        let row = queue[nextIndex]
        guard let asset = row.asset, asset.unsupportedReason == nil else { return }
        guard playbackDecision(for: asset) != .skipWiFiOnly else { return }
        guard preloadedNextTrackId != row.track.id else { return }
        guard let built = buildItem(for: asset) else { return }
        built.item.preferredForwardBufferDuration = 120
        applyEQ(to: built.item, row: row)
        preloadedNextItem = built.item
        preloadedNextTrackId = row.track.id
        preloadedNextLoader = built.loader
    }

    func upcomingQueueIndex() -> Int? {
        guard !queue.isEmpty, !isAmbient, repeatMode != .one else { return nil }
        if index < queue.count - 1 { return index + 1 }
        if repeatMode == .all, queue.count > 1 { return 0 }
        return nil
    }
    /// Chooses the FLAC alternate when the user prefers lossless and one exists,
    /// otherwise the primary (MP3) URL.
    func remoteURLString(for asset: Asset) -> String? {
        if preferFLAC, let alt = asset.altRemoteURL, !alt.isEmpty { return alt }
        return asset.remoteURL
    }

    func replaceItem(_ item: AVPlayerItem) {
        player.replaceCurrentItem(with: item)
        loadedSourceSampleRate = 0
        // Drop EQ taps for items no longer in play (the outgoing current item,
        // and any preloaded item that wasn't the one we advanced to).
        eqTap?.prune(keeping: [item, preloadedNextItem].compactMap { $0 })
        let asset = item.asset
        Task { @MainActor [weak self, asset, item] in
            guard let self,
                  self.player.currentItem === item,
                  let audioTracks = try? await asset.loadTracks(withMediaType: .audio),
                  let audioTrack = audioTracks.first,
                  let descriptions = try? await audioTrack.load(.formatDescriptions)
            else { return }
            for description in descriptions {
                if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description) {
                    self.loadedSourceSampleRate = asbd.pointee.mSampleRate
                    return
                }
            }
        }
        observeEnd(of: item)
    }

    func observeEnd(of item: AVPlayerItem) {
        if let obs = itemEndObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        itemEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if let nextIndex = self.crossfadeNextIndex,
                   self.queue.indices.contains(nextIndex) {
                    self.finishCrossfade(to: nextIndex, row: self.queue[nextIndex])
                    return
                }
                if self.sleepAtEndOfTrack {
                    self.sleepAtEndOfTrack = false
                    self.pause()
                    return
                }
                self.next()
            }
        }
    }

    func managedURL(_ rel: String) -> URL {
        let base = try! FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                appropriateFor: nil, create: true)
        return base.appendingPathComponent(rel)
    }

    /// F6: protects the current track's cache key from eviction while it's playing.
    /// Also protects any active prefetch keys so they aren't evicted mid-stream before
    /// the track advances to them.
    func protectCacheKeys(for asset: Asset) {
        var keys: Set<String> = []
        if asset.kind == .remote,
           asset.transientRemoteSupportsByteRanges,
           let urlString = remoteURLString(for: asset),
           let remote = URL(string: urlString) {
            keys.insert(AudioCache.key(for: remote))
        }
        for loader in prefetchLoaders.values {
            keys.insert(loader.cacheKey)
        }
        Task { await AudioCache.shared.setProtectedKeys(keys) }
    }
}
#endif
