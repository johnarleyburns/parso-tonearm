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
    @Published private(set) var playbackPhase: WatchPlaybackPhase = .idle
    @Published private(set) var itemReadiness: WatchItemReadiness = .noItem
    @Published private(set) var sessionStatus = "unknown"
    @Published private(set) var lastPlaybackErrorCode: String?
    @Published private(set) var playbackErrorMessage: String?
    @Published private(set) var playbackGenerationForDiagnostics: Int64 = 0
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
    private var pendingSeek: Double?
    private var playbackGeneration: Int64 = 0
    private var playbackTask: Task<Void, Never>?

    var queueTracks: [WatchTrackSnapshot] { queue }

    private init() {
        output.onItemEnded = { [weak self] in
            Task { @MainActor in self?.handleCommand(.itemEnded) }
        }
        output.onItemFailed = { [weak self] code in
            Task { @MainActor in
                guard let self else { return }
                self.handleFailedItem(code: code)
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
            Task { @MainActor in
                guard let self else { return }
                self.outputRate = rate
                if self.playbackPhase == .playing {
                    self.isPlaying = rate > 0
                    self.updateNowPlayingTime()
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
        guard !tracks.isEmpty else {
            failWithoutTrack(code: "emptyQueue", message: "There is nothing to play.")
            return
        }
        let safeIndex = min(max(0, startAt), tracks.count - 1)
        startLocalPlayback(tracks: tracks, selectedTrackID: tracks[safeIndex].id)
    }

    /// One entry point for every local start. The selected stable ID survives list refreshes and the
    /// actual queue replacement happens before the serialized platform transaction begins.
    func startLocalPlayback(tracks: [WatchTrackSnapshot], selectedTrackID: String,
                            seekTo: Double? = nil) {
        let playable = tracks.filter { localFileURL(for: $0) != nil }
        guard !playable.isEmpty else {
            failWithoutTrack(code: "localFileMissing", message: "This download is not available on the watch.")
            return
        }
        let start = playable.firstIndex(where: { $0.id == selectedTrackID }) ?? 0
        queue = playable
        engine.setQueue(playable.map(\.id), startIndex: start)
        currentTrack = playable[start]
        pendingSeek = seekTo.map { max(0, $0) }
        pendingRoutePlayback = false
        audioRouteProblem = nil
        lastPlaybackErrorCode = nil
        playbackErrorMessage = nil
        playbackPhase = .activating
        itemReadiness = .noItem
        sessionStatus = "pending"
        isPlaying = false
        elapsed = 0
        duration = 0
        outputRate = 0
        WatchPlaybackCoordinator.shared.setTarget(.thisWatch)
        navigateToNowPlaying()
        scheduleCurrentTrackPlayback()
    }

    func navigateToNowPlaying() { isShowingNowPlaying = true }
    func dismissNowPlaying() { isShowingNowPlaying = false }

    func togglePlayPause() {
        guard !queue.isEmpty else { return }
        // The engine's request bit can briefly diverge from the platform-confirmed state while
        // AVPlayer KVO callbacks are being delivered. Drive the visible control from the same
        // confirmed state the view renders, so a button showing "playing" always pauses.
        if isPlaying && playbackPhase == .playing && outputRate > 0 {
            handleCommand(.pause)
        } else {
            handleCommand(.play)
        }
    }

    func next() { handleCommand(.next) }
    func previous() { handleCommand(.previous) }
    func seek(to seconds: Double) { handleCommand(.seek(to: seconds)) }

    /// "Choose Output" — re-request the audio route, then resume if the engine wants to be playing.
    /// On watchOS activating a long-form session with no route makes the system present its picker.
    func retryAudioRoute() {
        guard currentTrack != nil else { return }
        pendingRoutePlayback = true
        audioRouteProblem = nil
        scheduleCurrentTrackPlayback()
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
        switch cmd {
        case .pause:
            playbackGeneration &+= 1
            playbackTask?.cancel()
            playbackTask = nil
            engine.command(.pause)
            engine.setConfirmedPlaying(false)
            isPlaying = false
            playbackPhase = .paused
            outputRate = 0
            stopPositionTimer()
            scheduleOutputPause()
            savePosition()
            updateNowPlayingTime()

        case .seek(let position):
            let target = max(0, position)
            elapsed = target
            pendingSeek = target
            if playbackPhase == .activating || playbackPhase == .loading || playbackPhase == .ready || playbackPhase == .waitingForRoute {
                // A seek made while a new item is loading belongs to that item. Restart the
                // transaction so the seek is applied after readiness instead of touching whatever
                // item happened to be current when the button was pressed.
                scheduleCurrentTrackPlayback()
            } else {
                playbackGeneration &+= 1
                playbackGenerationForDiagnostics = playbackGeneration
                let generation = playbackGeneration
                playbackTask?.cancel()
                playbackTask = Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard self.playbackGeneration == generation else { return }
                    await self.output.seek(to: target)
                    guard self.playbackGeneration == generation else { return }
                    self.pendingSeek = nil
                    self.updateNowPlayingTime()
                }
            }

        case .routeLost:
            playbackGeneration &+= 1
            playbackTask?.cancel()
            playbackTask = nil
            engine.command(.routeLost)
            engine.setConfirmedPlaying(false)
            isPlaying = false
            playbackPhase = .waitingForRoute
            outputRate = 0
            stopPositionTimer()
            audioRouteProblem = "Connect headphones or a speaker to play audio."
            scheduleOutputPause()
            savePosition()
            updateNowPlayingTime()
            Task {
                await recordPlaybackDiagnostic("routeLost", generation: playbackGeneration)
            }

        case .play, .togglePlayPause, .next, .previous, .jump, .itemEnded, .itemFailed:
            let directives = engine.command(cmd) { [weak self] key in
                guard let self else { return nil }
                return self.queue.first(where: { $0.id == key }).flatMap { self.localFileURL(for: $0) }
            }
            guard !directives.isEmpty else {
                failWithoutTrack(code: "localFileMissing", message: "This download is not available on the watch.")
                return
            }
            elapsed = engine.elapsed
            if let key = engine.currentTrack {
                currentTrack = queue.first(where: { $0.id == key })
            }
            if directives.contains(.stop) {
                playbackGeneration &+= 1
                playbackTask?.cancel()
                playbackTask = nil
                engine.setConfirmedPlaying(false)
                isPlaying = false
                playbackPhase = .idle
                outputRate = 0
                scheduleOutputPause()
                stopPositionTimer()
                clearNowPlaying()
            } else {
                pendingRoutePlayback = false
                playbackPhase = .activating
                itemReadiness = .noItem
                sessionStatus = "pending"
                isPlaying = false
                outputRate = 0
                scheduleCurrentTrackPlayback()
            }
        }
    }

    private func scheduleCurrentTrackPlayback() {
        guard let track = currentTrack, let url = localFileURL(for: track) else {
            failWithoutTrack(code: "localFileMissing", message: "This download is not available on the watch.")
            return
        }
        playbackGeneration &+= 1
        playbackGenerationForDiagnostics = playbackGeneration
        let generation = playbackGeneration
        playbackTask?.cancel()
        playbackTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runPlaybackTransaction(track: track, url: url, generation: generation)
        }
    }

    private func runPlaybackTransaction(track: WatchTrackSnapshot, url: URL, generation: Int64) async {
        guard generation == playbackGeneration else { return }
        // Stop the previous item before beginning a new activation/load transaction. This closes the
        // old audio window during rapid next/previous taps and prevents an obsolete player from
        // continuing while the new item is still only "requested".
        await output.pause()
        guard generation == playbackGeneration else { return }
        playbackPhase = .activating
        let activation = await output.activateSession()
        guard generation == playbackGeneration else { return }
        sessionStatus = activation.isActive ? "active" : (activation.code ?? "failed")
        guard activation.isActive else {
            pendingRoutePlayback = true
            audioRouteProblem = "Connect headphones or a speaker to play audio."
            playbackPhase = .waitingForRoute
            isPlaying = false
            outputRate = 0
            lastPlaybackErrorCode = activation.code
            await recordPlaybackDiagnostic("activationFailed", generation: generation,
                                           count: activation.route.outputCount)
            return
        }
        await recordPlaybackDiagnostic("activationSucceeded", generation: generation,
                                       count: activation.route.outputCount)
        audioRouteProblem = nil
        playbackErrorMessage = nil
        playbackPhase = .loading
        let loaded = await output.load(url: url)
        guard generation == playbackGeneration else { return }
        itemReadiness = output.currentItemReadiness()
        switch loaded {
        case .cancelled:
            return
        case .failed(let code):
            handleFailedItem(code: code, generation: generation)
            return
        case .ready(let loadedDuration):
            duration = loadedDuration
            itemReadiness = .ready
            playbackPhase = .ready
            lastPlaybackErrorCode = nil
            await recordPlaybackDiagnostic("itemReady", generation: generation,
                                           durationMillis: Int(max(0, loadedDuration) * 1000))
        }
        loadResolvedArtwork(for: track)
        if let seek = pendingSeek {
            pendingSeek = nil
            await output.seek(to: seek)
            guard generation == playbackGeneration else { return }
            elapsed = seek
        }
        let result = await output.play()
        guard generation == playbackGeneration else { return }
        switch result {
        case .cancelled:
            return
        case .failed(let code):
            failCurrentPlayback(code: code, generation: generation)
        case .playing(let rate):
            outputRate = rate
            isPlaying = true
            engine.setConfirmedPlaying(true)
            playbackPhase = .playing
            audioRouteProblem = nil
            lastPlaybackErrorCode = nil
            startPositionTimer()
            updateNowPlayingInfo(track: track)
            await recordPlaybackDiagnostic("playing", generation: generation,
                                           durationMillis: Int(max(0, duration) * 1000))
        }
    }

    private func failCurrentPlayback(code: String, generation: Int64? = nil) {
        if let generation, generation != playbackGeneration { return }
        playbackTask?.cancel()
        playbackTask = nil
        isPlaying = false
        engine.setConfirmedPlaying(false)
        outputRate = 0
        itemReadiness = output.currentItemReadiness()
        playbackPhase = .failed
        lastPlaybackErrorCode = code
        playbackErrorMessage = userMessage(for: code)
        audioRouteProblem = nil
        stopPositionTimer()
        updateNowPlayingTime()
        scheduleOutputPause()
        Task {
            await recordPlaybackDiagnostic("playbackFailed:\(code)",
                                           generation: generation ?? playbackGeneration)
        }
    }

    private func handleFailedItem(code: String, generation: Int64? = nil) {
        if let generation, generation != playbackGeneration { return }
        let directives = engine.command(.itemFailed) { [weak self] key in
            guard let self else { return nil }
            return self.queue.first(where: { $0.id == key }).flatMap { self.localFileURL(for: $0) }
        }
        Task {
            await recordPlaybackDiagnostic("itemLoadFailed:\(code)",
                                           generation: generation ?? playbackGeneration)
        }
        guard !directives.isEmpty else {
            failWithoutTrack(code: code, message: userMessage(for: code))
            return
        }
        elapsed = engine.elapsed
        if let key = engine.currentTrack {
            currentTrack = queue.first(where: { $0.id == key })
        }
        if directives.contains(.stop) {
            failCurrentPlayback(code: code, generation: generation)
        } else {
            pendingRoutePlayback = false
            playbackPhase = .activating
            itemReadiness = .noItem
            isPlaying = false
            engine.setConfirmedPlaying(false)
            outputRate = 0
            scheduleCurrentTrackPlayback()
        }
    }

    private func failWithoutTrack(code: String, message: String) {
        playbackGeneration &+= 1
        playbackTask?.cancel()
        playbackTask = nil
        isPlaying = false
        engine.setConfirmedPlaying(false)
        outputRate = 0
        playbackPhase = .failed
        lastPlaybackErrorCode = code
        playbackErrorMessage = message
        audioRouteProblem = nil
        stopPositionTimer()
        let generation = playbackGeneration
        Task {
            await recordPlaybackDiagnostic("playbackFailed:\(code)", generation: generation)
        }
    }

    private func recordPlaybackDiagnostic(_ state: String, generation: Int64,
                                          durationMillis: Int? = nil, count: Int? = nil) async {
        let trackCorrelation = currentTrack.map { "t\($0.id)" } ?? "none"
        await WatchAppAssembly.shared.diagnostics.record(.routeEvent, state,
                                                          correlationID: "g\(generation):\(trackCorrelation)",
                                                          durationMillis: durationMillis, count: count)
    }

    private func scheduleOutputPause() {
        let generation = playbackGeneration
        playbackTask?.cancel()
        playbackTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.output.pause()
            guard self.playbackGeneration == generation else { return }
        }
    }

    private func userMessage(for code: String) -> String {
        if code == "localFileMissing" { return "This download is not available on the watch." }
        if code == "itemReadinessTimeout" { return "The audio file did not become ready." }
        if code == "playbackRateZero" { return "Audio did not start on the selected output." }
        if code.hasPrefix("item-") { return "The downloaded audio file could not be played." }
        return "Audio could not start. Choose an output and try again."
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
        if case .interruptionEnded(let shouldResume) = event, shouldResume, wasPlaying {
            rebuildCurrentItemAndResume()
            return
        }
        if event == .mediaServicesReset {
            handleCommand(.pause)
            rebuildCurrentItem(resume: false)
            savePosition()
            return
        }
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
                rebuildCurrentItem(resume: false)
            case .resumeIfWasPlaying:
                if wasPlaying { handleCommand(.play) }
            }
        }
    }

    private func rebuildCurrentItemAndResume() {
        rebuildCurrentItem(resume: true)
    }

    private func rebuildCurrentItem(resume: Bool) {
        guard let track = currentTrack, localFileURL(for: track) != nil else { return }
        playbackGeneration &+= 1
        playbackGenerationForDiagnostics = playbackGeneration
        let generation = playbackGeneration
        playbackTask?.cancel()
        isPlaying = false
        engine.setConfirmedPlaying(false)
        outputRate = 0
        playbackPhase = .activating
        playbackTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.output.rebuildSession()
            guard generation == self.playbackGeneration else { return }
            switch result {
            case .cancelled:
                return
            case .failed(let code):
                self.failCurrentPlayback(code: code, generation: generation)
            case .ready(let loadedDuration):
                self.duration = loadedDuration
                self.itemReadiness = self.output.currentItemReadiness()
                self.playbackPhase = .ready
                self.loadResolvedArtwork(for: track)
                if resume {
                    switch await self.output.play() {
                    case .playing(let rate):
                        guard generation == self.playbackGeneration else { return }
                        self.outputRate = rate
                        self.isPlaying = true
                        self.engine.setConfirmedPlaying(true)
                        self.playbackPhase = .playing
                        self.updateNowPlayingInfo(track: track)
                    case .failed(let code):
                        self.failCurrentPlayback(code: code, generation: generation)
                    case .cancelled:
                        return
                    }
                } else {
                    self.updateNowPlayingInfo(track: track)
                }
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
        // The UI smoke test seeds and starts its own deterministic queue. Do not let a persisted
        // queue from a previous simulator run race that seed and cover the root surface.
        if ProcessInfo.processInfo.arguments.contains("UI_TESTING") { return }
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
        playbackPhase = .paused
        itemReadiness = .noItem
        sessionStatus = "unknown"
        outputRate = 0
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
            MPNowPlayingInfoPropertyPlaybackRate: outputRate
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
        info[MPNowPlayingInfoPropertyPlaybackRate] = outputRate
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func clearNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        artwork = nil
        resolvedArtworkTrackID = nil
    }

    private func loadResolvedArtwork(for track: WatchTrackSnapshot) {
        resolvedArtworkTrackID = nil
        artwork = nil
        guard let filename = track.artworkFilename,
              let directory = WatchAppAssembly.shared.artworkDirectory else { return }
        let url = directory.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url), let image = UIImage(data: data) else { return }
        resolvedArtworkTrackID = track.id
        artwork = image
        updateNowPlayingInfo(track: track)
    }
}
