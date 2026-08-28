import SwiftUI
import TonearmWatchCore

/// W9 — Up Next for whichever engine currently owns transport (§7.1). Tapping a row jumps that
/// engine; a row the active engine can't play is shown but explained.
struct WatchUpNextView: View {
    @ObservedObject private var player = WatchPlayer.shared
    @ObservedObject private var remote = WatchRemotePlayer.shared
    @ObservedObject private var coordinator = WatchPlaybackCoordinator.shared

    var body: some View {
        Group {
            if coordinator.target == .iPhone {
                remoteQueue
            } else {
                localQueue
            }
        }
        .navigationTitle("Up Next")
    }

    // MARK: - iPhone target

    @ViewBuilder
    private var remoteQueue: some View {
        if let state = remote.state, !state.queueWindow.isEmpty {
            List {
                Section("Playing \(state.queueCount) on iPhone") {
                    ForEach(Array(state.queueWindow.enumerated()), id: \.element.id) { offset, item in
                        let absoluteIndex = state.queueWindowStartIndex + offset
                        Button {
                            remote.jump(to: absoluteIndex)
                        } label: {
                            HStack(spacing: 8) {
                                if absoluteIndex == state.queueIndex {
                                    Image(systemName: state.isPlaying ? "play.fill" : "pause.fill")
                                        .font(.system(size: 10)).foregroundStyle(.tint)
                                        .accessibilityLabel(state.isPlaying ? "Now playing" : "Paused here")
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title).font(.system(.body)).lineLimit(1)
                                    if !item.isDownloadedOnWatch {
                                        Text("iPhone only").font(.system(.caption2)).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer(minLength: 4)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .listStyle(.carousel)
        } else {
            WatchEmptyStateView(icon: "list.bullet", title: "Nothing Queued",
                                message: "Play something on your iPhone to see it here.")
        }
    }

    // MARK: - This-watch target

    @ViewBuilder
    private var localQueue: some View {
        if player.queueTracks.isEmpty {
            WatchEmptyStateView(icon: "list.bullet", title: "Queue Empty",
                                message: "Play a track to add it to the queue.")
        } else {
            List {
                ForEach(Array(player.queueTracks.enumerated()), id: \.element.id) { idx, track in
                    Button {
                        player.jump(to: idx)
                    } label: {
                        HStack {
                            if track.id == player.currentTrack?.id {
                                Image(systemName: player.isPlaying ? "play.fill" : "pause.fill")
                                    .font(.system(size: 10)).foregroundStyle(.tint)
                                    .accessibilityLabel(player.isPlaying ? "Now playing" : "Paused here")
                            }
                            WatchTrackRow(track: track)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.carousel)
        }
    }
}
