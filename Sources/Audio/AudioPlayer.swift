#if !os(watchOS)
import Foundation
import AVFoundation
import ParsoAudioStreaming
import Combine
import Network

@MainActor
public final class AudioPlayer: ObservableObject {
    public static let shared = AudioPlayer()

    @Published public internal(set) var queue: [TrackRow] = []
    @Published public internal(set) var index: Int = 0
    @Published public internal(set) var isPlaying = false
    @Published public internal(set) var isStalled = false
    @Published public internal(set) var currentTime: Double = 0
    @Published public internal(set) var duration: Double = 0
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
    /// "Keep Playing" (main-library path only — DJ decks stay fully manual):
    /// when the manually-built queue is about to run out, extend it with more
    /// tracks instead of stopping. On by default. Turning it off removes any
    /// not-yet-played auto-added tail (`removeUnplayedKeepPlayingTracks`).
    @Published public var keepPlayingEnabled = true {
        didSet {
            guard keepPlayingEnabled != oldValue else { return }
            if !keepPlayingEnabled { removeUnplayedKeepPlayingTracks() }
        }
    }
    /// How many tracks a single Keep Playing extension appends. Exposed so
    /// Settings can let the user tune it (CLAUDE.md "let them drill down for
    /// more info in settings").
    public var keepPlayingBatchSize = 15
    /// The core track ids of every track Keep Playing has appended to the
    /// current queue (played or not) — what lets the queue UI mark them as
    /// "Extended by Keep Playing" instead of a track the user chose.
    @Published public internal(set) var keepPlayingAutoAddedTrackIDs: Set<Int64> = []
    /// True when the most recent Keep Playing extension had to fall back to a
    /// shuffle-continue (the CLAP similarity index wasn't available) rather
    /// than a real similarity pick — surfaced in the UI per CLAUDE.md
    /// "no silent/magic background work": a substituted behavior is never
    /// silent.
    @Published public internal(set) var keepPlayingLastExtensionWasFallback = false
    /// Why the last fallback happened, `nil` when the last extension was a
    /// real similarity pick (or nothing has extended yet this session).
    @Published public internal(set) var keepPlayingFallbackReason: KeepPlayingFallbackReason?
    /// The CLAP similarity seam (plan: `SearchService`/`VectorIndex`, C01–C09).
    /// `TonearmCore` cannot import `TonearmDiscovery` directly — that package
    /// already depends on `TonearmCore`, so the app wires the real adapter in
    /// after launch via this seam instead. `nil` (the default, and always the
    /// case under `swift test`) means Keep Playing always uses the honest
    /// shuffle-continue fallback.
    public var keepPlayingProvider: (any KeepPlayingSimilarityProviding)?
    /// Every track that has actually started playing during the current
    /// continuous-play session (most recent last), oldest-first. Reset by a
    /// fresh `play(tracks:startAt:)`. Keep Playing never re-suggests a track
    /// already in here, and the immediately-preceding entry is the
    /// "just-played track" it must never repeat.
    var keepPlayingHistory: [Int64] = []
    var keepPlayingExtensionInFlight = false
    /// Real report: "Keep Playing is on, but after a mood search's matches
    /// finish, I get dead air — nothing in the queue." Root cause: `next()`
    /// below permanently pauses when the queue is exhausted, with no path
    /// back to playing once the in-flight extension (`maybeExtendKeepPlaying
    /// Queue`, triggered when 1-2 tracks remain) finishes appending rows —
    /// `finishKeepPlayingExtension` only mutates `queue`, it never resumes.
    /// A mood queue's extension re-runs a live query (slower than the local
    /// vector lookup other sources use), so it's the most likely to still be
    /// running when the last track ends and lose this race. Set only when
    /// `next()` pauses specifically because it ran out of queue while an
    /// extension was still in flight; `finishKeepPlayingExtension` checks it
    /// to resume automatically once real tracks land, instead of leaving
    /// them queued-but-silent.
    var isWaitingForKeepPlayingToResume = false
    /// The queue `index` Keep Playing last attempted an extension from, so a
    /// second `loadCurrent` for the same index (no queue-shape change) never
    /// double-fires the lookup.
    var keepPlayingLastExtensionAttemptIndex: Int?
    /// Handle to the in-flight extension lookup, so a fresh `play(tracks:)`
    /// or a test teardown can cancel it outright instead of leaving a
    /// detached `Task` free to mutate `queue`/`keepPlayingAutoAddedTrackIDs`
    /// well after the state it was computed for is gone — `AudioPlayer` is
    /// a process-wide singleton, so an uncancelled extension from one
    /// session (or one test) can otherwise resolve during a later,
    /// unrelated one. `performKeepPlayingExtension` checks
    /// `Task.isCancelled` before doing anything observable.
    var keepPlayingExtensionTask: Task<Void, Never>?
    @Published public internal(set) var cacheState: CacheGlyphState = .none
    @Published public internal(set) var cachePercent: Int = 0
    @Published public internal(set) var cachedFraction: Double = 0
    @Published public internal(set) var isAmbient = false
    @Published public internal(set) var ambientChannelId: String?
    @Published public internal(set) var pathIsExpensive = false
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
    @Published public internal(set) var sleepTimerEndsAt: Date?

    var player = AVPlayer()
    var loopPlayer: AVQueuePlayer?
    var audioLooper: AVPlayerLooper?
    var timeObserver: Any?
    var itemEndObserver: NSObjectProtocol?
    var timeControlCancellable: AnyCancellable?
    var restoreTask: Task<Void, Never>?
    var isRestoring = false
    var pendingRestoreSeek: Double?
    /// Injectable persistence funnel: tests can swap in fakes/spies.
    public var persistor = PlaybackPositionPersistor()
    var loaders: [CachingResourceLoader] = []
    let loaderQueue = DispatchQueue(label: "guru.parso.tonearm.loaders")
    var stallModel = StallModel()
    var prefetchedURLs: [Int64: URL] = [:]
    /// Active prefetch loaders keyed by track id, so skipping a track can cancel
    /// its in-flight fetch (T3.5).
    var prefetchLoaders: [Int64: CachingResourceLoader] = [:]
    let retryPolicy = RetryPolicy()
    var unshuffledQueue: [TrackRow] = []
    /// Near-gapless (T2.5): the next queue item, preloaded (with its cache/EQ
    /// attached) so the boundary swap is seamless rather than a fresh teardown.
    var preloadedNextItem: AVPlayerItem?
    var preloadedNextTrackId: Int64?
    var preloadedNextLoader: CachingResourceLoader?
    var loadedSourceSampleRate: Double = 0
    var crossfadePlayer: AVPlayer?
    var crossfadeNextTrackId: Int64?
    var crossfadeNextIndex: Int?
    var crossfadeNextLoader: CachingResourceLoader?
    var crossfadeCompletionInFlight = false
    /// EQ (T4.1): a single tap engine shared across items; reattached to the
    /// preloaded next item so EQ survives near-gapless swaps.
    var eqTap: EQAudioTap?
    let pathMonitor = NWPathMonitor()
    let pathMonitorQueue = DispatchQueue(label: "guru.parso.tonearm.network")
    var sleepTimerTask: Task<Void, Never>?

    /// The platform seam. Defaults to a no-op so the queue/shuffle/repeat logic is
    /// host-testable; the app installs `SystemPlaybackBridge` via
    /// `attachPlatformBridge(_:)` at launch.
    var bridge: PlaybackPlatformBridge = NoopPlaybackBridge()

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
        // A manually-started queue begins a fresh Keep Playing session: no
        // history to avoid repeating, nothing auto-added yet. Cancel any
        // extension still in flight from the PREVIOUS session/queue — it was
        // computed against state that no longer exists, and letting it
        // resolve later would append tracks (or record a fallback reason)
        // against this new, unrelated queue.
        keepPlayingExtensionTask?.cancel()
        keepPlayingExtensionTask = nil
        keepPlayingExtensionInFlight = false
        isWaitingForKeepPlayingToResume = false
        keepPlayingHistory = []
        keepPlayingAutoAddedTrackIDs = []
        keepPlayingLastExtensionAttemptIndex = nil
        keepPlayingLastExtensionWasFallback = false
        keepPlayingFallbackReason = nil
        if shuffle { applyShuffle() }
        loadCurrent(autoplay: true)
    }

    public func playSingle(_ track: TrackRow) {
        play(tracks: [track], startAt: 0)
    }

    /// Replaces everything after the currently-playing track with `tracks`
    /// without interrupting playback — the "Update upcoming" behavior a
    /// re-rolled mood query needs, as opposed to `play(tracks:startAt:
    /// source:)`, which always restarts from a fresh index 0 (mirrors
    /// Acalum's "Update upcoming" vs. "Play now" distinction — docs/plans/
    /// mood-based-listening-plan.md §3.1 point 5). Falls back to a normal
    /// `play(tracks:startAt:source:)` when nothing is queued yet, since
    /// there is no "currently playing track" to preserve.
    public func updateUpcoming(with tracks: [TrackRow], source: QueueSource) {
        guard !isAmbient else { return }
        guard !queue.isEmpty else {
            play(tracks: tracks, startAt: 0, source: source)
            return
        }
        queueSource = source
        let kept = Array(queue.prefix(index + 1))
        let edited = QueueEditor.State(queue: kept + tracks, currentIndex: index)
        applyQueueEdit(edited, reloadCurrent: false, autoplay: isPlaying)
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
        if isPlaying {
            player.pause()
        } else {
            seekToStartIfAtEnd()
            player.play()
        }
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
            if keepPlayingEnabled, keepPlayingExtensionInFlight {
                isWaitingForKeepPlayingToResume = true
            }
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

    public func skipToIndex(_ newIndex: Int) {
        if isAmbient { return }
        guard queue.indices.contains(newIndex), newIndex != index else { return }
        index = newIndex
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

    func applyQueueEdit(_ edited: QueueEditor.State<TrackRow>,
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

    func clearQueuePlayback() {
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
        Task { await AudioCache.shared.setProtectedKeys([]) }

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
}
#endif
