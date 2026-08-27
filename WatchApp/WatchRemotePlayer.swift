import Foundation
import SwiftUI
import TonearmWatchCore
import TonearmWatchProtocol

/// The watch's remote control for the **iPhone** playback target (§7.1). It holds the last
/// `WatchPhonePlaybackSnapshot` the phone sent, predicts the elapsed clock forward from its anchor,
/// and forwards transport to the phone over the link — it never drives local audio.
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

    private let send: (WatchPlayCommand) async -> Void
    private let requestSnapshot: () async -> Void
    private var timer: Timer?
    private var ticksSincePoll = 0

    /// The default wiring talks to the real coordinator; tests inject spies.
    init(send: @escaping (WatchPlayCommand) async -> Void = { command in
             _ = await WatchAppAssembly.shared.playOnPhone(command)
         },
         requestSnapshot: @escaping () async -> Void = {
             await WatchAppAssembly.shared.refreshRemotePlayback()
         }) {
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

    // MARK: - Transport (always addressed to the phone)

    func play() { dispatch(WatchPlayCommand(action: .play)) }
    func pause() { dispatch(WatchPlayCommand(action: .pause)) }
    func togglePlayPause() { dispatch(WatchPlayCommand(action: .togglePlayPause)) }
    func next() { dispatch(WatchPlayCommand(action: .next)) }
    func previous() { dispatch(WatchPlayCommand(action: .previous)) }
    func jump(to index: Int) { dispatch(WatchPlayCommand(action: .jumpToIndex, startIndex: index)) }

    private func dispatch(_ command: WatchPlayCommand) {
        Task { await send(command) }
    }

    // MARK: - Prediction clock + correction poll

    /// Called from the W7 view's `.onAppear`. Ticks the predicted clock every second and asks the
    /// phone for an authoritative correction every fifth tick (§7.1). Torn down on `.onDisappear`
    /// so an idle watch does no polling (§11 / I-10).
    func startClock() {
        stopClock()
        ticksSincePoll = 0
        Task { await requestSnapshot() }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.onTick() }
        }
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
