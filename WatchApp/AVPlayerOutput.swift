import AVFoundation
import TonearmCore

@MainActor
final class AVPlayerOutput: WatchAudioOutput {
    private let player = AVPlayer()
    private var timeObserver: Any?
    private var itemEndObserver: NSObjectProtocol?
    private var itemFailedObserver: NSObjectProtocol?

    var onItemEnded: (() -> Void)?
    var onItemFailed: (() -> Void)?
    var onTimeUpdate: ((Double) -> Void)?

    private(set) var currentDuration: Double = 0

    func load(url: URL) async {
        removeObservers()
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, policy: .longFormAudio)
        try? await session.activate()

        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)

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
            self?.onTimeUpdate?(time.seconds)
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
        try? await session.activate()
        player.play()
    }

    func pause() async {
        player.pause()
    }

    func seek(to time: Double) async {
        let cm = CMTime(seconds: time, preferredTimescale: 600)
        await player.seek(to: cm)
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
