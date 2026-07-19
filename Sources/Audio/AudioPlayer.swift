import Foundation
import AVFoundation
import Combine
import Network

public enum RepeatMode: String, CaseIterable {
    case off, all, one
}

public enum QueueSource: Equatable {
    case source(Source)
    case playlist(Playlist)
    case library
    case ambient
    case none

    public var label: String {
        switch self {
        case .source(let s): return "From Library: \(s.title)"
        case .playlist(let p): return "From Playlist: \(p.title)"
        case .library: return "From Music"
        case .ambient: return "Ambient"
        case .none: return ""
        }
    }
}

@MainActor
public final class AudioPlayer: ObservableObject {
    public static let shared = AudioPlayer()

    @Published public private(set) var queue: [TrackRow] = []
    @Published public private(set) var index: Int = 0
    @Published public private(set) var isPlaying = false
    @Published public private(set) var isStalled = false
    @Published public private(set) var currentTime: Double = 0
    @Published public private(set) var duration: Double = 0
    @Published public var shuffle = false {
        didSet {
            guard shuffle != oldValue else { return }
            if shuffle {
                applyShuffle()
            } else {
                restoreShuffle()
            }
        }
    }
    @Published public var repeatMode: RepeatMode = .off
    @Published public private(set) var cacheState: CacheGlyphState = .none
    @Published public private(set) var cachePercent: Int = 0
    @Published public private(set) var cachedFraction: Double = 0
    @Published public private(set) var isAmbient = false
    @Published public private(set) var ambientChannelId: String?
    @Published public private(set) var pathIsExpensive = false
    @Published public var networkSkipMessage: String?
    @Published public var queueSource: QueueSource = .none

    public var streamOnCellular = true
    public var prefetchDepth = 2
    public var preferFLAC = false
    public var replayGainMode: ReplayGain.Mode = .track
    public var replayGainPreampDB: Double = 0
    public var replayGainPreventClipping = true
    public var crossfadeSeconds: Double = 0 {
        didSet {
            if normalizedCrossfadeSeconds == 0 {
                cancelCrossfade(resetVolume: true)
            }
        }
    }
    public var crossfadeCurve: CrossfadeCurve = .equalPower
    public var sleepAtEndOfTrack = false
    @Published public private(set) var sleepTimerEndsAt: Date?

    private var player = AVPlayer()
    private var loopPlayer: AVQueuePlayer?
    private var audioLooper: AVPlayerLooper?
    private var timeObserver: Any?
    private var itemEndObserver: NSObjectProtocol?
    private var timeControlCancellable: AnyCancellable?
    private var restoreTask: Task<Void, Never>?
    private var isRestoring = false
    private var pendingRestoreSeek: Double?
    /// Injectable persistence funnel: tests can swap in fakes/spies.
    public var persistor = PlaybackPositionPersistor()
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
    private var crossfadePlayer: AVPlayer?
    private var crossfadeNextTrackId: Int64?
    private var crossfadeNextIndex: Int?
    private var crossfadeNextLoader: CachingResourceLoader?
    private var crossfadeCompletionInFlight = false
    /// EQ (T4.1): a single tap engine shared across items; reattached to the
    /// preloaded next item so EQ survives near-gapless swaps.
    private var eqTap: EQAudioTap?
    private let pathMonitor = NWPathMonitor()
    private let pathMonitorQueue = DispatchQueue(label: "guru.parso.tonearm.network")
    private var sleepTimerTask: Task<Void, Never>?

    /// The platform seam. Defaults to a no-op so the queue/shuffle/repeat logic is
    /// host-testable; the app installs `SystemPlaybackBridge` via
    /// `attachPlatformBridge(_:)` at launch.
    private var bridge: PlaybackPlatformBridge = NoopPlaybackBridge()

    /// The observed playback truth: playing AND not stalled/buffering. Drives
    /// advancing playback surfaces so they freeze at the real position during
    /// stalls, interruptions, and pauses.
    public var isAdvancing: Bool { isPlaying && !isStalled }

    public var currentTrack: TrackRow? {
        if isAmbient, let channelId = ambientChannelId {
            return BuiltInContentProvider.allTrackRows.first {
                $0.asset?.relPath?.contains(channelId) == true
            } ?? queue.first
        }
        guard queue.indices.contains(index) else { return nil }
        return queue[index]
    }

    public var upNextTracks: [TrackRow] {
        if isAmbient { return [] }
        guard index < queue.count - 1 else { return [] }
        return Array(queue.dropFirst(index + 1))
    }

    private init() {
        addPeriodicObserver()
        observeTimeControlStatus()
        observeNetworkPath()
    }

    /// Installs the real platform bridge and starts the iOS-only integrations
    /// (audio session, remote commands, route/interruption observation). Called
    /// once at app launch; never called under `swift test`, which keeps the
    /// no-op bridge.
    public func attachPlatformBridge(_ bridge: PlaybackPlatformBridge) {
        self.bridge = bridge
        bridge.configureSession()
        bridge.setupRemoteCommands(
            resume: { [weak self] in
                Task { @MainActor [weak self] in await self?.withRestoredQueue { self?.resume() } }
            },
            pause: { [weak self] in
                Task { @MainActor [weak self] in await self?.withRestoredQueue { self?.pause() } }
            },
            next: { [weak self] in
                Task { @MainActor [weak self] in await self?.withRestoredQueue { self?.next() } }
            },
            previous: { [weak self] in
                Task { @MainActor [weak self] in await self?.withRestoredQueue { self?.previous() } }
            },
            seek: { [weak self] seconds in self?.seek(to: seconds) })
        bridge.startObservers(
            routeShouldPause: { [weak self] in
                guard let self, self.isPlaying else { return }
                self.pause()
            },
            interruptionPause: { [weak self] in self?.pausePlayback() },
            interruptionResume: { [weak self] in self?.resumePlayback() })
    }

    // MARK: - Public control

    public func play(tracks: [TrackRow], startAt start: Int, source: QueueSource = .none) {
        shutdownLoopPlayer()
        unshuffledQueue = []
        queueSource = source
        queue = tracks
        index = max(0, min(start, tracks.count - 1))
        if shuffle { applyShuffle() }
        loadCurrent(autoplay: true)
    }

    public func playSingle(_ track: TrackRow) {
        play(tracks: [track], startAt: 0)
    }

    public func moveQueueItems(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        guard !isAmbient, offsets.count == 1, let source = offsets.first else { return }
        let target = destination > source ? destination - 1 : destination
        moveQueueItem(from: source, to: target)
    }

    public func moveQueueItem(from source: Int, to destination: Int) {
        guard !isAmbient else { return }
        let edited = QueueEditor.move(
            from: source,
            to: destination,
            in: QueueEditor.State(queue: queue, currentIndex: index))
        applyQueueEdit(edited, reloadCurrent: false, autoplay: isPlaying)
    }

    public func removeFromQueue(atOffsets offsets: IndexSet) {
        guard !isAmbient, !offsets.isEmpty else { return }
        var state = QueueEditor.State(queue: queue, currentIndex: index)
        var removedCurrent = false
        for offset in offsets.sorted(by: >) {
            let normalized = state.normalized
            if offset == normalized.currentIndex { removedCurrent = true }
            state = QueueEditor.remove(at: offset, in: normalized)
        }
        applyQueueEdit(state, reloadCurrent: removedCurrent, autoplay: isPlaying)
    }

    public func removeFromQueue(at position: Int) {
        removeFromQueue(atOffsets: IndexSet(integer: position))
    }

    public func insertNext(_ row: TrackRow) {
        guard !isAmbient else { return }
        let wasEmpty = queue.isEmpty
        let edited = QueueEditor.insertNext(
            row,
            in: QueueEditor.State(queue: queue, currentIndex: index))
        applyQueueEdit(edited, reloadCurrent: wasEmpty, autoplay: false)
    }

    public func appendToQueue(_ row: TrackRow) {
        guard !isAmbient else { return }
        let wasEmpty = queue.isEmpty
        let edited = QueueEditor.append(
            row,
            in: QueueEditor.State(queue: queue, currentIndex: index))
        applyQueueEdit(edited, reloadCurrent: wasEmpty, autoplay: false)
    }

    public func togglePlayPause() {
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

    public func resumePlayback() {
        guard !isPlaying else {
            updateNowPlaying()
            return
        }
        if isAmbient {
            loopPlayer?.play()
            isPlaying = true
            updateNowPlaying()
        } else {
            resume()
        }
    }

    public func pausePlayback() {
        guard isPlaying else {
            updateNowPlaying()
            return
        }
        if isAmbient {
            loopPlayer?.pause()
            isPlaying = false
            updateNowPlaying()
        } else {
            pause()
        }
    }

    public func applySleepTimer(_ plan: IntentResolver.SleepTimerPlan, now: Date = Date()) {
        sleepTimerTask?.cancel()
        sleepTimerTask = nil
        sleepTimerEndsAt = nil

        switch plan {
        case .minutes(let minutes):
            sleepAtEndOfTrack = false
            let end = now.addingTimeInterval(TimeInterval(minutes * 60))
            sleepTimerEndsAt = end
            sleepTimerTask = Task { [weak self] in
                let remaining = max(0, end.timeIntervalSinceNow)
                guard remaining > 0 else { return }
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self, self.sleepTimerEndsAt == end else { return }
                    self.pausePlayback()
                    self.sleepTimerEndsAt = nil
                    self.sleepTimerTask = nil
                }
            }
        case .endOfTrack:
            sleepAtEndOfTrack = true
        case .cancel:
            sleepAtEndOfTrack = false
        }
    }

    public func next() {
        if isAmbient { nextAmbientTrack(); return }
        guard !queue.isEmpty else { return }
        if repeatMode == .one { seek(to: 0); player.play(); return }
        if index < queue.count - 1 {
            index += 1
        } else if repeatMode == .all {
            index = 0
        } else {
            player.pause(); isPlaying = false; updateNowPlaying(); return
        }
        loadCurrent(autoplay: true)
    }

    public func previous() {
        if isAmbient { previousAmbientTrack(); return }
        guard !queue.isEmpty else { return }
        if currentTime > 3 { seek(to: 0); return }
        index = max(0, index - 1)
        loadCurrent(autoplay: true)
    }

    public func seek(to seconds: Double) {
        guard !isAmbient else { return }
        pendingRestoreSeek = nil  // user-initiated seek cancels restore confirmation
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: time)
        currentTime = seconds
        updateNowPlayingTime()
        persist(reason: .userSeek)
        bridge.publishSnapshot(self)
    }

    private func applyQueueEdit(_ edited: QueueEditor.State<TrackRow>,
                                reloadCurrent: Bool,
                                autoplay: Bool) {
        queue = edited.queue
        index = edited.currentIndex
        if shuffle { unshuffledQueue = queue }

        guard !queue.isEmpty else {
            clearQueuePlayback()
            return
        }

        if reloadCurrent {
            loadCurrent(autoplay: autoplay)
        } else {
            invalidatePreloadedNext()
            prefetchNext()
            updateNowPlaying()
        }
    }

    private func clearQueuePlayback() {
        cancelCrossfade(resetVolume: true)
        shutdownLoaders()
        for loader in prefetchLoaders.values {
            loader.shutdown()
        }
        prefetchLoaders.removeAll()
        prefetchedURLs.removeAll()
        preloadedNextLoader?.shutdown()
        preloadedNextItem = nil
        preloadedNextTrackId = nil
        preloadedNextLoader = nil
        Task { await CacheStore.shared.setProtectedKeys([]) }

        player.pause()
        player.replaceCurrentItem(with: nil)
        isPlaying = false
        currentTime = 0
        duration = 0
        cacheState = .none
        cachePercent = 0
        cachedFraction = 0
        queueSource = .none
        applySleepTimer(.cancel)
        persist(reason: .userClear)
        bridge.clearNowPlaying()
    }

    // MARK: - Loading

    private func loadCurrent(autoplay: Bool) {
        guard let row = currentTrack, let asset = row.asset else { return }

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
        applyEQ(to: item, row: row, setLiveTap: true)
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
            if !asset.transientRemoteSupportsByteRanges {
                return (directRemoteItem(url: remote, headers: asset.transientRemoteHeaders), nil)
            }
            let cacheURL = CachingResourceLoader.cacheURL(for: remote)
            let avAsset = AVURLAsset(url: cacheURL)
            let loader = CachingResourceLoader(originalURL: remote, headers: asset.transientRemoteHeaders)
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

    private func directRemoteItem(url: URL, headers: [String: String]) -> AVPlayerItem {
        guard !headers.isEmpty else { return AVPlayerItem(url: url) }
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        return AVPlayerItem(asset: asset)
    }

    private func networkAssetKind(for asset: Asset) -> NetworkPolicy.AssetKind {
        asset.kind == .remote ? .remote : .local
    }

    private func playbackDecision(for asset: Asset) -> PlaybackDecision {
        NetworkPolicy.decide(
            assetKind: networkAssetKind(for: asset),
            isCached: isFullyCached(asset),
            pathIsExpensive: pathIsExpensive,
            streamOnCellular: streamOnCellular
        )
    }

    private func isFullyCached(_ asset: Asset) -> Bool {
        guard asset.kind == .remote,
              asset.transientRemoteSupportsByteRanges,
              let urlString = remoteURLString(for: asset),
              let remote = URL(string: urlString) else {
            return asset.kind != .remote
        }
        return CacheStore.completeCacheExists(for: remote)
    }

    private func skipCurrentForWiFiOnly(row: TrackRow) {
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
    private func preloadNextItem() {
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
        applyEQ(to: built.item, row: row, setLiveTap: false)
        preloadedNextItem = built.item
        preloadedNextTrackId = row.track.id
        preloadedNextLoader = built.loader
    }

    private func upcomingQueueIndex() -> Int? {
        guard !queue.isEmpty, !isAmbient, repeatMode != .one else { return nil }
        if index < queue.count - 1 { return index + 1 }
        if repeatMode == .all, queue.count > 1 { return 0 }
        return nil
    }

    // MARK: - Crossfade

    private var normalizedCrossfadeSeconds: Double {
        guard crossfadeSeconds.isFinite else { return 0 }
        return max(0, crossfadeSeconds)
    }

    private func updateCrossfade(position: Double) {
        let fadeSeconds = normalizedCrossfadeSeconds
        guard fadeSeconds > 0,
              !sleepAtEndOfTrack,
              let nextIndex = upcomingQueueIndex(),
              queue.indices.contains(nextIndex),
              let current = currentTrack else {
            cancelCrossfade(resetVolume: true)
            return
        }

        let next = queue[nextIndex]
        guard !CrossfadeCurve.suppressesForGaplessAlbum(
            current: CrossfadeCurve.AlbumContinuity(row: current),
            next: CrossfadeCurve.AlbumContinuity(row: next)
        ) else {
            cancelCrossfade(resetVolume: true)
            return
        }

        let currentDuration = duration > 0 ? duration : (current.track.durationSec ?? 0)
        let gains = CrossfadeCurve.gains(position: position,
                                         duration: currentDuration,
                                         fadeSeconds: fadeSeconds,
                                         curve: crossfadeCurve)
        guard gains.active else {
            player.volume = 1
            return
        }

        guard prepareCrossfadePlayer(for: next, at: nextIndex) else { return }
        player.volume = Float(min(max(gains.outgoing, 0), 1))
        crossfadePlayer?.volume = Float(min(max(gains.incoming, 0), 1))
        crossfadePlayer?.play()

        if gains.incoming >= 1 || position >= currentDuration {
            finishCrossfade(to: nextIndex, row: next)
        }
    }

    @discardableResult
    private func prepareCrossfadePlayer(for row: TrackRow, at nextIndex: Int) -> Bool {
        if crossfadePlayer != nil,
           crossfadeNextTrackId == row.track.id,
           crossfadeNextIndex == nextIndex {
            return true
        }

        cancelCrossfade(resetVolume: false)
        guard let asset = row.asset,
              asset.unsupportedReason == nil,
              playbackDecision(for: asset) != .skipWiFiOnly else {
            return false
        }

        let built: (item: AVPlayerItem, loader: CachingResourceLoader?)?
        if let preloadedNextItem, preloadedNextTrackId == row.track.id {
            built = (preloadedNextItem, preloadedNextLoader)
            self.preloadedNextItem = nil
            preloadedNextTrackId = nil
            preloadedNextLoader = nil
        } else {
            built = buildItem(for: asset)
        }

        guard let built else { return false }
        built.item.preferredForwardBufferDuration = 120
        built.item.automaticallyPreservesTimeOffsetFromLive = false
        applyEQ(to: built.item, row: row, setLiveTap: false)

        let nextPlayer = AVPlayer(playerItem: built.item)
        nextPlayer.volume = 0
        crossfadePlayer = nextPlayer
        crossfadeNextTrackId = row.track.id
        crossfadeNextIndex = nextIndex
        crossfadeNextLoader = built.loader
        nextPlayer.play()
        return true
    }

    private func finishCrossfade(to nextIndex: Int, row: TrackRow) {
        guard !crossfadeCompletionInFlight,
              let nextPlayer = crossfadePlayer,
              queue.indices.contains(nextIndex) else {
            return
        }
        crossfadeCompletionInFlight = true
        defer { crossfadeCompletionInFlight = false }

        let oldPlayer = player
        let oldLoaders = loaders
        loaders.removeAll()

        if let obs = itemEndObserver {
            NotificationCenter.default.removeObserver(obs)
            itemEndObserver = nil
        }
        if let observer = timeObserver {
            oldPlayer.removeTimeObserver(observer)
            timeObserver = nil
        }
        timeControlCancellable = nil

        oldPlayer.pause()
        oldPlayer.replaceCurrentItem(with: nil)
        oldLoaders.forEach { $0.shutdown() }

        player = nextPlayer
        player.volume = 1
        if let loader = crossfadeNextLoader {
            loaders.append(loader)
        }
        crossfadePlayer = nil
        crossfadeNextTrackId = nil
        crossfadeNextIndex = nil
        crossfadeNextLoader = nil

        index = nextIndex
        let seconds = player.currentTime().seconds
        currentTime = seconds.isFinite ? max(0, seconds) : 0
        if let rowDuration = row.track.durationSec {
            duration = rowDuration
        } else {
            let itemDuration = player.currentItem?.duration.seconds ?? 0
            duration = itemDuration.isFinite && itemDuration > 0 ? itemDuration : 0
        }
        if let item = player.currentItem {
            observeEnd(of: item)
        }
        addPeriodicObserver()
        observeTimeControlStatus()
        updateNowPlaying()
        prefetchNext()
        preloadNextItem()
        if let trackId = row.track.id {
            Task { try? await LibraryStore.shared.recordPlay(trackId: trackId) }
        }
    }

    private func cancelCrossfade(resetVolume: Bool) {
        guard crossfadePlayer != nil || crossfadeNextLoader != nil || crossfadeNextIndex != nil else {
            if resetVolume { player.volume = 1 }
            return
        }
        crossfadePlayer?.pause()
        crossfadePlayer?.replaceCurrentItem(with: nil)
        crossfadePlayer = nil
        crossfadeNextTrackId = nil
        crossfadeNextIndex = nil
        crossfadeNextLoader?.shutdown()
        crossfadeNextLoader = nil
        crossfadeCompletionInFlight = false
        if resetVolume { player.volume = 1 }
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
    /// EQ is enabled. Detaching happens naturally in the same teardown path as
    /// `shutdownLoaders()` (the item's audioMix is dropped when the item is
    /// replaced). Reattaches on the preloaded next item so EQ survives near-gapless
    /// swaps.
    private func applyEQ(to item: AVPlayerItem, row: TrackRow, setLiveTap: Bool) {
        let settings = EQSettingsPersistence.load()
        let store = EQSettingsStore(presets: EQSettingsPersistence.allPresets())
        let proAudio = ProAudioSettingsPersistence.load()
        let replayGain = replayGainValue(for: row.track)
        // The tap must attach whenever ANY stage is non-transparent: the 10-band
        // EQ, ReplayGain, OR the pro-audio chain. Without the pro-audio clause a
        // flat EQ + unity ReplayGain would strand the parametric/crossfeed/
        // convolution stages (the historical bug).
        guard settings.enabled || replayGain != 1 || !proAudio.isTransparent else {
            item.audioMix = nil
            return
        }
        let gains = settings.enabled ? store.effectiveBands(for: settings).map(Double.init)
            : Array(repeating: 0, count: EQEngine.bandCount)
        let tap = EQAudioTap(
            engine: EQEngine(gains: gains, bypassed: !settings.enabled),
            settings: proAudio,
            replayGain: replayGain)
        if setLiveTap { eqTap = tap }
        Task { @MainActor in
            if let mix = await tap.makeAudioMix(for: item) {
                item.audioMix = mix
            }
        }
    }

    /// Live-updates EQ gains on the currently playing item without interrupting
    /// playback (engage/disengage is glitch-free). Call from the EQ settings UI.
    public func updateEQ(gains: [Double], enabled: Bool) {
        let settings = EQSettings(bands: gains.map(Float.init), enabled: enabled, activePresetID: nil)
        updateEQ(settings: settings)
    }

    public func updateEQ(settings: EQSettings) {
        let store = EQSettingsStore(presets: EQSettingsPersistence.allPresets())
        let normalized = store.normalized(settings)
        EQSettingsPersistence.save(normalized)
        pushLiveAudioProcessing(eqEnabled: normalized.enabled,
                                gains: store.effectiveBands(for: normalized).map(Double.init))
    }

    /// Pushes the current Pro Audio settings into the live tap (from the Pro Tools
    /// audio sliders). Mirrors `updateEQ(settings:)`.
    public func updateProAudio(_ settings: ProAudioSettings) {
        ProAudioSettingsPersistence.save(settings)
        let eqSettings = EQSettingsPersistence.load()
        let store = EQSettingsStore(presets: EQSettingsPersistence.allPresets())
        let gains = eqSettings.enabled ? store.effectiveBands(for: eqSettings).map(Double.init)
            : Array(repeating: 0, count: EQEngine.bandCount)
        pushLiveAudioProcessing(eqEnabled: eqSettings.enabled, gains: gains)
    }

    /// Shared live-update path: pushes EQ + Pro Audio + ReplayGain into the running
    /// tap without interrupting playback, attaching or clearing the mix as the
    /// combined transparency changes.
    private func pushLiveAudioProcessing(eqEnabled: Bool, gains: [Double]) {
        let proAudio = ProAudioSettingsPersistence.load()
        let replayGain = currentTrack.map { replayGainValue(for: $0.track) } ?? 1
        let needsTap = eqEnabled || replayGain != 1 || !proAudio.isTransparent
        if let tap = eqTap, needsTap {
            tap.update(gains: gains, bypassed: !eqEnabled, settings: proAudio, replayGain: replayGain)
        } else if !needsTap {
            player.currentItem?.audioMix = nil
            eqTap = nil
        } else if let item = player.currentItem, let row = currentTrack {
            // Toggled on from a clean chain: (re)attach the mix on the live item.
            applyEQ(to: item, row: row, setLiveTap: true)
        }
    }

    private func replayGainValue(for track: Track) -> Double {
        ReplayGain.appliedGain(
            mode: replayGainMode,
            tags: track.replayGainTags,
            preampDB: replayGainPreampDB,
            preventClipping: replayGainPreventClipping)
    }

    /// The hardware output sample rate the audio session is currently running at.
    public var hardwareSampleRate: Double {
        bridge.sampleRate
    }

    /// The nominal sample rate of the currently loaded source audio track, or 0
    /// when unknown (e.g. nothing playing yet).
    public var currentSourceSampleRate: Double {
        guard let track = player.currentItem?.tracks.first(where: {
            $0.assetTrack?.mediaType == .audio
        }), let assetTrack = track.assetTrack else { return 0 }
        let descriptions = assetTrack.formatDescriptions as? [CMFormatDescription] ?? []
        for description in descriptions {
            if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description) {
                return asbd.pointee.mSampleRate
            }
        }
        return 0
    }

    /// Honest bit-perfect plan for the current state: derived from the REAL
    /// hardware/source rates and the live ReplayGain, never from view `@State`.
    public func bitPerfectPlan(for settings: ProAudioSettings) -> BitPerfectOutputPlan {
        let replayGain = currentTrack.map { replayGainValue(for: $0.track) } ?? 1
        return settings.bitPerfectPlan(
            hardwareSampleRate: hardwareSampleRate,
            sourceSampleRate: currentSourceSampleRate,
            replayGainActive: replayGain != 1)
    }

    /// Chooses the FLAC alternate when the user prefers lossless and one exists,
    /// otherwise the primary (MP3) URL.
    private func remoteURLString(for asset: Asset) -> String? {
        if preferFLAC, let alt = asset.altRemoteURL, !alt.isEmpty { return alt }
        return asset.remoteURL
    }

    private func replaceItem(_ item: AVPlayerItem) {
        player.replaceCurrentItem(with: item)
        observeEnd(of: item)
    }

    private func observeEnd(of item: AVPlayerItem) {
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

    private func managedURL(_ rel: String) -> URL {
        let base = try! FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                appropriateFor: nil, create: true)
        return base.appendingPathComponent(rel)
    }

    /// F6: protects the current track's cache key from eviction while it's playing.
    /// Also protects any active prefetch keys so they aren't evicted mid-stream before
    /// the track advances to them.
    private func protectCacheKeys(for asset: Asset) {
        var keys: Set<String> = []
        if asset.kind == .remote,
           asset.transientRemoteSupportsByteRanges,
           let urlString = remoteURLString(for: asset),
           let remote = URL(string: urlString) {
            keys.insert(CachingResourceLoader.key(for: remote))
        }
        for loader in prefetchLoaders.values {
            keys.insert(loader.cacheKey)
        }
        Task { await CacheStore.shared.setProtectedKeys(keys) }
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
                  asset.transientRemoteSupportsByteRanges,
                  let urlString = remoteURLString(for: asset), let remote = URL(string: urlString) else { continue }
            guard playbackDecision(for: asset) != .skipWiFiOnly else { continue }
            if prefetchLoaders[trackId] != nil { continue }  // already prefetching
            prefetchedURLs[trackId] = remote
            let loader = CachingResourceLoader(originalURL: remote, headers: asset.transientRemoteHeaders)
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
                self.updateCrossfade(position: time.seconds)
                if time.seconds > 0 && time.seconds != previous {
                    self.stallModel.confirmPlayback(generation: self.stallModel.loadGeneration)
                }
                self.refreshCacheState()
                self.updateNowPlayingTime()

                // F3: persist on tick (throttled to ≥1 write/s inside persistTick)
                // F5: seek confirmation for restore
                if let target = self.pendingRestoreSeek {
                    let pos = time.seconds
                    if self.player.currentItem?.status == .readyToPlay,
                       abs(pos - target) > 2 {
                        // Re-issue the seek
                        let cmTime = CMTime(seconds: target, preferredTimescale: 600)
                        await self.player.seek(to: cmTime,
                                         toleranceBefore: .zero,
                                         toleranceAfter: .zero)
                    } else if abs(pos - target) <= 2 {
                        self.pendingRestoreSeek = nil
                        self.persist(reason: .restoreCommit)
                    }
                    // While pending, report target for persistence purposes
                    self.currentTime = target
                }

                self.persistTick()
            }
        }
    }

    /// Observes the player's true playback state (Fix 1). `timeControlStatus` is
    /// the ground truth: manual `isPlaying` flips can't see buffering stalls on
    /// remote streams, which made self-advancing progress sprint ahead while
    /// audio was actually frozen. Re-subscribed after crossfade swaps
    /// the player instance.
    private func observeTimeControlStatus() {
        timeControlCancellable = player.publisher(for: \.timeControlStatus)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.handleTimeControlChange(self.player.timeControlStatus)
                }
            }
    }

    private func handleTimeControlChange(_ status: AVPlayer.TimeControlStatus) {
        guard !isAmbient else { return }
        let wasAdvancing = isAdvancing
        let wasPlaying = isPlaying
        switch status {
        case .playing:
            isPlaying = true
            isStalled = false
        case .waitingToPlayAtSpecifiedRate:
            isStalled = true
        case .paused:
            if crossfadePlayer == nil {
                isPlaying = false
            }
            isStalled = false
        @unknown default:
            break
        }
        if isAdvancing != wasAdvancing || isPlaying != wasPlaying {
            updateNowPlaying()
        }
    }

    private func refreshCacheState() {
        guard let asset = currentTrack?.asset, asset.kind == .remote,
              asset.transientRemoteSupportsByteRanges,
              let urlString = remoteURLString(for: asset), let remote = URL(string: urlString) else {
            if currentTrack?.asset?.kind == .remote {
                cacheState = .none
                cachePercent = 0
                cachedFraction = 0
            } else {
                cacheState = .cached
                cachePercent = 100
                cachedFraction = 1
            }
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

    private func observeNetworkPath() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.pathIsExpensive = path.isExpensive
            }
        }
        pathMonitor.start(queue: pathMonitorQueue)
    }

    private func resume() { player.play(); isPlaying = true; updateNowPlaying() }
    private func pause() { player.pause(); isPlaying = false; updateNowPlaying() }

    private func updateNowPlaying() {
        guard currentTrack != nil else {
            bridge.clearNowPlaying()
            return
        }
        persist(reason: .transportEvent)
        bridge.refreshNowPlaying(self)
    }

    private func updateNowPlayingTime() {
        bridge.refreshNowPlayingTime(self)
    }

    // MARK: - Queue persistence (Fix 2)

    /// Persists the queue/position to the App Group on the same discrete events
    /// that publish now-playing info, so an intent-launched suspended app can
    /// rebuild the player instead of no-oping on an empty queue.
    internal func persistPlaybackState() {
        guard !isAmbient else { return }
        var ids: [Int64] = []
        var syncIDs: [String?] = []
        var currentIndex = 0
        for (position, row) in queue.enumerated() {
            guard let id = row.track.id, id > 0 else { continue }
            if position == index { currentIndex = ids.count }
            ids.append(id)
            syncIDs.append(row.track.syncID)
        }
        guard !ids.isEmpty else {
            PlaybackStateStore.clear()
            return
        }
        PlaybackStateStore.save(PlaybackStateSnapshot(
            trackIDs: ids,
            trackSyncIDs: syncIDs,
            currentIndex: currentIndex,
            elapsed: currentTime,
            isPlaying: isPlaying,
            savedAt: Date()
        ))
    }

    /// Single persistence funnel. Builds a snapshot, then delegates to the
    /// injectable `persistor` (admission policy + composite store).
    internal func persist(reason: PlaybackWriteReason) {
        guard !isAmbient else { return }
        guard !isRestoring else { return }

        var ids: [Int64] = []
        var syncIDs: [String?] = []
        var currentIndex = 0
        for (position, row) in queue.enumerated() {
            guard let id = row.track.id, id > 0 else { continue }
            if position == index { currentIndex = ids.count }
            ids.append(id)
            syncIDs.append(row.track.syncID)
        }

        if ids.isEmpty {
            persistor.save(candidate: nil, reason: reason)
            return
        }

        let candidate = PlaybackStateSnapshot(
            trackIDs: ids,
            trackSyncIDs: syncIDs,
            currentIndex: currentIndex,
            elapsed: currentTime,
            isPlaying: isPlaying,
            savedAt: Date()
        )

        persistor.save(candidate: candidate, reason: reason)
    }

    /// Called from the periodic tick while advancing. Throttled to ≥1 write/s.
    internal func persistTick() {
        guard isAdvancing else { return }
        let now = Date()
        guard now.timeIntervalSince(persistor.lastPersistAt) >= 1.0 else { return }
        persist(reason: .tick)
    }

    /// Exact, unthrottled persist for lifecycle events (app background /
    /// inactive). Admission still applies (G3: tick/background may not regress).
    public func persistNow() {
        persist(reason: .background)
    }

    /// Guarantees the persisted queue is restored before executing `action`, so
    /// cold-launch control surfaces (Siri intents, deep links, lock-screen
    /// commands) work from an empty-player state (F6).
    public func withRestoredQueue(_ action: @MainActor () -> Void) async {
        if queue.isEmpty, !isAmbient {
            await restorePersistedQueue()
        }
        action()
    }

    /// Rebuilds the queue from the persisted state (paused, no autoplay) when the
    /// player is empty. Runs at most once per process; concurrent callers await
    /// the same restore.
    public func restorePersistedQueue() async {
        if let restoreTask {
            await restoreTask.value
            return
        }
        let task = Task { await performQueueRestore() }
        restoreTask = task
        await task.value
    }

    /// Resets the once-per-process restore guard so tests can re-run
    /// `restorePersistedQueue()` without restarting the process.
    /// Also clears the restore task so the next call can retry (F5 retry).
    internal func resetRestoreForTesting() {
        restoreTask = nil
    }

    internal func performQueueRestore() async {
        guard queue.isEmpty, !isAmbient else { return }
        guard let saved = await persistor.loadBest(), !saved.trackIDs.isEmpty else { return }

        let plan = await QueueRestorePlanner.plan(
            saved: saved,
            resolveByID: { id in try? await LibraryStore.shared.trackRow(id: id) },
            resolveBySyncID: { syncID in try? await LibraryStore.shared.trackRow(syncID: syncID) }
        )

        guard let plan, !plan.rows.isEmpty, queue.isEmpty, !isAmbient else {
            // Retry: if nothing was restored, allow a second attempt later
            // (needed for post-CloudKit-reconcile second attempt, F8).
            restoreTask = nil
            return
        }

        isRestoring = true
        pendingRestoreSeek = nil

        queue = plan.rows
        index = plan.startIndex
        loadCurrent(autoplay: false)

        // Set currentTime to the seek target immediately so persist during the
        // seek window is accurate. Seek with zero tolerance for precision.
        currentTime = plan.seekTo
        if plan.seekTo > 0 {
            let cmTime = CMTime(seconds: plan.seekTo, preferredTimescale: 600)
            await player.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
            pendingRestoreSeek = plan.seekTo
        }

        isRestoring = false

        if pendingRestoreSeek == nil {
            persist(reason: .restoreCommit)
        }
    }

    // MARK: - Built-in / Ambient

    public func playAmbient(channelId: String) {
        guard let url = BuiltInContentProvider.bundledAudioURL(forChannelId: channelId) else { return }
        cancelCrossfade(resetVolume: true)
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

    public func nextAmbientTrack() {
        guard isAmbient, let currentId = ambientChannelId else { return }
        let allIds = BuiltInContentProvider.tracks.map { $0.channelId }
        guard let idx = allIds.firstIndex(of: currentId) else { return }
        let nextIdx = (idx + 1) % allIds.count
        playAmbient(channelId: allIds[nextIdx])
    }

    public func previousAmbientTrack() {
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
        cancelCrossfade(resetVolume: true)
        preloadedNextLoader?.shutdown()
        preloadedNextItem = nil
        preloadedNextTrackId = nil
        preloadedNextLoader = nil
        preloadNextItem()
    }

    public func cycleRepeatMode() {
        repeatMode = switch repeatMode {
        case .off: .all
        case .all: .one
        case .one: .off
        }
    }

    public func toggleShuffle() {
        shuffle.toggle()
    }
}
