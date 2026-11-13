import Combine
import Foundation
import WidgetKit
import TonearmWatchCore

/// Watch redesign A2 — keeps the Smart Stack widget's shared state current. It writes this
/// watch's local Now Playing state to the App Group and reloads the widget only when the card
/// would actually change (title, play state, or a seek) — never on clock ticks.
@MainActor
final class WatchWidgetPublisher {
    static let shared = WatchWidgetPublisher()
    private var cancellables = Set<AnyCancellable>()
    private var last: WatchNowPlayingWidgetState?

    func start() {
        guard cancellables.isEmpty else { return }
        last = WatchNowPlayingWidgetStore.load()
        WatchPlayer.shared.objectWillChange
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] in self?.publish() }
            .store(in: &cancellables)
    }

    private func publish() {
        let state = current()
        guard state != last else { return }
        let reload = state?.differsStructurally(from: last) ?? (last != nil)
        WatchNowPlayingWidgetStore.save(state)
        last = state
        if reload { WidgetCenter.shared.reloadTimelines(ofKind: "PlatterheadWatchNowPlaying") }
    }

    private func current() -> WatchNowPlayingWidgetState? {
        let player = WatchPlayer.shared
        guard let track = player.currentTrack else { return nil }
        return WatchNowPlayingWidgetState(title: track.title, subtitle: track.artist, target: .watch,
                                          isPlaying: player.isPlaying, elapsed: player.elapsed,
                                          duration: player.duration, anchorDate: Date())
    }
}
