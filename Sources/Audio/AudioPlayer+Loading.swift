#if !os(watchOS)
import Foundation
import AVFoundation
import ParsoAudioStreaming
import Combine
import Network
import OSLog

private let loadingLog = Logger(subsystem: "guru.parso.tonearm", category: "Playback")

extension AudioPlayer {
    // MARK: - Loading

    func loadCurrent(autoplay: Bool) {
        guard let row = currentTrack else {
            loadingLog.error("loadCurrent: no current track at index \(self.index, privacy: .public) of \(self.queue.count, privacy: .public)")
            return
        }
        guard let asset = row.asset else {
            loadingLog.error("loadCurrent: track \(row.track.id ?? -1, privacy: .public) \"\(row.track.title, privacy: .public)\" has no asset row — nothing to play")
            return
        }
        if let trackId = row.track.id { recordKeepPlayingHistory(trackId) }

        if let reason = asset.unsupportedReason {
            loadingLog.error("loadCurrent: track \(row.track.id ?? -1, privacy: .public) \"\(row.track.title, privacy: .public)\" is unsupported (\(reason, privacy: .public)) — skipping to next")
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
        let reusedPreload = preloadedNextItem != nil && preloadedNextTrackId == row.track.id
        if let preItem = preloadedNextItem, preloadedNextTrackId == row.track.id {
            built = (preItem, preloadedNextLoader)
        } else {
            built = buildItem(for: asset)
        }
        // TEMPORARY diagnostic — real, repeated report ("I click on a track
        // I've played before and nothing happens"), 4th occurrence despite
        // 3 distinct fixes this session. Remove once root-caused live.
        loadingLog.notice("loadCurrent: track \(row.track.id ?? -1, privacy: .public) \"\(row.track.title, privacy: .public)\" kind=\(asset.kind.rawValue, privacy: .public) reusedPreload=\(reusedPreload, privacy: .public) remoteURL=\(asset.remoteURL ?? "nil", privacy: .public) transientSupportsByteRanges=\(asset.transientRemoteSupportsByteRanges, privacy: .public) autoplay=\(autoplay, privacy: .public)")
        preloadedNextItem = nil
        preloadedNextTrackId = nil
        preloadedNextLoader = nil

        guard let built else {
            loadingLog.error("loadCurrent: buildItem(for:) returned nil for track \(row.track.id ?? -1, privacy: .public) \"\(row.track.title, privacy: .public)\" (asset kind \(asset.kind.rawValue, privacy: .public), remoteURL=\(asset.remoteURL ?? "nil", privacy: .public)) — skipping to next")
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

        // Built-in tracks (docs/plans/builtin-mood-starter-index-plan.md)
        // live in the app bundle, not Application Support — `managedURL(_:)`
        // below would silently never find them.
        if asset.kind == .builtIn, let channelId = asset.relPath,
           let url = BuiltInContentProvider.bundledAudioURL(forChannelId: channelId) {
            return (AVPlayerItem(url: url), nil)
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
        // TEMPORARY diagnostic — see loadCurrent's matching comment. Logs
        // every status transition (unknown -> readyToPlay/failed) and the
        // real underlying error if AVFoundation ever reports one, which
        // print-based debugging of this exact bug has never captured yet.
        let trackTitle = currentTrack?.track.title ?? "?"
        itemStatusCancellable = item.publisher(for: \.status)
            .sink { status in
                loadingLog.notice("replaceItem: status change for \"\(trackTitle, privacy: .public)\" -> \(String(describing: status), privacy: .public), error=\(String(describing: item.error), privacy: .public)")
            }
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
        // Same fallback pattern as AudioCache.root: extremely unlikely to
        // fail on a real device/Mac, but this runs on every local-track
        // resolve — a force-try here is a needless crash risk versus a
        // graceful fallback to a directory that always resolves.
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
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
