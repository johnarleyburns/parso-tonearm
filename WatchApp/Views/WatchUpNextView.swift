import SwiftUI
import TonearmCore

struct WatchUpNextView: View {
    @ObservedObject private var player = WatchPlayer.shared

    var body: some View {
        Group {
            if player.queueTracks.isEmpty {
                WatchEmptyStateView(
                    icon: "list.bullet",
                    title: "Queue Empty",
                    message: "Play a track to add it to the queue.")
            } else {
                List {
                    ForEach(Array(player.queueTracks.enumerated()), id: \.element.id) { idx, row in
                        Button {
                            player.jump(to: idx)
                        } label: {
                            HStack {
                                if row.id == player.currentTrack?.id {
                                    Image(systemName: player.isPlaying ? "play.fill" : "pause.fill")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.tint)
                                }
                                WatchTrackRow(row: row)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listStyle(.carousel)
            }
        }
        .navigationTitle("Up Next")
    }
}
