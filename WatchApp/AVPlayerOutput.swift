import AVFoundation
import TonearmWatchCore

@MainActor
final class AVPlayerOutput: WatchAudioOutput {
    private let player = AVPlayer()
    private var timeObserver: Any?
    private var itemEndObserver: NSObjectProtocol?
    private var itemFailedObserver: NSObjectProtocol?
    private var currentURL: URL?
    private var currentVolume: Float = 0.5

    var onItemEnded: (() -> Void)?
    var onItemFailed: (() -> Void)?
    var onTimeUpdate: ((Double) -> Void)?

    private(set) var currentDuration: Double = 0

    func load(url: URL) async {
        removeObservers()
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, policy: .longFormAudio)
        #if os(watchOS)
        _ = try? await session.activate()
        #else
        try? session.setActive(true)
        #endif

        currentURL = url
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        player.volume = currentVolume

        itemEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.onItemEnded?() }
        }

        itemFailedObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.onItemFailed?() }
        }

        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor in self?.onTimeUpdate?(time.seconds) }
        }

        if let dur = try? await item.asset.load(.duration), dur.seconds.isFinite {
            currentDuration = dur.seconds
        } else {
            currentDuration = 0
        }
    }

    func play() async {
        let session = AVAudioSession.sharedInstance()
        if session.category != .playback {
            try? session.setCategory(.playback, mode: .default, policy: .longFormAudio)
        }
        #if os(watchOS)
        _ = try? await session.activate()
        #else
        try? session.setActive(true)
        #endif
        player.play()
    }

    func pause() async {
        player.pause()
    }

    func seek(to time: Double) async {
        let cm = CMTime(seconds: time, preferredTimescale: 600)
        await player.seek(to: cm)
    }

    func setVolume(_ volume: Double) {
        let clamped = Float(min(1, max(0, volume)))
        currentVolume = clamped
        player.volume = clamped
    }

    /// Rebuild the audio session and reload the current item, keeping the player paused. Callers
    /// resume explicitly if the policy says to.
    func rebuildSession() async {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, policy: .longFormAudio)
        #if os(watchOS)
        _ = try? await session.activate()
        #else
        try? session.setActive(true)
        #endif
        guard let url = currentURL else { return }
        let resumeAt = player.currentTime()
        await load(url: url)
        await player.seek(to: resumeAt)
    }

    func removeObservers() {
        if let obs = timeObserver {
            player.removeTimeObserver(obs)
            timeObserver = nil
        }
        if let obs = itemEndObserver {
            NotificationCenter.default.removeObserver(obs)
            itemEndObserver = nil
        }
        if let obs = itemFailedObserver {
            NotificationCenter.default.removeObserver(obs)
            itemFailedObserver = nil
        }
    }
}
