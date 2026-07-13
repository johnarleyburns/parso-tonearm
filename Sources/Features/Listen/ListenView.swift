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
                statsCard(appState.listeningStats)
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
                                player.play(tracks: rows, startAt: idx, source: .library)
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
                                    player.play(tracks: appState.favoriteRows, startAt: idx, source: .library)
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

    private func statsCard(_ stats: ListeningStats.Summary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionHeader(title: "Listening Stats")
                Spacer()
                if stats.totalPlayCount > 0 {
                    ShareLink(item: stats.yearInReview.shareText) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.brass)
                    }
                    .accessibilityLabel("Share")
                }
            }

            HStack(spacing: 10) {
                statTile(title: "Plays", value: "\(stats.totalPlayCount)")
                statTile(title: "Time", value: ListeningStats.durationText(stats.totalListeningTime))
                statTile(title: "Streak", value: "\(stats.currentStreakDays)d")
            }

            if let artist = stats.topArtists.first {
                topLine("Top Artist", artist.name, detail: "\(artist.playCount) plays")
            }
            if let track = stats.topTracks.first {
                topLine("Top Track", track.row.track.title, detail: "\(track.playCount) plays")
            }
        }
        .padding(.bottom, 22)
    }

    private func statTile(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.system(size: 18, weight: .bold))
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Palette.ink3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .glassSurface(cornerRadius: 8)
    }

    private func topLine(_ title: String, _ value: String, detail: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Palette.ink3)
                Text(value)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
            }
            Spacer()
            Text(detail)
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.ink3)
        }
    }
}

struct RecentCard: View {
    let row: TrackRow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ArtworkView(trackRow: row,
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
