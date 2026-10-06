import Foundation
import SwiftUI
import TonearmWatchCore
import TonearmWatchProtocol

/// Legacy compatibility shell for the removed iPhone playback target. The watch is now local-only:
/// this type retains old view and widget seams while deliberately sending no playback commands or
/// polling requests. Audio playback belongs to `WatchPlayer` and requires a ready local asset.
///
/// The pure parts (revision ordering, elapsed prediction, staleness) live in
/// `WatchRemotePlaybackState` in `TonearmWatchCore` and are host-tested there; this type is the
/// thin `@MainActor` shell that owns the timer and the send seam.
@MainActor
final class WatchRemotePlayer: ObservableObject {
    static let shared = WatchRemotePlayer()

    /// What the phone is playing, as last heard. `nil` until the first snapshot arrives.
    @Published private(set) var state: WatchRemotePlaybackState?
    /// Bumped once a second while Now Playing (iPhone target) is on screen so the predicted
    /// elapsed clock re-renders without a new snapshot.
    @Published private(set) var clockTick: Int = 0
    /// The last "play on iPhone" the phone refused or never answered, with its protocol code, so
    /// Now Playing can say so and offer a retry instead of silently showing nothing.
    @Published private(set) var startFailure: StartFailure?

    struct StartFailure: Equatable {
        var command: WatchPlayCommand
        var code: String
        /// How many songs of the requested item are downloaded here — S4 offers "Play on Watch"
        /// only when this is real.
        var downloadedAlternativeCount = 0
    }

    /// T3: a "play on iPhone" is in flight; Now Playing shows "Starting on iPhone…" until the
    /// phone's reply or snapshot confirms it, or S4 replaces it.
    @Published private(set) var isStarting = false
    @Published private(set) var startingTitle: String?

    func beginStart(title: String?) {
        startFailure = nil
        startingTitle = title
        isStarting = true
    }

    func endStart() {
        isStarting = false
        startingTitle = nil
    }

    private var pendingVolume: Double?
    private var lastSentVolume: Double?
    private var volumeTask: Task<Void, Never>?
    private let send: (WatchPlayCommand) async -> Void
    private let requestSnapshot: () async -> Void
    private var timer: Timer?
    private var ticksSincePoll = 0

    /// The default wiring talks to the real coordinator; tests inject spies.
    init(send: @escaping (WatchPlayCommand) async -> Void = { _ in },
         requestSnapshot: @escaping () async -> Void = {}) {
        self.send = send
        self.requestSnapshot = requestSnapshot
    }

    // MARK: - Inbound

    /// Apply a snapshot received from the phone, dropping it if it is older than what we hold.
    func apply(_ snapshot: WatchPhonePlaybackSnapshot) {
        let now = Date()
        if let current = state {
            guard let next = current.applying(snapshot, at: now) else { return }
            state = next
        } else {
            state = WatchRemotePlaybackState(snapshot: snapshot, receivedAt: now)
        }
    }

    func clear() { state = nil }

    func setStartFailure(_ failure: StartFailure?) { startFailure = failure }

    // MARK: - Legacy transport (intentionally disabled)

    func play() { dispatch(WatchPlayCommand(action: .play)) }
    func pause() { dispatch(WatchPlayCommand(action: .pause)) }
    func togglePlayPause() { dispatch(WatchPlayCommand(action: .togglePlayPause)) }
    func next() { dispatch(WatchPlayCommand(action: .next)) }
    func previous() { dispatch(WatchPlayCommand(action: .previous)) }
    func jump(to index: Int) { dispatch(WatchPlayCommand(action: .jumpToIndex, startIndex: index)) }
    func setShuffle(_ enabled: Bool) { dispatch(WatchPlayCommand(action: .setShuffle, shuffleEnabled: enabled)) }
    func setRepeat(_ mode: TonearmWatchProtocol.WatchRepeatMode) { dispatch(WatchPlayCommand(action: .setRepeat, repeatMode: mode)) }

    // MARK: - Volume (watch redesign §6.1)

    /// The phone player's level as last reported, or the Crown's latest local value while the user is
    /// turning it. 1 when the phone predates the redesign and reports no volume.
    var volume: Double { pendingVolume ?? state?.snapshot.volume ?? 1 }

    /// True once the phone reports its level — a phone that predates the redesign can't take
    /// `setVolume`, so the Crown stays idle rather than sending commands it would reject.
    var supportsVolume: Bool { state?.snapshot.volume != nil }

    /// The Crown fires many changes per second; send at most every 150 ms, latest value wins.
    func setVolume(_ level: Double) {
        let clamped = min(max(level, 0), 1)
        pendingVolume = clamped
        objectWillChange.send()
        guard volumeTask == nil else { return }
        volumeTask = Task { @MainActor [weak self] in
            while let self, let value = self.pendingVolume, value != self.lastSentVolume {
                self.lastSentVolume = value
                await self.send(.setVolume(value))
                try? await Task.sleep(for: .milliseconds(150))
            }
            self?.volumeTask = nil
            self?.pendingVolume = nil
        }
    }

    private func dispatch(_ command: WatchPlayCommand) {
        // Kept as a no-op for old callers compiled against the compatibility shell. Product code
        // must use WatchPlayer, which only accepts tracks whose local audio is ready.
    }

    // MARK: - Prediction clock + correction poll

    /// Called from the W7 view's `.onAppear`. Ticks the predicted clock every second and asks the
    /// phone for an authoritative correction every fifth tick (§7.1). Torn down on `.onDisappear`
    /// so an idle watch does no polling (§11 / I-10).
    func startClock() {
        stopClock()
        // There is no remote clock to predict or correct in watch-only mode.
    }

    func stopClock() {
        timer?.invalidate()
        timer = nil
    }

    private func onTick() {
        clockTick &+= 1
        ticksSincePoll += 1
        if ticksSincePoll >= 5 {
            ticksSincePoll = 0
            Task { await requestSnapshot() }
        }
    }
}
