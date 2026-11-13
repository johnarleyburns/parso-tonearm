import SwiftUI
import TonearmWatchCore

/// Watch redesign §5 N4 — Up Next for this watch's local queue.
struct WatchUpNextView: View {
    @ObservedObject private var player = WatchPlayer.shared

    var body: some View {
        localQueue
            .navigationTitle("Up Next")
    }

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
                                isPlaying: player.isPlaying)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(rowBackground(current: isCurrent))
                    }
                } header: {
                    Text(header(collection: player.currentTrack?.albumTitle))
                }
            }
        }
    }

    // MARK: Rows

    private func row(title: String, detail: String, isCurrent: Bool, isPlaying: Bool) -> some View {
        HStack(spacing: 8) {
            if isCurrent {
                Image(systemName: isPlaying ? "play.fill" : "pause.fill")
                    .font(.caption2).foregroundStyle(WatchPalette.accent)
                    .accessibilityLabel((isPlaying ? Text("Now playing") : Text("Paused here")))
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
        .contentShape(Rectangle())
    }

    private func rowBackground(current: Bool) -> some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(current ? WatchPalette.accentSoft : WatchPalette.surface)
    }

    private func header(collection: String?) -> String {
        if let collection, !collection.isEmpty {
            return String(localized: "Playing from \(collection) · on Watch")
        }
        return String(localized: "Playing on Watch")
    }
}
