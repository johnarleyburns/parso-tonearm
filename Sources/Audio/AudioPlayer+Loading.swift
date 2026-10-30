#if !os(watchOS)
import Foundation
import AVFoundation
import ParsoAudioStreaming
import Combine
import Network
import OSLog

private let loadingLog = Logger(subsystem: "guru.parso.tonearm", category: "Playback")

private let localLog = Logger(subsystem: "guru.parso.tonearm", category: "LocalMedia")

/// An item for an imported local file. It owns the scoped-access lease, so
/// access lasts exactly as long as AVFoundation can use the item and is
/// released when the item is replaced, discarded or invalidated.
final class LocalPlayerItem: AVPlayerItem {
    private let lease: SecurityScopedAssetLease?
    let backing: ResolvedLocalAsset.Backing

    init(url: URL, lease: SecurityScopedAssetLease?, backing: ResolvedLocalAsset.Backing) {
        self.lease = lease
        self.backing = backing
        super.init(asset: AVURLAsset(url: url), automaticallyLoadedAssetKeys: nil)
    }

    /// Ends scoped access now (idempotent). The lease also releases on deinit.
    func releaseLease() { lease?.release() }
}

/// Why a remote item could not be opened, as shown to the user.
enum RemotePlaybackFailure: Equatable {
    case jamendoLocatorUnavailable

    var userMessage: String {
        String(localized: "Jamendo track unavailable — the stream link could not be refreshed", bundle: .module)
    }
}

/// An ordinary Jamendo load bound to its exact queue occurrence and load generation.
struct OrdinaryJamendoLoad {
    let row: TrackRow
    let asset: Asset
    let occurrence: QueueOccurrenceID?
    let generation: Int
    var retried: Bool
}

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
        // Any new load supersedes a pending catalog resolve (exact queue occurrence + generation).
        let occurrence = queueOccurrences.indices.contains(index) ? queueOccurrences[index] : nil
        cancelCatalogPlaybackLoad()
        let generation = catalogPlaybackLoadGeneration
        // Loading any item ends the terminal boundary (waiting or exhausted).
        if keepPlayingBoundaryState != .idle { resetKeepPlayingBoundary() }
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

        if loadCurrentOnStarterStream(row: row, autoplay: autoplay) { return }
        if wantsMixDecks, loadCurrentOnMixDecks(row: row, autoplay: autoplay) { return }

        if row.source?.kind == .jamendoGenre, asset.kind == .remote {
            startOrdinaryJamendoLoad(OrdinaryJamendoLoad(row: row, asset: asset, occurrence: occurrence,
                                                         generation: generation, retried: false),
                                     autoplay: autoplay)
            return
        }
        finishOrdinaryLoad(row: row, asset: asset, autoplay: autoplay)
    }

    /// Invalidates any pending catalog resolve so a late result can never apply.
    func cancelCatalogPlaybackLoad() {
        catalogPlaybackLoadGeneration &+= 1
        catalogPlaybackLoadTask?.cancel()
        catalogPlaybackLoadTask = nil
        ordinaryJamendoLoad = nil
    }

    /// Resolves the durable `jamendo:<id>` locator off the render path, then builds the item with the
    /// fresh URL only if the exact occurrence/generation is still current.
    private func startOrdinaryJamendoLoad(_ load: OrdinaryJamendoLoad, autoplay: Bool) {
        ordinaryJamendoLoad = load
        catalogPlaybackAutoplay = autoplay
        catalogPlaybackLoadTask?.cancel()
        let resolver = catalogPlaybackURLResolver
        catalogPlaybackLoadTask = Task { @MainActor [weak self] in
            do {
                let resolved = try await resolver.resolve(row: load.row)
                guard let self else { return }
                guard !Task.isCancelled,
                      self.catalogPlaybackLoadGeneration == load.generation,
                      self.queueOccurrences.indices.contains(self.index),
                      self.queueOccurrences[self.index] == load.occurrence else { return }
                var transient = load.asset
                if let resolved { transient.remoteURL = resolved.url.absoluteString }
                self.finishOrdinaryLoad(row: load.row, asset: transient, autoplay: self.catalogPlaybackAutoplay)
            } catch is CancellationError {
                return
            } catch {
                guard let self, !Task.isCancelled,
                      self.catalogPlaybackLoadGeneration == load.generation else { return }
                self.failRemotePlayback(.jamendoLocatorUnavailable)
            }
        }
    }

    /// Classified HTTP failure from the ordinary remote loader for the current Jamendo item: a stale
    /// link refreshes once for the exact occurrence; a second one (or a permanent one) fails truthfully.
    func handleOrdinaryJamendoLoaderFailure(httpStatus: Int, terminal: Bool = false) {
        guard let load = ordinaryJamendoLoad,
              load.generation == catalogPlaybackLoadGeneration,
              queueOccurrences.indices.contains(index),
              queueOccurrences[index] == load.occurrence else { return }
        switch JamendoLocatorFailure.classify(httpStatus: httpStatus) {
        case .transient:
            // The loader's own bounded retry/backoff owns a live request; a terminal failure
            // (retry exhausted / item already failed) must not strand the item.
            if terminal { failRemotePlayback(.jamendoLocatorUnavailable) }
        case .permanent:
            failRemotePlayback(.jamendoLocatorUnavailable)
        case .expiredOrInvalid:
            guard !load.retried else {
                failRemotePlayback(.jamendoLocatorUnavailable)
                return
            }
            var retry = load
            retry.retried = true
            startOrdinaryJamendoLoad(retry, autoplay: catalogPlaybackAutoplay || isPlaying)
        }
    }

    /// A terminal failure of the current ordinary Jamendo item (failed AVPlayer item or the loader's
    /// exhausted retry). Always on the main actor; stale occurrences/generations are ignored.
    /// Without a usable HTTP status the cached URL cannot be called valid, so it fails truthfully.
    func handleOrdinaryJamendoTerminalLoaderFailure(httpStatus: Int?) {
        guard let load = ordinaryJamendoLoad,
              load.generation == catalogPlaybackLoadGeneration,
              queueOccurrences.indices.contains(index),
              queueOccurrences[index] == load.occurrence else { return }
        if let httpStatus {
            handleOrdinaryJamendoLoaderFailure(httpStatus: httpStatus, terminal: true)
        } else {
            failRemotePlayback(.jamendoLocatorUnavailable)
        }
    }

    /// Controlled stop for a remote item that cannot be opened; leaves the player idle and says why.
    func failRemotePlayback(_ failure: RemotePlaybackFailure) {
        ordinaryJamendoLoad = nil
        catalogPlaybackLoadTask = nil
        shutdownLoaders()
        itemStatusCancellable = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        isPlaying = false
        currentTime = 0
        networkSkipMessage = failure.userMessage
        updateNowPlaying()
    }

    private static func httpStatus(of item: AVPlayerItem) -> Int? {
        if let code = item.errorLog()?.events.map(\.errorStatusCode).last(where: { $0 > 0 }) { return code }
        var error = item.error as NSError?
        while let current = error {
            if let code = current.userInfo["HTTPStatusCode"] as? Int { return code }
            error = current.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return nil
    }

    /// Existing body of `loadCurrent` after its Starter/MixDeck checks. It receives the resolved
    /// transient asset and therefore keeps buildItem/cache behavior intact.
    private func finishOrdinaryLoad(row: TrackRow, asset: Asset, autoplay: Bool) {
        smartBlendFallbackToken = nil
        stopMixDecks()
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
            lastLocalFailure = nil
            built = ordinaryBuildItemHook?(asset) ?? buildItem(for: asset)
        }
        // TEMPORARY diagnostic — real, repeated report ("I click on a track
        // I've played before and nothing happens"), 4th occurrence despite
        // 3 distinct fixes this session. Remove once root-caused live.
        loadingLog.notice("loadCurrent: track \(row.track.id ?? -1, privacy: .public) \"\(row.track.title, privacy: .public)\" kind=\(asset.kind.rawValue, privacy: .public) reusedPreload=\(reusedPreload, privacy: .public) remoteURL=\(asset.remoteURL ?? "nil", privacy: .public) transientSupportsByteRanges=\(asset.transientRemoteSupportsByteRanges, privacy: .public) autoplay=\(autoplay, privacy: .public)")
        preloadedNextItem = nil
        preloadedNextTrackId = nil
        preloadedNextLoader = nil

        if built == nil, let failure = lastLocalFailure {
            lastLocalFailure = nil
            failLocalPlayback(failure)
            return
        }
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
            let assetOptions = audioAssetOptions(for: remote)

            // Jamendo's resolved stream URL is a query-only URL (`?trackid=…&format=mp32`),
            // so the cache blob has no filename extension.  Once the blob is complete,
            // play it directly and provide AVFoundation the format hint it cannot infer
            // from the extensionless cache filename.  This also makes cached playback
            // independent of Jamendo's current signed URL response.
            if AudioCache.completeCacheExists(for: remote) {
                let cachedURL = AudioCache.fileURL(for: AudioCache.key(for: remote))
                if FileManager.default.fileExists(atPath: cachedURL.path) {
                    loadingLog.notice("loadCurrent: using complete cached file for \(remote.absoluteString, privacy: .public) mime=\(assetOptions[AVURLAssetOverrideMIMETypeKey] as? String ?? "none", privacy: .public)")
                    return (AVPlayerItem(asset: AVURLAsset(url: cachedURL, options: assetOptions)), nil)
                }
            }

            if !asset.transientRemoteSupportsByteRanges {
                return (directRemoteItem(url: remote, headers: asset.transientRemoteHeaders), nil)
            }
            let cacheURL = RemoteAudioURL.cacheURL(for: remote, scheme: AudioCache.scheme)
            let avAsset = AVURLAsset(url: cacheURL, options: assetOptions)
            let loader = CachingResourceLoader(originalURL: remote, store: AudioCache.shared, config: AudioCache.loaderConfig(headers: asset.transientRemoteHeaders))
            avAsset.resourceLoader.setDelegate(loader, queue: loaderQueue)
            return (AVPlayerItem(asset: avAsset), loader)
        } else if asset.bookmark != nil || asset.relPath != nil {
            let diag = LocalPlaybackDiagnostics.shared
            let loadID = diag.makeLoadID()
            diag.record(.resolveStart, loadID: loadID)
            do {
                let resolved = try localResolver.resolve(asset)
                diag.record(.resolveEnd, loadID: loadID)
                diag.record(resolved.lease != nil ? .accessAcquired : .itemBuilt, loadID: loadID)
                localLog.notice("local item resolved backing=\(resolved.backing.rawValue, privacy: .public) stale=\(resolved.bookmarkWasStale, privacy: .public) kind=\(asset.kind.rawValue, privacy: .public)")
                return (LocalPlayerItem(url: resolved.url, lease: resolved.lease, backing: resolved.backing), nil)
            } catch {
                lastLocalFailure = error
                diag.record(error == .accessDenied ? .accessDenied : .metadataError, loadID: loadID)
                localLog.error("local item unavailable class=\(error.logClass, privacy: .public) kind=\(asset.kind.rawValue, privacy: .public)")
                return nil
            }
        }
        return nil
    }

    /// Controlled stop for a local item that cannot play: leaves the player idle
    /// (releasing the item and its scoped-access lease) and tells the user why.
    func failLocalPlayback(_ failure: LocalMediaFailure) {
        localReadinessTask?.cancel()
        itemStatusCancellable = nil
        player.pause()
        (player.currentItem as? LocalPlayerItem)?.releaseLease()
        player.replaceCurrentItem(with: nil)
        isPlaying = false
        currentTime = 0
        networkSkipMessage = failure.userMessage
        updateNowPlaying()
    }

    private func watchLocalReadiness(of item: LocalPlayerItem) {
        let started = ContinuousClock.now
        let timeout = localReadinessTimeout
        localReadinessTask?.cancel()
        localReadinessTask = Task { @MainActor [weak self, weak item] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self, let item,
                  self.player.currentItem === item, item.status == .unknown else { return }
            localLog.error("local readiness timeout elapsed=\(String(describing: ContinuousClock.now - started), privacy: .public) backing=\(item.backing.rawValue, privacy: .public)")
            self.failLocalPlayback(.readinessTimeout)
        }
    }

    /// AVFoundation cannot infer a media type from Jamendo's extensionless
    /// `format=mp32` URLs or from their extensionless cache blobs.  Keep this
    /// inference at the app boundary so the shared streaming package remains
    /// provider-agnostic.
    private func audioAssetOptions(for remote: URL) -> [String: Any] {
        guard let mime = remoteAudioMIMEType(for: remote) else { return [:] }
        return [AVURLAssetOverrideMIMETypeKey: mime]
    }

    func remoteAudioMIMEType(for remote: URL) -> String? {
        if let mime = RemoteAudioURL.contentTypeMIME(for: remote) {
            return mime
        }
        guard let queryItems = URLComponents(url: remote, resolvingAgainstBaseURL: false)?.queryItems else {
            return nil
        }
        for name in ["format", "audioformat", "audiodlformat"] {
            guard let value = queryItems.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })?.value?.lowercased() else {
                continue
            }
            switch value {
            case "mp3", "mp31", "mp32", "mpeg": return "audio/mpeg"
            case "m4a", "aac", "mp4": return "audio/mp4"
            case "flac": return "audio/flac"
            case "wav": return "audio/wav"
            case "aif", "aiff": return "audio/aiff"
            default: continue
            }
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
        networkSkipMessage = String(localized: "Skipped \(row.track.title): Wi-Fi only", bundle: .module)
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
    func preloadNextItem(allowingMixDecks: Bool = false) {
        guard !isAmbient, repeatMode != .one, allowingMixDecks || (mixDecks == nil && starterStream == nil) else { return }
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

    /// Discards the preloaded next item (and its scoped-access lease) without playing it.
    func dropPreloadedNext() {
        preloadedNextLoader?.shutdown()
        (preloadedNextItem as? LocalPlayerItem)?.releaseLease()
        preloadedNextItem = nil
        preloadedNextTrackId = nil
        preloadedNextLoader = nil
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
        let outgoing = player.currentItem
        player.replaceCurrentItem(with: item)
        if outgoing !== item {
            (outgoing as? LocalPlayerItem)?.releaseLease()
            LocalPlaybackDiagnostics.shared.record(outgoing is LocalPlayerItem ? .accessReleased : .playerReplaced, loadID: 0)
        }
        loadedSourceSampleRate = 0
        // TEMPORARY diagnostic — see loadCurrent's matching comment. Logs
        // every status transition (unknown -> readyToPlay/failed) and the
        // real underlying error if AVFoundation ever reports one, which
        // print-based debugging of this exact bug has never captured yet.
        let trackTitle = currentTrack?.track.title ?? "?"
        itemStatusCancellable = item.publisher(for: \.status)
            // KVO fires on an AVFoundation queue; this closure is main-actor isolated
            // (Swift 6), so it must be delivered on the main queue or the runtime traps.
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak item] status in
                if let self, status == .failed, let item, self.player.currentItem === item,
                   self.ordinaryJamendoLoad != nil {
                    self.handleOrdinaryJamendoTerminalLoaderFailure(httpStatus: Self.httpStatus(of: item))
                    return
                }
                if let self, let local = item as? LocalPlayerItem, self.player.currentItem === local {
                    switch status {
                    case .readyToPlay:
                        self.localReadinessTask?.cancel()
                        LocalPlaybackDiagnostics.shared.record(.itemStatus, loadID: 0, values: ["status": status.rawValue])
                        localLog.notice("local item ready backing=\(local.backing.rawValue, privacy: .public)")
                    case .failed:
                        localLog.error("local item failed backing=\(local.backing.rawValue, privacy: .public)")
                        self.failLocalPlayback(.unreadableMedia)
                        return
                    default: break
                    }
                }
                loadingLog.notice("replaceItem: status change for \"\(trackTitle, privacy: .public)\" -> \(String(describing: status), privacy: .public), error=\(String(describing: item?.error), privacy: .public)")
            }
        // Drop EQ taps for items no longer in play (the outgoing current item,
        // and any preloaded item that wasn't the one we advanced to).
        eqTap?.prune(keeping: [item, preloadedNextItem].compactMap { $0 })
        let asset = item.asset
        Task { @MainActor [weak self, asset, weak item] in
            guard let self, let item,
                  self.player.currentItem === item,
                  let audioTracks = asset.tracks(withMediaType: .audio),
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
        if let local = item as? LocalPlayerItem { watchLocalReadiness(of: local) } else { localReadinessTask?.cancel() }
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
