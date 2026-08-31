import Foundation
import SwiftUI
import UIKit
import AVFoundation
import MediaPlayer
import TonearmWatchCore

@MainActor
final class WatchPlayer: ObservableObject {
    static let shared = WatchPlayer()

    @Published var currentTrack: WatchTrackSnapshot?
    @Published var isPlaying = false
    @Published var volume: Double = 0.5 {
        didSet { output.setVolume(volume) }
    }
    /// Non-nil when the audio route went away; drives the "Choose headphones or a speaker" hint.
    @Published var routeHint: String?
    /// Non-nil when the audio session could not be activated — the watch has no usable output route.
    /// Distinct from `routeHint` (a transient policy nudge): this is a hard "no audio is playing"
    /// state with a "Choose Output" affordance.
    @Published var audioRouteProblem: String?
    /// Embedded cover art for the current local track, or `nil` — the view falls back to a glyph.
    @Published var artwork: UIImage?
    /// The AVPlayer's actual transport rate. 0 while paused/stalled, ~1 while audio is running.
    /// Surfaced so a test (and a curious user) can tell real playback from a relabelled button.
    @Published private(set) var outputRate: Double = 0
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
    private var resolvedArtworkTrackID: String?
    private var pendingRoutePlayback = false

    var queueTracks: [WatchTrackSnapshot] { queue }

    private init() {
        output.onItemEnded = { [weak self] in
            Task { @MainActor in self?.handleCommand(.itemEnded) }
        }
        output.onItemFailed = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                await WatchAppAssembly.shared.diagnostics.record(.routeEvent, "itemLoadFailed")
                self.handleCommand(.itemFailed)
            }
        }
        output.onTimeUpdate = { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                self.elapsed = time
                self.updateNowPlayingTime()
            }
        }
        output.onRateChange = { [weak self] rate in
            Task { @MainActor in self?.outputRate = rate }
        }
        output.onSessionProblem = { [weak self] reason in
            Task { @MainActor in
                self?.audioRouteProblem = reason
                if let reason {
                    NSLog("WatchPlayer: audio route problem — \(reason)")
                    await WatchAppAssembly.shared.diagnostics.record(.routeEvent, "sessionUnavailable")
                }
            }
        }
        output.onArtwork = { [weak self] image in
            Task { @MainActor in
                guard self?.resolvedArtworkTrackID == nil else { return }
                self?.artwork = image
                if let track = self?.currentTrack { self?.updateNowPlayingInfo(track: track) }
            }
        }
        setupRemoteCommands()
        observeAudioSession()
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
        // Starting local playback is the user explicitly choosing the this-watch target (§7.1 —
        // the choice rides the play action; it is not an automatic switch).
        WatchPlaybackCoordinator.shared.setTarget(.thisWatch)
        navigateToNowPlaying()
        guard output.hasUsableRoute() else {
            pendingRoutePlayback = true
            audioRouteProblem = "Connect headphones or a speaker to play audio."
            return
        }
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
    func seek(to seconds: Double) { handleCommand(.seek(to: seconds)) }

    /// "Choose Output" — re-request the audio route, then resume if the engine wants to be playing.
    /// On watchOS activating a long-form session with no route makes the system present its picker.
    func retryAudioRoute() {
        Task { @MainActor in
            await output.requestRoute()
            guard audioRouteProblem == nil else { return }
            if pendingRoutePlayback {
                pendingRoutePlayback = false
                handleCommand(.play)
            } else if engine.isPlaying {
                await output.play()
            }
        }
    }

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
        if case .play = cmd, !output.hasUsableRoute() {
            pendingRoutePlayback = true
            audioRouteProblem = "Connect headphones or a speaker to play audio."
            return
        }
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

        // Directives must be applied in order — `.loadItem` has to finish before `.play`. One Task
        // per directive would race them.
        let hadStop = directives.contains(.stop)
        Task { @MainActor in
            await applyWatchDirectives(directives, to: output)
            self.duration = self.output.currentDuration
            if hadStop { self.clearNowPlaying() }
            else if let track = self.currentTrack {
                self.loadResolvedArtwork(for: track)
                self.updateNowPlayingInfo(track: track)
            }
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

    // MARK: - Audio session lifecycle

    private func observeAudioSession() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            let optionsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: optionsRaw).contains(.shouldResume)
            let event: WatchAudioEvent
            switch type {
            case .began: event = .interruptionBegan
            case .ended: event = .interruptionEnded(shouldResume: shouldResume)
            @unknown default: return
            }
            Task { @MainActor in WatchPlayer.shared.handleAudioEvent(event) }
        }
        nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { note in
            guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
            let lost = reason == .oldDeviceUnavailable || reason == .noSuitableRouteForCategory
            let available = reason == .newDeviceAvailable || reason == .routeConfigurationChange
            guard lost || available else { return }
            Task { @MainActor in
                WatchPlayer.shared.handleAudioEvent(lost ? .routeLost : .routeAvailable)
            }
        }
        nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in WatchPlayer.shared.handleAudioEvent(.mediaServicesReset) }
        }
    }

    func handleAudioEvent(_ event: WatchAudioEvent) {
        let wasPlaying = isPlaying
        for action in WatchAudioSessionPolicy.actions(for: event, wasPlaying: wasPlaying) {
            switch action {
            case .pause:
                if isPlaying { handleCommand(.pause) }
            case .persist:
                savePosition()
            case .showRouteHint:
                routeHint = "Choose headphones or a speaker"
            case .clearRouteHint:
                routeHint = nil
            case .rebuildSession:
                Task { @MainActor in await output.rebuildSession() }
            case .resumeIfWasPlaying:
                if wasPlaying { handleCommand(.play) }
            }
        }
    }

    /// Checkpoint the queue immediately — called on scene inactive/background (§7.3).
    func persistNow() { savePosition() }

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

        // The engine decides which tracks survive and where the index lands (§7.3, missing-file
        // restoration); the view layer just projects its queue.
        let availableKeys = Set(byID.compactMap { id, row in localFileURL(for: row) != nil ? id : nil })
        let restored = WatchPlayerEngine.restored(from: snap, availableKeys: availableKeys)
        guard !restored.queue.isEmpty else { return }

        engine = restored
        queue = restored.queue.compactMap { byID[$0] }
        currentTrack = restored.currentTrack.flatMap { byID[$0] }
        elapsed = restored.elapsed
        isShuffled = restored.isShuffled
        repeatMode = restored.repeatMode
        isPlaying = false
        // The production launch surface is Now Playing when a persisted queue is present. UI smoke
        // runs intentionally start on the root list so they can exercise every entry point.
        if currentTrack != nil && !ProcessInfo.processInfo.arguments.contains("UI_TESTING") {
            navigateToNowPlaying()
        }
    }

    func clearPosition() { WatchPositionStore.clear() }

    // MARK: - Now Playing

    private func setupRemoteCommands() {
        let cc = MPRemoteCommandCenter.shared()

        // Register only the commands the watch actually supports (§7.4).
        cc.playCommand.isEnabled = true
        cc.pauseCommand.isEnabled = true
        cc.togglePlayPauseCommand.isEnabled = true
        cc.nextTrackCommand.isEnabled = true
        cc.previousTrackCommand.isEnabled = true

        // Everything else is explicitly disabled so the system Now Playing UI does not offer a
        // control the watch cannot honour.
        for unsupported: MPRemoteCommand in [
            cc.changePlaybackPositionCommand, cc.seekForwardCommand, cc.seekBackwardCommand,
            cc.skipForwardCommand, cc.skipBackwardCommand, cc.changePlaybackRateCommand,
            cc.changeRepeatModeCommand, cc.changeShuffleModeCommand, cc.ratingCommand,
            cc.likeCommand, cc.dislikeCommand, cc.bookmarkCommand
        ] {
            unsupported.isEnabled = false
        }

        cc.playCommand.addTarget { _ in
            Task { @MainActor in WatchPlayer.shared.handleCommand(.play) }
            return .success
        }
        cc.pauseCommand.addTarget { _ in
            Task { @MainActor in WatchPlayer.shared.handleCommand(.pause) }
            return .success
        }
        cc.togglePlayPauseCommand.addTarget { _ in
            Task { @MainActor in WatchPlayer.shared.togglePlayPause() }
            return .success
        }
        cc.nextTrackCommand.addTarget { _ in
            Task { @MainActor in WatchPlayer.shared.next() }
            return .success
        }
        cc.previousTrackCommand.addTarget { _ in
            Task { @MainActor in WatchPlayer.shared.previous() }
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
        if let artwork {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: artwork.size) { _ in artwork }
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
        artwork = nil
        resolvedArtworkTrackID = nil
    }

    private func loadResolvedArtwork(for track: WatchTrackSnapshot) {
        resolvedArtworkTrackID = nil
        guard let filename = track.artworkFilename,
              let directory = WatchAppAssembly.shared.artworkDirectory else { return }
        let url = directory.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url), let image = UIImage(data: data) else { return }
        resolvedArtworkTrackID = track.id
        artwork = image
    }
}
