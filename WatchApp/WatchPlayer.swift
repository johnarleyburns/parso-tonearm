import Foundation
import SwiftUI
import AVFoundation
import MediaPlayer
import TonearmWatchCore

@MainActor
final class WatchPlayer: ObservableObject {
    static let shared = WatchPlayer()

    @Published var currentTrack: WatchTrackSnapshot?
    @Published var isPlaying = false
    @Published var volume: Double = 0.5
    @Published var elapsed: Double = 0
    @Published var duration: Double = 0
    @Published var isShuffled = false
    @Published var repeatMode: WatchRepeatMode = .off
    @Published var navigationPath = NavigationPath()
    /// Drives presentation of Now Playing. A boolean-bound sheet is used instead of a programmatic
    /// `NavigationPath` push because external mutations to a `NavigationPath` binding do not reliably
    /// drive the stack on watchOS — the symptom being "tap Play → nothing happens".
    @Published var isShowingNowPlaying = false

    private var engine = WatchPlayerEngine()
    private var output = AVPlayerOutput()
    private var queue: [WatchTrackSnapshot] = []
    private var positionTimer: Timer?

    var queueTracks: [WatchTrackSnapshot] { queue }

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

    func play(tracks: [WatchTrackSnapshot], startAt: Int) {
        // Offline truth: only tracks whose audio actually resolves are playable.
        let playable = tracks.filter { localFileURL(for: $0) != nil }
        guard !playable.isEmpty else { return }
        let anchor = startAt < tracks.count ? tracks[startAt] : tracks[0]
        let start = playable.firstIndex(where: { $0.id == anchor.id }) ?? 0
        queue = playable
        engine.setQueue(playable.map(\.id), startIndex: start)
        currentTrack = playable[start]
        navigateToNowPlaying()
        handleCommand(.play)
    }

    func navigateToNowPlaying() { isShowingNowPlaying = true }
    func dismissNowPlaying() { isShowingNowPlaying = false }

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
            return self.queue.first(where: { $0.id == key }).flatMap { self.localFileURL(for: $0) }
        }

        isPlaying = engine.isPlaying
        elapsed = engine.elapsed
        if let key = engine.currentTrack {
            currentTrack = queue.first(where: { $0.id == key })
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

    /// A file already downloaded to the watch for this track, resolved against the SwiftData store's
    /// audio directory. There is no streaming path on the watch after the Phase 6 cutover — offline
    /// truth is the only truth.
    private func localFileURL(for snapshot: WatchTrackSnapshot) -> URL? {
        guard let filename = snapshot.localFilename,
              let directory = WatchAppAssembly.shared.audioDirectory else { return nil }
        let url = directory.appendingPathComponent(filename)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - Queue rebind

    private func rebindQueueFromEngine() {
        let engineKeys = engine.queue
        var newQueue: [WatchTrackSnapshot] = []
        for key in engineKeys {
            if let row = queue.first(where: { $0.id == key }) {
                newQueue.append(row)
            }
        }
        queue = newQueue
        if let key = engine.currentTrack {
            currentTrack = queue.first(where: { $0.id == key })
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
        guard let snap = WatchPositionStore.loadOrClear(), !snap.trackKeys.isEmpty,
              let repository = WatchAppAssembly.shared.repository else { return }
        let rows = (try? await repository.tracks(readyOnly: true)) ?? []
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        var valid: [WatchTrackSnapshot] = []
        var validIndex = 0
        for (i, key) in snap.trackKeys.enumerated() {
            guard let row = byID[key], localFileURL(for: row) != nil else { continue }
            valid.append(row)
            if i == snap.currentIndex { validIndex = valid.count - 1 }
        }
        guard !valid.isEmpty else { return }
        queue = valid
        currentTrack = valid.count > validIndex ? valid[validIndex] : valid[0]
        elapsed = snap.elapsed
        engine = WatchPlayerEngine(queue: valid.map(\.id),
                                   startIndex: valid.count > validIndex ? validIndex : 0)
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

    private func updateNowPlayingInfo(track: WatchTrackSnapshot) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]
        if !track.artist.isEmpty { info[MPMediaItemPropertyArtist] = track.artist }
        if !track.albumTitle.isEmpty { info[MPMediaItemPropertyAlbumTitle] = track.albumTitle }
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
