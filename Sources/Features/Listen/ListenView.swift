import SwiftUI

struct ListenView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var player: AudioPlayer

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ScreenHeader(title: "Listen")
                    .padding(.bottom, 16)

                if !appState.recentlyPlayed.isEmpty {
                    cardRow(title: "Jump Back In", rows: appState.recentlyPlayed)
                }
                if !appState.recentlyAdded.isEmpty {
                    cardRow(title: "Recently Added", rows: appState.recentlyAdded)
                }
                favorites
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 160)
        }
        .foregroundStyle(Palette.ink)
        .task { await appState.reload() }
    }

    private func cardRow(title: String, rows: [TrackRow]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: title)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(rows) { row in
                        Button {
                            if let idx = rows.firstIndex(where: { $0.id == row.id }) {
                                player.play(tracks: rows, startAt: idx)
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
            SectionHeader(title: "Favorites",
                          trailing: appState.favoriteRows.isEmpty ? nil : "\(appState.favoriteRows.count)")
            if appState.favoriteRows.isEmpty {
                Text("Favorite a track and it will show up here.")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.ink3)
                    .padding(.vertical, 18)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(appState.favoriteRows) { row in
                            Button {
                                if let idx = appState.favoriteRows.firstIndex(where: { $0.id == row.id }) {
                                    player.play(tracks: appState.favoriteRows, startAt: idx)
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
            }
        }
    }
}

struct RecentCard: View {
    let row: TrackRow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ArtworkView(identifier: row.source?.iaIdentifier,
                        trackRow: row,
                        seed: row.album?.title ?? row.track.title,
                        cornerRadius: 14)
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
