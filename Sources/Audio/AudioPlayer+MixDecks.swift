#if !os(watchOS)
import Foundation
import AVFoundation
import OSLog

private let mixDecksLog = Logger(subsystem: "guru.parso.tonearm", category: "MixDecks")

/// Smart transitions play on the mix decks (MixDeckPlayer), the app's one
/// planner and mixer for blends: the approved dj2 blends need both tracks on one
/// sample clock with a crossover in their path, which two AVPlayers can't give.
/// Everything else about the queue (index, Now Playing, persistence, Keep
/// Playing) stays in AudioPlayer. AVPlayer plays queues without smart
/// transitions, with the user's plain crossfade at most.
extension AudioPlayer: MixDeckHost {
    /// Whether the current queue plays on the mix decks: mixes, every queue when
    /// "Use for everything" is on, and auditions.
    var wantsMixDecks: Bool {
        guard !isAmbient else { return false }
        if auditionRequested { return true }
        guard smartTransitionsEnabled else { return false }
        if case .mix = queueSource { return true }
        return UserDefaults.standard.bool(forKey: "smartTransitionsEverywhere")
    }

    /// Loads the current track onto the mix decks. False when the decks can't
    /// be created, and the caller plays it on AVPlayer instead.
    func loadCurrentOnMixDecks(row: TrackRow, autoplay: Bool) -> Bool {
        if mixDecks == nil {
            do {
                mixDecks = try MixDeckPlayer(host: self)
            } catch {
                mixDecksLog.error("mix decks unavailable, playing on AVPlayer: \(error.localizedDescription, privacy: .public)")
                return false
            }
        }
        guard let mixDecks else { return false }
        cancelCrossfade(resetVolume: true)
        shutdownLoaders()
        preloadedNextLoader?.shutdown()
        preloadedNextItem = nil
        preloadedNextTrackId = nil
        preloadedNextLoader = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        transitionPlan = nil

        mixDecks.volume = outputLevel
        mixDecks.blendsEnabled = smartTransitionsEnabled
        currentTime = 0
        duration = row.track.durationSec ?? 0
        isPlaying = autoplay
        mixDecks.start(index: index, at: 0, autoplay: autoplay)
        updateNowPlaying()
        prefetchNext()
        if autoplay, let trackId = row.track.id {
            Task { try? await LibraryStore.shared.recordPlay(trackId: trackId) }
        }
        maybeExtendKeepPlayingQueue()
        return true
    }

    /// Resumes the decks, restarting the current track when it had played out.
    func resumeMixDecks(_ mixDecks: MixDeckPlayer) {
        if mixDecks.current == nil || mixDecks.hasReachedEnd {
            mixDecks.start(index: index, at: 0, autoplay: true)
        } else {
            mixDecks.resume()
        }
    }

    func stopMixDecks() {
        guard let mixDecks else { return }
        mixDecks.stop()
        self.mixDecks = nil
        transitionPlan = nil
        transitionPrepState = .ready
    }

    // MARK: - MixDeckHost

    var mixDecksCurrentIndex: Int { index }

    func mixDecksUpcomingIndex(after current: Int) -> Int? {
        guard !queue.isEmpty, repeatMode != .one, !sleepAtEndOfTrack else { return nil }
        let next: Int
        if current < queue.count - 1 {
            next = current + 1
        } else if repeatMode == .all, queue.count > 1 {
            next = 0
        } else {
            return nil
        }
        // An unplayable or Wi-Fi-only next track isn't blended into; when the
        // current one ends, next() skips it as it would without the decks.
        guard let asset = queue[next].asset, asset.unsupportedReason == nil,
              playbackDecision(for: asset) != .skipWiFiOnly else { return nil }
        return next
    }

    func mixDecksEdge(from: Int, to: Int) -> MixDeckEdge {
        guard queue.indices.contains(from), queue.indices.contains(to) else { return .blend }
        if CrossfadeCurve.suppressesForGaplessAlbum(current: CrossfadeCurve.AlbumContinuity(row: queue[from]),
                                                    next: CrossfadeCurve.AlbumContinuity(row: queue[to])) {
            return .gapless
        }
        if case .mix(let mix) = queueSource,
           mix.transitionPlans.contains(where: {
               $0.fromTrackID == queue[from].track.id && $0.toTrackID == queue[to].track.id
                   && $0.style == .plainCrossfade
           }) {
            return .fade
        }
        return .blend
    }

    func mixDecksTrack(at index: Int) -> (trackID: Int64, source: MixTrackSource, bpm: Double?)? {
        guard queue.indices.contains(index), let id = queue[index].track.id,
              let asset = queue[index].asset, let source = mixTrackSource(for: asset) else { return nil }
        return (id, source, nil)
    }

    func mixDecksDidAdvance(to scheduledIndex: Int, trackID: Int64, duration trackDuration: Double) -> Int {
        // The queue may have been edited since the blend was scheduled: find the track again.
        let newIndex: Int
        if queue.indices.contains(scheduledIndex), queue[scheduledIndex].track.id == trackID {
            newIndex = scheduledIndex
        } else if let found = queue.indices.first(where: { $0 > index && queue[$0].track.id == trackID })
                    ?? queue.indices.first(where: { queue[$0].track.id == trackID }) {
            newIndex = found
        } else {
            return scheduledIndex
        }
        index = newIndex
        let row = queue[newIndex]
        duration = row.track.durationSec ?? trackDuration
        if let seconds = mixDecks?.currentSeconds { currentTime = seconds }
        if let trackId = row.track.id {
            recordKeepPlayingHistory(trackId)
            Task { try? await LibraryStore.shared.recordPlay(trackId: trackId) }
        }
        updateNowPlaying()
        prefetchNext()
        maybeExtendKeepPlayingQueue()
        return newIndex
    }

    func mixDecksDidReachEnd(trackID: Int64) {
        guard currentTrack?.track.id == trackID else { return }
        if sleepAtEndOfTrack {
            sleepAtEndOfTrack = false
            pause()
            return
        }
        next()
    }

    func mixDecksCouldNotPlay(index failedIndex: Int, reason: String) {
        let title = queue.indices.contains(failedIndex) ? queue[failedIndex].track.title : "?"
        mixDecksLog.error("mix decks: skipping \"\(title, privacy: .public)\": \(reason, privacy: .public)")
        networkSkipMessage = String(localized: "Skipped \(title): \(reason)", bundle: .module)
        guard failedIndex == index else { return }
        next()
    }

    func mixDecksPosition(seconds: Double) {
        let previous = currentTime
        currentTime = seconds
        if abs(seconds - previous) >= 0.5 || seconds < previous {
            updateNowPlayingTime()
        }
        persistTick()
    }

    func mixDecksLoading(_ loading: Bool) {
        guard isStalled != loading else { return }
        isStalled = loading
        updateNowPlaying()
    }

    func mixDecksPublish(plan: TransitionPlan?, state: GridPrepState) {
        transitionPlan = plan
        transitionPrepState = state
    }

    // MARK: - Sources

    /// Where the mix decks read an asset: the same choices as `buildItem`
    /// (Opus CAF, bundled, complete cache, stream, bookmark, managed file).
    func mixTrackSource(for asset: Asset) -> MixTrackSource? {
        if let opusString = asset.opusRemoteURL, let opusURL = URL(string: opusString) {
            let caf = AudioCache.cafURL(forRemoteOpus: opusURL)
            if FileManager.default.fileExists(atPath: caf.path) {
                return .file(caf, container: .caf, securityScoped: false)
            }
        }
        if asset.kind == .builtIn, let channelId = asset.relPath,
           let url = BuiltInContentProvider.bundledAudioURL(forChannelId: channelId) {
            return .file(url, container: .auto, securityScoped: false)
        }
        if asset.kind == .remote, let urlString = remoteURLString(for: asset), let remote = URL(string: urlString) {
            let container = remote.pathExtension.isEmpty
                ? MixTrackLoader.container(forMIME: remoteAudioMIMEType(for: remote)) : .auto
            if AudioCache.completeCacheExists(for: remote) {
                let cached = AudioCache.fileURL(for: AudioCache.key(for: remote))
                if FileManager.default.fileExists(atPath: cached.path) {
                    return .file(cached, container: container == .auto
                                 ? MixTrackLoader.container(forExtension: remote.pathExtension) : container,
                                 securityScoped: false)
                }
            }
            let cacheKey = asset.transientRemoteSupportsByteRanges ? AudioCache.key(for: remote) : nil
            return .remote(remote, headers: asset.transientRemoteHeaders, container: container, cacheKey: cacheKey)
        }
        if let bookmark = asset.bookmark, let (url, _) = BookmarkVault.resolve(bookmark) {
            return .file(url, container: .auto, securityScoped: true)
        }
        if let rel = asset.relPath {
            return .file(managedURL(rel), container: .auto, securityScoped: false)
        }
        return nil
    }
}
#endif
