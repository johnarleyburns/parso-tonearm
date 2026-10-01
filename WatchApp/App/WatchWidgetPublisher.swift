import Combine
import Foundation
import WidgetKit
import TonearmWatchCore

/// Watch redesign A2 — keeps the Smart Stack widget's shared state current. It writes whatever
/// Now Playing shows (either device) to the App Group and reloads the widget only when the card
/// would actually change (title, play state, device, or a seek) — never on clock ticks.
@MainActor
final class WatchWidgetPublisher {
    static let shared = WatchWidgetPublisher()
    private var cancellables = Set<AnyCancellable>()
    private var last: WatchNowPlayingWidgetState?

    func start() {
        guard cancellables.isEmpty else { return }
        last = WatchNowPlayingWidgetStore.load()
        Publishers.Merge3(WatchPlayer.shared.objectWillChange.map { _ in () },
                          WatchRemotePlayer.shared.objectWillChange.map { _ in () },
                          WatchPlaybackCoordinator.shared.objectWillChange.map { _ in () })
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
        let remote = WatchRemotePlayer.shared
        let shown = WatchNowPlayingResolver.shown(
            local: .init(hasItem: player.currentTrack != nil, isPlaying: player.isPlaying),
            remote: .init(hasItem: remote.state?.currentItem != nil, isPlaying: remote.state?.isPlaying ?? false),
            target: WatchPlaybackCoordinator.shared.target)
        let now = Date()
        switch shown {
        case .iPhone:
            guard let state = remote.state, let item = state.currentItem else { return nil }
            return WatchNowPlayingWidgetState(title: item.title, subtitle: item.artist, target: .iPhone,
                                              isPlaying: state.isPlaying, elapsed: state.predictedElapsed(at: now),
                                              duration: item.durationSeconds ?? 0, anchorDate: now,
                                              colorHex: state.snapshot.artworkColorHex)
        case .thisWatch:
            guard let track = player.currentTrack else { return nil }
            return WatchNowPlayingWidgetState(title: track.title, subtitle: track.artist, target: .watch,
                                              isPlaying: player.isPlaying, elapsed: player.elapsed,
                                              duration: player.duration, anchorDate: now)
        case nil:
            return nil
        }
    }
}
