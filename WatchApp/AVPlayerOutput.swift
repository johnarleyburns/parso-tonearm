import AVFoundation
import UIKit
import TonearmWatchCore

@MainActor
final class AVPlayerOutput: WatchAudioOutput {
    private let player = AVPlayer()
    private var timeObserver: Any?
    private var itemEndObserver: NSObjectProtocol?
    private var itemFailedObserver: NSObjectProtocol?
    private var statusObserver: NSKeyValueObservation?
    private var rateObserver: NSKeyValueObservation?
    private var currentURL: URL?
    private var currentVolume: Float = 0.5
    private var artworkToken = 0
    private var itemFailureReported = false

    var onItemEnded: (() -> Void)?
    var onItemFailed: (() -> Void)?
    var onTimeUpdate: ((Double) -> Void)?
    /// Fires with the AVPlayer's transport rate whenever it changes — a direct read of whether audio
    /// is actually running, distinct from the pure engine's `isPlaying`.
    var onRateChange: ((Double) -> Void)?
    /// Fires with a short, user-facing reason when the audio session cannot be activated (on the
    /// watch this is almost always "no audio route selected").
    var onSessionProblem: ((String?) -> Void)?
    /// Embedded cover art for the current item, or `nil` when the file carries none.
    var onArtwork: ((UIImage?) -> Void)?

    private(set) var currentDuration: Double = 0

    init() {
        rateObserver = player.observe(\.rate, options: [.new]) { [weak self] player, _ in
            let rate = Double(player.rate)
            Task { @MainActor in self?.onRateChange?(rate) }
        }
    }

    func load(url: URL) async {
        removeItemObservers()
        await activateSession()

        currentURL = url
        artworkToken &+= 1
        let token = artworkToken
        let item = AVPlayerItem(url: url)
        itemFailureReported = false
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
            guard let self, !self.itemFailureReported else { return }
            self.itemFailureReported = true
            Task { @MainActor in self.onItemFailed?() }
        }

        statusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            let error = item.error as NSError?
            let reason = item.error?.localizedDescription ?? "unknown"
            NSLog("AVPlayerOutput: item failed to load — \(reason); underlying=\(String(describing: error?.userInfo[NSUnderlyingErrorKey]))")
            guard let self, !self.itemFailureReported else { return }
            self.itemFailureReported = true
            Task { @MainActor in self.onItemFailed?() }
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

        await loadArtwork(from: item.asset, token: token)
    }

    func play() async {
        await activateSession()
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
        await activateSession()
        guard let url = currentURL else { return }
        let resumeAt = player.currentTime()
        await load(url: url)
        await player.seek(to: resumeAt)
    }

    /// Explicitly re-request the audio route — wired to the "Choose Output" affordance. On watchOS
    /// activating a long-form session with no route makes the system present its output picker.
    func requestRoute() async {
        await activateSession()
    }

    func removeObservers() {
        removeItemObservers()
        rateObserver?.invalidate()
        rateObserver = nil
    }

    // MARK: - Private

    private func activateSession() async {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, policy: .longFormAudio)
            #if os(watchOS)
            try await session.activate()
            #else
            try session.setActive(true)
            #endif
            onSessionProblem?(nil)
        } catch {
            NSLog("WatchAudio: audio session activation failed: \(error.localizedDescription)")
            onSessionProblem?(sessionProblemReason(error))
        }
    }

    private func sessionProblemReason(_ error: Error) -> String {
        #if os(watchOS)
        let code = (error as NSError).code
        // AVAudioSession.ErrorCode.cannotStartPlaying / .cannotInterruptOthers surface here when
        // there is no eligible Bluetooth route.
        if code == AVAudioSession.ErrorCode.cannotStartPlaying.rawValue
            || code == AVAudioSession.ErrorCode.cannotInterruptOthers.rawValue {
            return "Connect Bluetooth headphones or a speaker to play audio."
        }
        #endif
        return "Can't start audio — check your audio output."
    }

    private func loadArtwork(from asset: AVAsset, token: Int) async {
        let metadata = (try? await asset.load(.commonMetadata)) ?? []
        guard token == artworkToken else { return }
        for item in metadata where item.commonKey == .commonKeyArtwork {
            if let data = try? await item.load(.dataValue), let image = UIImage(data: data) {
                if token == artworkToken { onArtwork?(image) }
                return
            }
        }
        if token == artworkToken { onArtwork?(nil) }
    }

    private func removeItemObservers() {
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
        statusObserver?.invalidate()
        statusObserver = nil
    }
}
