import SwiftUI

struct ListenView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var player: AudioPlayer

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ScreenHeader(title: "Listen")
                    .padding(.bottom, 16)

                if appState.recentlyPlayed.isEmpty && appState.favoriteRows.isEmpty {
                    EmptyStateView(icon: "play.circle",
                                   title: "Nothing here yet",
                                   message: "Add a source, then play something. Your recent tracks and favorites show up here.")
                        .padding(.top, 60)
                } else {
                    if !appState.recentlyPlayed.isEmpty { jumpBackIn }
                    if !appState.favoriteRows.isEmpty { favorites }
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 160)
        }
        .foregroundStyle(Palette.ink)
        .task { await appState.reload() }
    }

    private var jumpBackIn: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Jump Back In")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(appState.recentlyPlayed) { row in
                        Button {
                            if let idx = appState.recentlyPlayed.firstIndex(where: { $0.id == row.id }) {
                                player.play(tracks: appState.recentlyPlayed, startAt: idx)
                            }
                        } label: {
                            RecentCard(row: row)
                        }
                        .buttonStyle(.plain)
                        .trackContextMenu(row)
                    }
                }
                .padding(.horizontal, 2)
            }
            .padding(.bottom, 20)
        }
    }

    private var favorites: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Favorites", trailing: "\(appState.favoriteRows.count)")
            ForEach(appState.favoriteRows) { row in
                Button {
                    if let idx = appState.favoriteRows.firstIndex(where: { $0.id == row.id }) {
                        player.play(tracks: appState.favoriteRows, startAt: idx)
                    }
                } label: {
                    TrackRowView(row: row)
                }
                .buttonStyle(.plain)
                .trackContextMenu(row)
                Divider().overlay(Palette.hairline)
            }
        }
    }
}

struct RecentCard: View {
    let row: TrackRow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ArtworkView(seed: row.album?.title ?? row.track.title, cornerRadius: 14)
                .frame(width: 132, height: 132)
            Text(row.track.title)
                .font(.system(size: 12.5, weight: .semibold))
                .lineLimit(1)
                .padding(.top, 7)
            Text(row.album?.artist ?? (row.asset?.kind == .remote ? "archive.org" : "On device"))
                .font(.system(size: 11))
                .foregroundStyle(Palette.ink3)
                .lineLimit(1)
                .padding(.top, 1)
        }
        .frame(width: 132)
    }
}
