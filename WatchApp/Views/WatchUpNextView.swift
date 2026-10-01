import SwiftUI
import TonearmWatchCore
import TonearmWatchProtocol

/// Watch redesign §5 N4 — Up Next for whichever engine Now Playing shows. The header says where
/// the queue plays; tapping a row jumps that engine; a row the shown engine can't play here stays
/// visible with a note ("iPhone only"), never hidden.
struct WatchUpNextView: View {
    @ObservedObject private var player = WatchPlayer.shared
    @ObservedObject private var remote = WatchRemotePlayer.shared
    @ObservedObject private var coordinator = WatchPlaybackCoordinator.shared

    private var shown: WatchTarget {
        WatchNowPlayingResolver.shown(
            local: .init(hasItem: player.currentTrack != nil, isPlaying: player.isPlaying),
            remote: .init(hasItem: remote.state?.currentItem != nil, isPlaying: remote.state?.isPlaying ?? false),
            target: coordinator.target) ?? coordinator.target
    }

    var body: some View {
        Group {
            if shown == .iPhone { remoteQueue } else { localQueue }
        }
        .navigationTitle("Up Next")
    }

    // MARK: iPhone

    @ViewBuilder
    private var remoteQueue: some View {
        if let state = remote.state, !state.queueWindow.isEmpty {
            List {
                Section {
                    ForEach(Array(state.queueWindow.enumerated()), id: \.element.id) { offset, item in
                        let index = state.queueWindowStartIndex + offset
                        Button { remote.jump(to: index) } label: {
                            row(title: item.title,
                                detail: item.isDownloadedOnWatch ? item.artist
                                                                 : String(localized: "iPhone only"),
                                isCurrent: index == state.queueIndex, isPlaying: state.isPlaying,
                                downloaded: item.isDownloadedOnWatch)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(rowBackground(current: index == state.queueIndex))
                    }
                } header: {
                    Text(header(collection: state.collectionTitle, target: .iPhone))
                }
            }
        } else {
            WatchEmptyStateView(icon: "list.bullet", title: "Nothing Queued",
                                message: "Play something on your iPhone to see it here.")
        }
    }

    // MARK: This watch

    @ViewBuilder
    private var localQueue: some View {
        if player.queueTracks.isEmpty {
            WatchEmptyStateView(icon: "list.bullet", title: "Queue Empty",
                                message: "Play a song to add it to the queue.")
        } else {
            List {
                Section {
                    ForEach(Array(player.queueTracks.enumerated()), id: \.element.id) { index, track in
                        let isCurrent = track.id == player.currentTrack?.id
                        Button { player.jump(to: index) } label: {
                            row(title: track.title, detail: track.artist, isCurrent: isCurrent,
                                isPlaying: player.isPlaying, downloaded: true)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(rowBackground(current: isCurrent))
                    }
                } header: {
                    Text(header(collection: player.currentTrack?.albumTitle, target: .thisWatch))
                }
            }
        }
    }

    // MARK: Rows

    private func row(title: String, detail: String, isCurrent: Bool, isPlaying: Bool, downloaded: Bool) -> some View {
        HStack(spacing: 8) {
            if isCurrent {
                Image(systemName: isPlaying ? "play.fill" : "pause.fill")
                    .font(.caption2).foregroundStyle(WatchPalette.accent)
                    .accessibilityLabel(Text(isPlaying ? "Now playing" : "Paused here"))
            } else {
                WatchArtTile(tint: WatchArtTint.color(for: title), size: 28)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.body).lineLimit(1)
                if !detail.isEmpty {
                    Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 2)
        }
        .opacity(shown == .thisWatch || downloaded || isCurrent ? 1 : 0.85)
        .contentShape(Rectangle())
    }

    private func rowBackground(current: Bool) -> some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(current ? WatchPalette.accentSoft : WatchPalette.surface)
    }

    private func header(collection: String?, target: WatchTarget) -> String {
        let place = target == .iPhone ? String(localized: "on iPhone") : String(localized: "on Watch")
        if let collection, !collection.isEmpty {
            return String(localized: "Playing from \(collection) · \(place)")
        }
        return String(localized: "Playing \(place)")
    }
}
