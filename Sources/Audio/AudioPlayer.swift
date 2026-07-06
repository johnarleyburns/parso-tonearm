import Foundation
import AVFoundation
import MediaPlayer
import Combine
import UIKit

enum RepeatMode: String, CaseIterable {
    case off, all, one
}

@MainActor
final class AudioPlayer: ObservableObject {
    static let shared = AudioPlayer()

    @Published private(set) var queue: [TrackRow] = []
    @Published private(set) var index: Int = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published var shuffle = false
    @Published var repeatMode: RepeatMode = .off
    @Published private(set) var cacheState: CacheGlyphState = .none
    @Published private(set) var cachePercent: Int = 0
    @Published private(set) var cachedFraction: Double = 0

    var streamOnCellular = true
    var prefetchDepth = 2
    var preferFLAC = false

    private var player = AVPlayer()
    private var timeObserver: Any?
    private var itemEndObserver: NSObjectProtocol?
    private var loaders: [CachingResourceLoader] = []
    private let loaderQueue = DispatchQueue(label: "guru.parso.tonearm.loaders")

    var currentTrack: TrackRow? {
        guard queue.indices.contains(index) else { return nil }
        return queue[index]
    }

    private init() {
        configureSession()
        setupRemoteCommands()
        addPeriodicObserver()
    }

    // MARK: - Public control

    func play(tracks: [TrackRow], startAt start: Int) {
        queue = tracks
        index = max(0, min(start, tracks.count - 1))
        loadCurrent(autoplay: true)
    }

    func playSingle(_ track: TrackRow) {
        play(tracks: [track], startAt: 0)
    }

    func togglePlayPause() {
        if isPlaying { player.pause() } else { player.play() }
        isPlaying.toggle()
        updateNowPlaying()
    }

    func next() {
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
        guard !queue.isEmpty else { return }
        if currentTime > 3 { seek(to: 0); return }
        index = max(0, index - 1)
        loadCurrent(autoplay: true)
    }

    func seek(to seconds: Double) {
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

        let item: AVPlayerItem
        if asset.kind == .remote, let urlString = remoteURLString(for: asset), let remote = URL(string: urlString) {
            let cacheURL = CachingResourceLoader.cacheURL(for: remote)
            let avAsset = AVURLAsset(url: cacheURL)
            let loader = CachingResourceLoader(originalURL: remote)
            loaders.append(loader)
            avAsset.resourceLoader.setDelegate(loader, queue: loaderQueue)
            item = AVPlayerItem(asset: avAsset)
        } else if let bookmark = asset.bookmark, let (url, _) = BookmarkVault.resolve(bookmark) {
            _ = url.startAccessingSecurityScopedResource()
            item = AVPlayerItem(url: url)
        } else if let rel = asset.relPath {
            let url = managedURL(rel)
            item = AVPlayerItem(url: url)
        } else {
            next()
            return
        }

        replaceItem(item)
        if autoplay {
            player.play()
            isPlaying = true
        }
        duration = row.track.durationSec ?? 0
        updateNowPlaying()
        prefetchNext()
        if let trackId = row.track.id {
            Task { try? await LibraryStore.shared.recordPlay(trackId: trackId) }
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
            Task { @MainActor in self?.next() }
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
        let upcoming = queue.dropFirst(index + 1).prefix(prefetchDepth)
        for row in upcoming {
            guard let asset = row.asset, asset.kind == .remote,
                  let urlString = asset.remoteURL, let remote = URL(string: urlString) else { continue }
            Task.detached(priority: .background) {
                let loader = CachingResourceLoader(originalURL: remote)
                _ = loader
            }
        }
    }

    // MARK: - Observers

    private func addPeriodicObserver() {
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            Task { @MainActor in
                self.currentTime = time.seconds
                if let d = self.player.currentItem?.duration.seconds, d.isFinite, d > 0 {
                    self.duration = d
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
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]
        info[MPMediaItemPropertyAlbumTitle] = row.album?.title
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func updateNowPlayingTime() {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
