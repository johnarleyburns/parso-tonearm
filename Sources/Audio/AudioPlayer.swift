import Foundation
import AVFoundation
import MediaPlayer
import Combine
import UIKit

enum RepeatMode: String, CaseIterable {
    case off, all, one
}

enum QueueSource: Equatable {
    case source(Source)
    case playlist(Playlist)
    case library
    case ambient
    case none

    var label: String {
        switch self {
        case .source(let s): return "From Source: \(s.title)"
        case .playlist(let p): return "From Playlist: \(p.title)"
        case .library: return "From Library"
        case .ambient: return "Ambient"
        case .none: return ""
        }
    }
}

@MainActor
final class AudioPlayer: ObservableObject {
    static let shared = AudioPlayer()

    @Published private(set) var queue: [TrackRow] = []
    @Published private(set) var index: Int = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published var shuffle = false {
        didSet {
            guard shuffle != oldValue else { return }
            if shuffle {
                applyShuffle()
            } else {
                restoreShuffle()
            }
        }
    }
    @Published var repeatMode: RepeatMode = .off
    @Published private(set) var cacheState: CacheGlyphState = .none
    @Published private(set) var cachePercent: Int = 0
    @Published private(set) var cachedFraction: Double = 0
    @Published private(set) var isAmbient = false
    @Published private(set) var ambientChannelId: String?
    @Published var queueSource: QueueSource = .none

    var streamOnCellular = true
    var prefetchDepth = 2
    var preferFLAC = false
    var sleepAtEndOfTrack = false

    private var player = AVPlayer()
    private var loopPlayer: AVQueuePlayer?
    private var audioLooper: AVPlayerLooper?
    private var timeObserver: Any?
    private var itemEndObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?
    private var loaders: [CachingResourceLoader] = []
    private let loaderQueue = DispatchQueue(label: "guru.parso.tonearm.loaders")
    private var stallModel = StallModel()
    private var prefetchedURLs: [Int64: URL] = [:]
    /// Active prefetch loaders keyed by track id, so skipping a track can cancel
    /// its in-flight fetch (T3.5).
    private var prefetchLoaders: [Int64: CachingResourceLoader] = [:]
    private let retryPolicy = RetryPolicy()
    private var unshuffledQueue: [TrackRow] = []
    /// Near-gapless (T2.5): the next queue item, preloaded (with its cache/EQ
    /// attached) so the boundary swap is seamless rather than a fresh teardown.
    private var preloadedNextItem: AVPlayerItem?
    private var preloadedNextTrackId: Int64?
    private var preloadedNextLoader: CachingResourceLoader?
    /// EQ (T4.1): a single tap engine shared across items; reattached to the
    /// preloaded next item so EQ survives near-gapless swaps.
    private var eqTap: EQAudioTap?

    var currentTrack: TrackRow? {
        if isAmbient, let channelId = ambientChannelId {
            return BuiltInContentProvider.allTrackRows.first {
                $0.asset?.relPath?.contains(channelId) == true
            } ?? queue.first
        }
        guard queue.indices.contains(index) else { return nil }
        return queue[index]
    }

    var upNextTracks: [TrackRow] {
        if isAmbient { return [] }
        guard index < queue.count - 1 else { return [] }
        return Array(queue.dropFirst(index + 1))
    }

    private init() {
        configureSession()
        setupRemoteCommands()
        addPeriodicObserver()
        observeRouteChanges()
    }

    // MARK: - Public control

    func play(tracks: [TrackRow], startAt start: Int, source: QueueSource = .none) {
        shutdownLoopPlayer()
        unshuffledQueue = []
        queueSource = source
        queue = tracks
        index = max(0, min(start, tracks.count - 1))
        if shuffle { applyShuffle() }
        loadCurrent(autoplay: true)
    }

    func playSingle(_ track: TrackRow) {
        play(tracks: [track], startAt: 0)
    }

    func togglePlayPause() {
        if isAmbient {
            if isPlaying { loopPlayer?.pause() } else { loopPlayer?.play() }
            isPlaying.toggle()
            updateNowPlaying()
            return
        }
        if isPlaying { player.pause() } else { player.play() }
        isPlaying.toggle()
        updateNowPlaying()
    }

    func next() {
        if isAmbient { nextAmbientTrack(); return }
        guard !queue.isEmpty else { return }
        if repeatMode == .one { seek(to: 0); player.play(); return }
        if index < queue.count - 1 {
            index += 1
        } else if repeatMode == .all {
            index = 0
        } else {
            player.pause(); isPlaying = false; return
        }
        loadCurrent(autoplay: true)
    }

    func previous() {
        if isAmbient { previousAmbientTrack(); return }
        guard !queue.isEmpty else { return }
        if currentTime > 3 { seek(to: 0); return }
        index = max(0, index - 1)
        loadCurrent(autoplay: true)
    }

    func seek(to seconds: Double) {
        guard !isAmbient else { return }
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: time)
        currentTime = seconds
    }

    // MARK: - Loading

    private func loadCurrent(autoplay: Bool) {
        guard let row = currentTrack, let asset = row.asset else { return }

        if let reason = asset.unsupportedReason {
            _ = reason
            next()
            return
        }

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
        applyEQ(to: item)
        if autoplay {
            player.play()
            isPlaying = true
        }
        duration = row.track.durationSec ?? 0
        updateNowPlaying()
        prefetchNext()
        preloadNextItem()
        if let trackId = row.track.id {
            Task { try? await LibraryStore.shared.recordPlay(trackId: trackId) }
        }
    }

    /// Builds an `AVPlayerItem` (and its cache loader, if remote) for an asset,
    /// applying the "Opus when ready" policy (T2.4): if a remuxed `.caf` exists
    /// for the track's Opus derivative, play that local file; otherwise cold-play
    /// FLAC/MP3 via the caching resource loader. The loader is returned rather
    /// than attached, so callers (near-gapless preload) can own it.
    private func buildItem(for asset: Asset) -> (item: AVPlayerItem, loader: CachingResourceLoader?)? {
        // Opus-when-ready: a remuxed CAF upgrades playback to Opus.
        if let opusString = asset.opusRemoteURL, let opusURL = URL(string: opusString) {
            let caf = CacheStore.cafURL(forRemoteOpus: opusURL)
            if FileManager.default.fileExists(atPath: caf.path) {
                return (AVPlayerItem(url: caf), nil)
            }
        }

        if asset.kind == .remote, let urlString = remoteURLString(for: asset), let remote = URL(string: urlString) {
            let cacheURL = CachingResourceLoader.cacheURL(for: remote)
            let avAsset = AVURLAsset(url: cacheURL)
            let loader = CachingResourceLoader(originalURL: remote)
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

    /// Preloads the upcoming track's `AVPlayerItem` (with its own cache loader)
    /// so the natural track boundary swaps to a ready item instead of tearing the
    /// player down and rebuilding (T2.5). No-op when there is no next track, when
    /// the next item is unsupported, or when it is already preloaded.
    private func preloadNextItem() {
        guard !isAmbient, repeatMode != .one else { return }
        let nextIndex: Int
        if index < queue.count - 1 {
            nextIndex = index + 1
        } else if repeatMode == .all, !queue.isEmpty {
            nextIndex = 0
        } else {
            return
        }
        guard queue.indices.contains(nextIndex) else { return }
        let row = queue[nextIndex]
        guard let asset = row.asset, asset.unsupportedReason == nil else { return }
        guard preloadedNextTrackId != row.track.id else { return }
        guard let built = buildItem(for: asset) else { return }
        built.item.preferredForwardBufferDuration = 120
        applyEQ(to: built.item)
        preloadedNextItem = built.item
        preloadedNextTrackId = row.track.id
        preloadedNextLoader = built.loader
    }

    private func shutdownLoaders() {
        let oldLoaders = loaders
        loaders.removeAll()
        for loader in oldLoaders {
            loader.shutdown()
        }
    }

    // MARK: - EQ (T4.1)

    /// Applies the current EQ state to an item via `MTAudioProcessingTap` when the
    /// EQ is enabled and Pro is active. Detaching happens naturally in the same
    /// teardown path as `shutdownLoaders()` (the item's audioMix is dropped when
    /// the item is replaced). Reattaches on the preloaded next item so EQ survives
    /// near-gapless swaps.
    private func applyEQ(to item: AVPlayerItem) {
        guard ProFeature.isEnabled(.eq), EQSettings.isEnabled else {
            item.audioMix = nil
            return
        }
        let engine = EQEngine(gains: EQSettings.gains, bypassed: false)
        let tap = EQAudioTap(engine: engine)
        eqTap = tap
        Task { @MainActor in
            if let mix = await tap.makeAudioMix(for: item) {
                item.audioMix = mix
            }
        }
    }

    /// Live-updates EQ gains on the currently playing item without interrupting
    /// playback (engage/disengage is glitch-free). Call from the EQ settings UI.
    func updateEQ(gains: [Double], enabled: Bool) {
        EQSettings.gains = gains
        EQSettings.isEnabled = enabled
        guard ProFeature.isEnabled(.eq) else { return }
        if let tap = eqTap, enabled {
            tap.update(gains: gains, bypassed: false)
        } else if let item = player.currentItem {
            // Toggled on/off: (re)attach or clear the mix on the live item.
            applyEQ(to: item)
        }
    }

    /// Chooses the FLAC alternate when the user prefers lossless and one exists,
    /// otherwise the primary (MP3) URL.
    private func remoteURLString(for asset: Asset) -> String? {
        if preferFLAC, let alt = asset.altRemoteURL, !alt.isEmpty { return alt }
        return asset.remoteURL
    }

    private func replaceItem(_ item: AVPlayerItem) {
        if let obs = itemEndObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        player.replaceCurrentItem(with: item)
        itemEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.sleepAtEndOfTrack {
                    self.sleepAtEndOfTrack = false
                    self.pause()
                    return
                }
                self.next()
            }
        }
    }

    private func managedURL(_ rel: String) -> URL {
        let base = try! FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                appropriateFor: nil, create: true)
        return base.appendingPathComponent(rel)
    }

    // MARK: - Prefetch (FR-3.5)

    private func prefetchNext() {
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
                  let urlString = remoteURLString(for: asset), let remote = URL(string: urlString) else { continue }
            if prefetchLoaders[trackId] != nil { continue }  // already prefetching
            prefetchedURLs[trackId] = remote
            let loader = CachingResourceLoader(originalURL: remote)
            prefetchLoaders[trackId] = loader
            let cacheURL = CachingResourceLoader.cacheURL(for: remote)
            Task.detached(priority: .background) {
                let avAsset = AVURLAsset(url: cacheURL)
                avAsset.resourceLoader.setDelegate(loader, queue: DispatchQueue(label: "prefetch"))
                let item = AVPlayerItem(asset: avAsset)
                _ = item
            }
            // "Opus when ready" (T2.4): fetch the Opus derivative and remux it to
            // CAF so the NEXT play/repeat of this track upgrades to Opus. Cold play
            // above stays on the instant FLAC/MP3 — no added latency on the tap.
            if let opusString = asset.opusRemoteURL, let opusURL = URL(string: opusString) {
                prefetchOpusAndRemux(opusURL)
            }
            // Cache the artwork alongside its music so prefetched tracks are
            // fully available offline, not just their audio bytes.
            Task.detached(priority: .background) {
                _ = await ArtworkService.shared.artwork(forTrackRow: row)
            }
        }
    }

    /// Downloads a complete Opus derivative into the stream cache and remuxes it
    /// to a sibling CAF. Skips work when a CAF already exists or the key was
    /// already marked unavailable. Fire-and-forget; failures fall back silently.
    private func prefetchOpusAndRemux(_ opusURL: URL) {
        let caf = CacheStore.cafURL(forRemoteOpus: opusURL)
        guard !FileManager.default.fileExists(atPath: caf.path) else { return }
        let key = CachingResourceLoader.key(for: opusURL)
        Task.detached(priority: .background) {
            if await OpusRemuxer.shared.isUnavailable(key) { return }
            let dest = CacheStore.fileURL(for: key)
            do {
                let (tmp, response) = try await URLSession.shared.download(from: opusURL)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return }
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: tmp, to: dest)
                let bytes = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64) ?? nil
                if let b = bytes { await CacheStore.shared.setContentLength(b, for: key) }
                let cafURL = try await OpusRemuxer.shared.remux(opusFileURL: dest, cacheKey: key)
                let cafSize = (try? FileManager.default.attributesOfItem(atPath: cafURL.path)[.size] as? Int64) ?? nil
                await CacheStore.shared.recordCAFBytes(cafSize ?? 0, for: key)
            } catch {
                await OpusRemuxer.shared.markUnavailable(key)
            }
        }
    }

    // MARK: - Observers

    private func addPeriodicObserver() {
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            Task { @MainActor in
                let previous = self.currentTime
                self.currentTime = time.seconds
                if let d = self.player.currentItem?.duration.seconds, d.isFinite, d > 0 {
                    self.duration = d
                }
                if time.seconds > 0 && time.seconds != previous {
                    self.stallModel.confirmPlayback(generation: self.stallModel.loadGeneration)
                }
                self.refreshCacheState()
                self.updateNowPlayingTime()
            }
        }
    }

    private func refreshCacheState() {
        guard let asset = currentTrack?.asset, asset.kind == .remote,
              let urlString = remoteURLString(for: asset), let remote = URL(string: urlString) else {
            cacheState = .cached
            cachePercent = 100
            cachedFraction = 1
            return
        }
        let key = CachingResourceLoader.key(for: remote)
        Task {
            let state = await CacheStore.shared.state(for: key)
            let map = await CacheStore.shared.rangeMap(for: key)
            let total = await CacheStore.shared.totalBytes(for: key) ?? 0
            await MainActor.run {
                self.cacheState = state
                if total > 0 {
                    self.cachedFraction = min(1, Double(map.totalBytes()) / Double(total))
                    self.cachePercent = Int((self.cachedFraction * 100).rounded())
                }
            }
        }
    }

    // MARK: - Session / Remote

    private func configureSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
    }

    private func observeRouteChanges() {
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil, queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                guard let self, self.isPlaying else { return }
                guard let reasonRaw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                      let reason = AVAudioSession.RouteChangeReason(rawValue: reasonRaw) else { return }
                let prevKey = AVAudioSessionRouteChangePreviousRouteKey
                let prevRoute = notification.userInfo?[prevKey] as? AVAudioSessionRouteDescription
                let prevHadExternal = prevRoute?.outputs.contains(where: { $0.portType != .builtInSpeaker }) == true

                switch reason {
                case .oldDeviceUnavailable:
                    if prevHadExternal { self.pause() }
                case .routeConfigurationChange:
                    let currentOutputs = AVAudioSession.sharedInstance().currentRoute.outputs
                    let isBuiltInOnly = currentOutputs.allSatisfy { $0.portType == .builtInSpeaker }
                    if isBuiltInOnly && prevHadExternal { self.pause() }
                default: break
                }
            }
        }
    }

    private func setupRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in self?.resume(); return .success }
        c.pauseCommand.addTarget { [weak self] _ in self?.pause(); return .success }
        c.nextTrackCommand.addTarget { [weak self] _ in self?.next(); return .success }
        c.previousTrackCommand.addTarget { [weak self] _ in self?.previous(); return .success }
        c.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.seek(to: e.positionTime)
            return .success
        }
    }

    private func resume() { player.play(); isPlaying = true; updateNowPlaying() }
    private func pause() { player.pause(); isPlaying = false; updateNowPlaying() }

    private func updateNowPlaying() {
        guard let row = currentTrack else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: row.track.title,
            MPMediaItemPropertyArtist: row.album?.artist ?? "archive.org",
            MPMediaItemPropertyPlaybackDuration: isAmbient ? 0 : duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: isAmbient ? 0 : currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]
        info[MPMediaItemPropertyAlbumTitle] = row.album?.title
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        Task {
            if let image = await ArtworkService.shared.artwork(forTrackRow: row) {
                let art = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                var current = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                current[MPMediaItemPropertyArtwork] = art
                MPNowPlayingInfoCenter.default().nowPlayingInfo = current
            }
        }
    }

    private func updateNowPlayingTime() {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: - Built-in / Ambient

    func playAmbient(channelId: String) {
        guard let url = BuiltInContentProvider.bundledAudioURL(forChannelId: channelId) else { return }
        shutdownLoopPlayer()
        shutdownLoaders()
        player.pause()
        player.replaceCurrentItem(with: nil)

        isAmbient = true
        ambientChannelId = channelId
        queueSource = .ambient

        let item = AVPlayerItem(url: url)
        let qp = AVQueuePlayer()
        qp.actionAtItemEnd = .advance
        audioLooper = AVPlayerLooper(player: qp, templateItem: item)
        loopPlayer = qp

        if let row = BuiltInContentProvider.allTrackRows.first(where: {
            $0.asset?.relPath?.contains(channelId) == true
        }) {
            queue = [row]
            index = 0
            duration = 0
            currentTime = 0
        }

        qp.play()
        isPlaying = true
        cacheState = .cached
        cachePercent = 100
        cachedFraction = 1
        updateNowPlaying()
    }

    func nextAmbientTrack() {
        guard isAmbient, let currentId = ambientChannelId else { return }
        let allIds = BuiltInContentProvider.tracks.map { $0.channelId }
        guard let idx = allIds.firstIndex(of: currentId) else { return }
        let nextIdx = (idx + 1) % allIds.count
        playAmbient(channelId: allIds[nextIdx])
    }

    func previousAmbientTrack() {
        guard isAmbient, let currentId = ambientChannelId else { return }
        let allIds = BuiltInContentProvider.tracks.map { $0.channelId }
        guard let idx = allIds.firstIndex(of: currentId) else { return }
        let prevIdx = (idx - 1 + allIds.count) % allIds.count
        playAmbient(channelId: allIds[prevIdx])
    }

    private func loadBuiltInAsset(_ asset: Asset, row: TrackRow, autoplay: Bool) {
        guard let relPath = asset.relPath else { return }
        let name = (relPath as NSString).deletingPathExtension
        let ext = (relPath as NSString).pathExtension
        guard let url = Bundle.main.url(forResource: name, withExtension: ext) else { return }

        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 120
        item.automaticallyPreservesTimeOffsetFromLive = false

        replaceItem(item)
        if autoplay {
            player.play()
            isPlaying = true
        }
        duration = row.track.durationSec ?? 0
        updateNowPlaying()
    }

    private func shutdownLoopPlayer() {
        loopPlayer?.pause()
        audioLooper?.disableLooping()
        audioLooper = nil
        loopPlayer = nil
        isAmbient = false
        ambientChannelId = nil
    }

    // MARK: - Shuffle & Repeat

    private func applyShuffle() {
        guard queue.count > 1 else { return }
        unshuffledQueue = queue
        let current = queue[index]
        var rest = queue
        rest.remove(at: index)
        rest.shuffle()
        queue = [current] + rest
        index = 0
        invalidatePreloadedNext()
    }

    private func restoreShuffle() {
        guard !unshuffledQueue.isEmpty else { return }
        if let current = currentTrack,
           let origIdx = unshuffledQueue.firstIndex(where: { $0.id == current.id }) {
            queue = unshuffledQueue
            index = origIdx
        }
        unshuffledQueue = []
        invalidatePreloadedNext()
    }

    /// Drops any preloaded next item whose position no longer follows the current
    /// track (e.g. after shuffle reorders the queue), then repreloads.
    private func invalidatePreloadedNext() {
        preloadedNextLoader?.shutdown()
        preloadedNextItem = nil
        preloadedNextTrackId = nil
        preloadedNextLoader = nil
        preloadNextItem()
    }

    func cycleRepeatMode() {
        repeatMode = switch repeatMode {
        case .off: .all
        case .all: .one
        case .one: .off
        }
    }

    func toggleShuffle() {
        shuffle.toggle()
    }
}
