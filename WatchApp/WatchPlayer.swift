import Foundation
import SwiftUI
import AVFoundation
import MediaPlayer
import TonearmCore

@MainActor
final class WatchPlayer: ObservableObject {
    static let shared = WatchPlayer()

    @Published var currentTrack: TrackRow?
    @Published var isPlaying = false
    @Published var volume: Double = 0.5
    @Published var elapsed: Double = 0
    @Published var duration: Double = 0
    @Published var isShuffled = false
    @Published var repeatMode: WatchRepeatMode = .off
    @Published var showFetchOverlay = false
    @Published var fetchProgress: Double = 0
    @Published var fetchingTrackTitle = ""

    private var engine = WatchPlayerEngine()
    private var output = AVPlayerOutput()
    private var queue: [TrackRow] = []
    private var positionTimer: Timer?

    var queueTracks: [TrackRow] { queue }

    private init() {
        output.onItemEnded = { [weak self] in
            Task { @MainActor in self?.handleCommand(.itemEnded) }
        }
        output.onItemFailed = { [weak self] in
            Task { @MainActor in self?.handleCommand(.itemFailed) }
        }
        output.onTimeUpdate = { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                self.elapsed = time
                self.updateNowPlayingTime()
            }
        }
        setupRemoteCommands()
    }

    // MARK: - Public API

    func play(tracks: [TrackRow], startAt: Int) {
        guard !tracks.isEmpty else { return }
        queue = tracks
        engine.setQueue(tracks.map { WatchCatalog.key(for: $0.track.id ?? -1) }, startIndex: startAt)
        let row = startAt < tracks.count ? tracks[startAt] : tracks[0]
        currentTrack = row
        guard let url = resolveURL(for: row) else {
            showFetchFor(row)
            return
        }
        handleCommand(.play)
    }

    func togglePlayPause() {
        guard !queue.isEmpty else { return }
        handleCommand(.togglePlayPause)
    }

    func next() { handleCommand(.next) }
    func previous() { handleCommand(.previous) }

    func jump(to index: Int) {
        guard index >= 0, index < queue.count else { return }
        handleCommand(.jump(to: index))
    }

    func toggleShuffle() {
        engine.toggleShuffle()
        isShuffled = engine.isShuffled
        rebindQueueFromEngine()
    }

    func cycleRepeat() {
        engine.cycleRepeat()
        repeatMode = engine.repeatMode
    }

    // MARK: - Engine commands

    private func handleCommand(_ cmd: WatchEngineCommand) {
        let directives = engine.command(cmd) { [weak self] key in
            guard let self else { return nil }
            return self.queue.first(where: { WatchCatalog.key(for: $0.track.id ?? -1) == key }).flatMap { self.resolveURL(for: $0) }
        }

        isPlaying = engine.isPlaying
        elapsed = engine.elapsed
        if let key = engine.currentTrack {
            currentTrack = queue.first(where: { WatchCatalog.key(for: $0.track.id ?? -1) == key })
        }
        duration = output.currentDuration

        for d in directives {
            Task { @MainActor in await applyDirective(d) }
        }

        savePosition()
        if let track = currentTrack {
            updateNowPlayingInfo(track: track)
            startPositionTimer()
        } else if engine.queue.isEmpty || !engine.isPlaying {
            stopPositionTimer()
            clearNowPlaying()
        }
    }

    private func applyDirective(_ d: WatchEngineDirective) async {
        switch d {
        case .loadItem(let url): await output.load(url: url); duration = output.currentDuration
        case .play: await output.play()
        case .pause: await output.pause()
        case .seek(let t): await output.seek(to: t)
        case .stop: await output.pause(); clearNowPlaying()
        }
    }

    // MARK: - URL resolution

    private func resolveURL(for row: TrackRow) -> URL? {
        guard let relPath = row.asset?.relPath else { return nil }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let url = appSupport.appendingPathComponent(relPath)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let cacheURL = caches.appendingPathComponent(relPath)
        if FileManager.default.fileExists(atPath: cacheURL.path) { return cacheURL }
        return nil
    }

    // MARK: - Fetch overlay

    private func showFetchFor(_ row: TrackRow) {
        fetchingTrackTitle = row.track.title
        fetchProgress = 0
        showFetchOverlay = true
        let key = WatchCatalog.key(for: row.track.id ?? -1)
        WatchSessionAdapter.shared.sendFetchRequest(trackKey: key)
    }

    func cancelFetch() {
        if let track = currentTrack {
            WatchSessionAdapter.shared.sendCancelFetch(trackKey: WatchCatalog.key(for: track.track.id ?? -1))
        }
        showFetchOverlay = false
        fetchProgress = 0
    }

    // MARK: - Queue rebind

    private func rebindQueueFromEngine() {
        let engineKeys = engine.queue
        var newQueue: [TrackRow] = []
        for key in engineKeys {
            if let row = queue.first(where: { WatchCatalog.key(for: $0.track.id ?? -1) == key }) {
                newQueue.append(row)
            }
        }
        queue = newQueue
        if let key = engine.currentTrack {
            currentTrack = queue.first(where: { WatchCatalog.key(for: $0.track.id ?? -1) == key })
        }
    }

    // MARK: - Position persistence

    private func savePosition() {
        WatchPositionStore.save(engine.snapshot)
    }

    private func startPositionTimer() {
        stopPositionTimer()
        positionTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.savePosition() }
        }
    }

    private func stopPositionTimer() {
        positionTimer?.invalidate()
        positionTimer = nil
    }

    func restorePositionIfAvailable() async {
        guard let snap = WatchPositionStore.loadOrClear(), !snap.trackKeys.isEmpty else { return }
        let rows = (try? await LibraryStore.shared.allTrackRows()) ?? []
        var restored: [TrackRow] = []
        var index = snap.currentIndex
        for key in snap.trackKeys {
            if let row = rows.first(where: { WatchCatalog.key(for: $0.track.id ?? -1) == key }) {
                restored.append(row)
            }
        }
        guard !restored.isEmpty else { return }
        var valid: [TrackRow] = []
        var validIndex = 0
        for (i, row) in restored.enumerated() {
            if resolveURL(for: row) != nil {
                valid.append(row)
                if i == index { validIndex = valid.count - 1 }
            }
        }
        guard !valid.isEmpty else { return }
        queue = valid
        currentTrack = valid.count > validIndex ? valid[validIndex] : valid[0]
        elapsed = snap.elapsed
        engine = WatchPlayerEngine(queue: valid.map { WatchCatalog.key(for: $0.track.id ?? -1) }, startIndex: valid.count > validIndex ? validIndex : 0)
        isPlaying = false
    }

    func clearPosition() { WatchPositionStore.clear() }

    // MARK: - Now Playing

    private func setupRemoteCommands() {
        let cc = MPRemoteCommandCenter.shared()
        cc.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.handleCommand(.play) }
            return .success
        }
        cc.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.handleCommand(.pause) }
            return .success
        }
        cc.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.next() }
            return .success
        }
        cc.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previous() }
            return .success
        }
    }

    private func updateNowPlayingInfo(track: TrackRow) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.track.title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]
        if let artist = track.album?.artist ?? track.artist?.name {
            info[MPMediaItemPropertyArtist] = artist
        }
        if let albumTitle = track.album?.title {
            info[MPMediaItemPropertyAlbumTitle] = albumTitle
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func updateNowPlayingTime() {
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func clearNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
}
