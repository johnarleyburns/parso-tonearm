import AVFoundation
import UIKit
import TonearmWatchCore

@MainActor
final class AVPlayerOutput: WatchAudioOutput {
    private static let itemReadinessTimeout: Duration = .seconds(15)
    private static let playConfirmationTimeout: Duration = .seconds(3)
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
    private var sessionIsActive = false

    var onItemEnded: (() -> Void)?
    var onItemFailed: ((String) -> Void)?
    var onTimeUpdate: ((Double) -> Void)?
    /// Fires with the AVPlayer's transport rate whenever it changes — a direct read of whether audio
    /// is actually running, distinct from the pure engine's `isPlaying`.
    var onRateChange: ((Double) -> Void)?
    /// Embedded cover art for the current item, or `nil` when the file carries none.
    var onArtwork: ((UIImage?) -> Void)?

    private(set) var currentDuration: Double = 0

    init() {
        rateObserver = player.observe(\.rate, options: [.new]) { [weak self] player, _ in
            let rate = Double(player.rate)
            Task { @MainActor in self?.onRateChange?(rate) }
        }
    }

    func activateSession() async -> WatchAudioActivationResult {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, policy: .longFormAudio)
            #if os(watchOS)
            let activated = try await session.activate()
            #else
            try session.setActive(true)
            let activated = true
            #endif
            let route = currentRoute()
            #if os(watchOS)
            guard activated, route.outputCount > 0 else {
                let code = activated ? "routeUnavailable" : "activationRejected"
                sessionIsActive = false
                return .unavailable(code: code, route: route)
            }
            #endif
            sessionIsActive = true
            return .active(route: route)
        } catch {
            let code = Self.activationErrorCode(error)
            NSLog("WatchAudio: audio session activation failed: \(error.localizedDescription)")
            sessionIsActive = false
            return .failed(code: code, route: currentRoute())
        }
    }

    func load(url: URL) async -> WatchItemLoadResult {
        removeItemObservers()
        player.pause()
        currentDuration = 0

        currentURL = url
        artworkToken &+= 1
        let token = artworkToken
        let item = AVPlayerItem(url: url)
        itemFailureReported = false
        player.replaceCurrentItem(with: item)
        player.volume = currentVolume
        // AVPlayerItem can remain .unknown until its owning player is asked to prepare the item.
        // Preroll is only legal after AVPlayer itself is ready; on watchOS the call throws an
        // Objective-C exception otherwise. A play request is the safe fallback that drives item
        // preparation, while play() below still requires a later non-zero rate before the app
        // reports "playing".
        if player.status == .readyToPlay {
            player.preroll(atRate: 0) { _ in }
        } else {
            player.play()
        }

        itemEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.player.currentItem === item else { return }
                self.onItemEnded?()
            }
        }

        itemFailedObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self,
                      self.player.currentItem === item,
                      !self.itemFailureReported else { return }
                self.itemFailureReported = true
                self.onItemFailed?(Self.itemErrorCode(item.error))
            }
        }

        statusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            Task { @MainActor [weak self] in
                let error = item.error as NSError?
                let reason = item.error?.localizedDescription ?? "unknown"
                NSLog("AVPlayerOutput: item failed to load — \(reason); underlying=\(String(describing: error?.userInfo[NSUnderlyingErrorKey]))")
                guard let self,
                      self.player.currentItem === item,
                      !self.itemFailureReported else { return }
                self.itemFailureReported = true
                self.onItemFailed?(Self.itemErrorCode(item.error))
            }
        }

        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor in self?.onTimeUpdate?(time.seconds) }
        }

        let deadline = ContinuousClock.now + Self.itemReadinessTimeout
        while ContinuousClock.now < deadline {
            if Task.isCancelled { return .cancelled }
            switch item.status {
            case .readyToPlay:
                if let dur = try? await item.asset.load(.duration), dur.seconds.isFinite {
                    currentDuration = max(0, dur.seconds)
                }
                // Embedded artwork is optional presentation metadata. Do not delay the critical
                // item-ready result on a metadata provider that may be slow or incomplete on
                // watchOS; the token prevents a late callback from decorating a newer item.
                Task { @MainActor [weak self, asset = item.asset, token] in
                    await self?.loadArtwork(from: asset, token: token)
                }
                return .ready(durationSeconds: currentDuration)
            case .failed:
                let code = Self.itemErrorCode(item.error)
                return .failed(code: code)
            case .unknown:
                try? await Task.sleep(for: .milliseconds(50))
            @unknown default:
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        return .failed(code: "itemReadinessTimeout")
    }

    func play() async -> WatchPlayResult {
        if !sessionIsActive {
            let activation = await activateSession()
            guard activation.isActive else {
                return .failed(code: activation.code ?? "activationFailed")
            }
        }
        guard player.currentItem?.status == .readyToPlay else {
            return .failed(code: "itemNotReady")
        }
        player.play()
        let deadline = ContinuousClock.now + Self.playConfirmationTimeout
        while ContinuousClock.now < deadline {
            if Task.isCancelled { return .cancelled }
            if player.rate > 0 { return .playing(rate: Double(player.rate)) }
            if player.currentItem?.status == .failed {
                return .failed(code: Self.itemErrorCode(player.currentItem?.error))
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return .failed(code: "playbackRateZero")
    }

    func pause() async {
        player.pause()
        // Make the stop observable immediately even when AVPlayer is still draining a prior
        // command on the simulator.
        player.rate = 0
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
    func rebuildSession() async -> WatchSessionRebuildResult {
        guard let url = currentURL else { return .failed(code: "noCurrentItem") }
        let resumeAt = player.currentTime()
        let activation = await activateSession()
        guard activation.isActive else {
            return .failed(code: activation.code ?? "activationFailed")
        }
        switch await load(url: url) {
        case .cancelled: return .cancelled
        case .failed(let code): return .failed(code: code)
        case .ready(let duration):
            await player.seek(to: resumeAt)
            return .ready(durationSeconds: duration)
        }
    }

    /// Explicitly re-request the audio route — wired to the "Choose Output" affordance. On watchOS
    /// activating a long-form session with no route makes the system present its output picker.
    func requestRoute() async -> WatchAudioActivationResult {
        await activateSession()
    }

    func currentRate() -> Double { Double(player.rate) }

    func currentRoute() -> WatchRouteSnapshot {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        return WatchRouteSnapshot(outputCount: outputs.count,
                                  outputPortTypes: outputs.map { $0.portType.rawValue })
    }

    func currentItemReadiness() -> WatchItemReadiness {
        guard let item = player.currentItem else { return .noItem }
        switch item.status {
        case .unknown: return .unknown
        case .readyToPlay: return .ready
        case .failed: return .failed
        @unknown default: return .unknown
        }
    }

    func removeObservers() {
        removeItemObservers()
        rateObserver?.invalidate()
        rateObserver = nil
    }

    // MARK: - Private

    private static func activationErrorCode(_ error: Error) -> String {
        let nsError = error as NSError
        return "activation-\(nsError.domain)-\(nsError.code)"
    }

    private static func itemErrorCode(_ error: Error?) -> String {
        guard let error else { return "itemFailed" }
        let nsError = error as NSError
        return "item-\(nsError.domain)-\(nsError.code)"
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
