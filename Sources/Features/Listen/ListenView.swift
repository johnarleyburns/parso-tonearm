import SwiftUI
import TonearmCore

struct ListenView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var player: AudioPlayer
    @ObservedObject private var support = SupportDevelopmentStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ScreenHeader(title: "Listen")
                if support.isSupporter {
                    supporterBadge
                        .padding(.top, 6)
                        .padding(.bottom, 10)
                } else {
                    Spacer().frame(height: 16)
                }

                if !appState.recentlyPlayed.isEmpty {
                    cardRow(title: "Jump Back In", rows: appState.recentlyPlayed)
                }
                // "Recently Added" removed at the user's request — it duplicated "Jump Back In"
                // in practice and wasn't used. `appState.recentlyAdded` is left in place (still
                // populated by `reload()`) in case another surface wants it later.
                statsCard(appState.listeningStats)
                favorites
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 160)
        }
        .foregroundStyle(Palette.ink)
        .task { await appState.reload() }
    }

    /// Shown only when `SupportDevelopmentStore.isSupporter` is true — the
    /// one, purely cosmetic acknowledgement of the optional "Contribute to
    /// Development" purchase (business decision: nothing in Tonearm is
    /// gated, so this badge unlocks nothing either).
    private var supporterBadge: some View {
        Label("Supporter", systemImage: "heart.fill")
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(Palette.brass)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .glassSurface(cornerRadius: 12)
            .accessibilityIdentifier("listen.supporterBadge")
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

            if stats.totalPlayCount > 0 {
                weeklyChart(stats.dailyRollups)
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

    /// A 7-day listening-time bar chart, in the style of the parso-voxglass sibling app's
    /// "Listening Stats" weekly chart — plain SwiftUI shapes (no Charts-framework dependency),
    /// scaled to the tallest day, brass gradient bars, day-letter labels underneath. Uses
    /// `stats.dailyRollups` (already computed by `ListeningStats.summarize`) — no new data model.
    private func weeklyChart(_ dailyRollups: [ListeningStats.PeriodRollup]) -> some View {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let byDay = Dictionary(uniqueKeysWithValues: dailyRollups.map {
            (calendar.startOfDay(for: $0.start), $0.listeningTime)
        })
        let formatter: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "EEEEE"
            return f
        }()
        let bars: [(label: String, seconds: TimeInterval)] = (0..<7).reversed().map { offset in
            let day = calendar.date(byAdding: .day, value: -offset, to: today) ?? today
            return (formatter.string(from: day), byDay[day] ?? 0)
        }
        let maxSeconds = max(bars.map(\.seconds).max() ?? 1, 1)

        return HStack(alignment: .bottom, spacing: 8) {
            ForEach(Array(bars.enumerated()), id: \.offset) { _, bar in
                VStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(LinearGradient(
                            colors: [Palette.brass, Palette.brass.opacity(0.7)],
                            startPoint: .top, endPoint: .bottom))
                        .frame(height: max(3, CGFloat(bar.seconds / maxSeconds) * 44))
                        .accessibilityHidden(true)
                    Text(bar.label)
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(Palette.ink3)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(bar.label): \(ListeningStats.durationText(bar.seconds))")
            }
        }
        .frame(height: 58, alignment: .bottom)
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
            Text(row.album?.artist ?? (row.asset?.kind == .remote ? PlaybackDisplayPolicy.providerName(for: row.source) : "On device"))
                .font(.system(size: 11))
                .foregroundStyle(Palette.ink3)
                .lineLimit(1)
                .padding(.top, 1)
        }
        .frame(width: 132)
    }
}
