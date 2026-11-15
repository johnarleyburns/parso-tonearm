import SwiftUI
import TonearmCore

struct ListenView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var player: AudioPlayer
    @ObservedObject private var support = SupportDevelopmentStore.shared

    /// Listening Stats' Top 10 Songs/Artists — collapsed by default (real
    /// report), shown via an explicit "Show More…".
    @State private var showTopLists = false
    /// Backs the shared `trackDetailSheet` (plan §3.6) — every track tap on
    /// this screen sets this instead of calling `player.play(...)` directly.
    @State private var selectedTrackForDetail: TrackRow?
    @ScaledMetric(relativeTo: .body) private var collectionContentHeight: CGFloat = 188
    @State private var showSettings = false
    @State private var showClearRecentConfirm = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if support.isSupporter {
                    supporterBadge
                        .padding(.top, 6)
                        .padding(.bottom, 10)
                } else {
                    Spacer().frame(height: 16)
                }

                cardRow(title: "Jump Back In", rows: appState.recentlyPlayed,
                        emptyMessage: "Your recently played music will appear here.", identifier: "listen.recent",
                        onClear: { showClearRecentConfirm = true })
                favorites
                statsCard(appState.listeningStats)
                    .redacted(reason: appState.didLoadLibraryOnce ? [] : .placeholder)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 160)
        }
        .navigationTitle("Listen")
        .largeNavigationTitle()
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape.fill")
                }
                .accessibilityLabel("Settings")
                .accessibilityIdentifier("listen.settings")
            }
        }
        .foregroundStyle(Palette.ink)
        .task {
            guard appState.didLoadLibraryOnce else { return }
            await appState.reload()
        }
        .trackDetailSheet(for: $selectedTrackForDetail)
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .confirmationDialog("Clear Jump Back In?", isPresented: $showClearRecentConfirm,
                            titleVisibility: .visible) {
            Button("Clear", role: .destructive) {
                Task { await clearRecentHistory() }
            }
            .accessibilityIdentifier("listen.recent.clearConfirm")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This also resets Listening Stats — play counts, streaks, Top 10s, and Year in Review. This cannot be undone.")
        }
        .sensoryFeedback(.warning, trigger: showClearRecentConfirm)
    }

    /// Shown only when `SupportDevelopmentStore.isSupporter` is true — the
    /// one, purely cosmetic acknowledgement of the optional "Contribute to
    /// Development" purchase (business decision: nothing in Tonearm is
    /// gated, so this badge unlocks nothing either).
    private var supporterBadge: some View {
        Label("Supporter", systemImage: "heart.fill")
            .font(Typography.caption)
            .foregroundStyle(Palette.accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .glassSurface(cornerRadius: 12)
            .accessibilityIdentifier("listen.supporterBadge")
    }


    // MARK: - Jump Back In / Favorites

    private func cardRow(title: LocalizedStringKey, rows: [TrackRow],
                         emptyMessage: LocalizedStringKey, identifier: String,
                         showNeverRecommend: Bool = false,
                         onClear: (() -> Void)? = nil) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                SectionHeader(title: title)
                Spacer()
                if let onClear {
                    Button("Clear", action: onClear)
                        .font(Typography.caption)
                        .foregroundStyle(Palette.inkTertiary)
                        .padding(.bottom, 10)
                        .accessibilityIdentifier("listen.recent.clear")
                }
            }
            Group {
                if !appState.didLoadLibraryOnce {
                    HStack { ProgressView(); Text("Loading…") }
                        .accessibilityIdentifier(identifier == "listen.recent" ? "listen.loading" : "listen.favorites.loading")
                } else if rows.isEmpty {
                    Text(emptyMessage).font(Typography.callout).foregroundStyle(Palette.inkTertiary)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 12) {
                            ForEach(rows) { row in
                                Button {
                                    selectedTrackForDetail = row
                                } label: {
                                    RecentCard(row: row)
                                }
                                .buttonStyle(.plain)
                                .trackContextMenu(row, showRemoveFromJumpBackIn: identifier == "listen.recent",
                                                  showNeverRecommend: showNeverRecommend)
                            }
                        }
                        .padding(.horizontal, 2)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: collectionContentHeight, alignment: .topLeading)
        }
        .padding(.bottom, 20)
        .accessibilityIdentifier(identifier)
    }

    /// Runs only from the confirmed destructive dialog action.
    private func clearRecentHistory() async {
        try? await appState.store.clearPlayHistory()
        await appState.reload()
    }

    private var favorites: some View {
        cardRow(title: "Favorites", rows: appState.favoriteRows,
                emptyMessage: "Your favorite music will appear here.", identifier: "listen.favorites",
                showNeverRecommend: true)
    }

    // MARK: - Listening Stats

    private func statsCard(_ stats: ListeningStats.Summary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionHeader(title: "Listening Stats")
                Spacer()
                if stats.totalPlayCount > 0 {
                    ShareLink(item: stats.yearInReview.shareText) {
                        Image(systemName: "square.and.arrow.up")
                            .font(Typography.callout)
                            .foregroundStyle(Palette.accent)
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

            // Real report: collapsed by default, showing only the summary
            // tiles and the weekly chart — Top 10 Songs/Artists (the long
            // part) sit behind an explicit "Show More…" rather than always
            // taking their full height on a screen everyone opens often.
            if !stats.topTracks.isEmpty || !stats.topArtists.isEmpty {
                if showTopLists {
                    if !stats.topTracks.isEmpty {
                        topTracksList(stats.topTracks)
                    }
                    if !stats.topArtists.isEmpty {
                        topArtistsList(stats.topArtists)
                    }
                    Button("Show Less") { Motion.perform(Motion.standard) { showTopLists = false } }
                        .font(Typography.callout)
                        .foregroundStyle(Palette.accent)
                        .accessibilityIdentifier("listen.stats.showLess")
                } else {
                    Button("Show More…") { Motion.perform(Motion.standard) { showTopLists = true } }
                        .font(Typography.callout)
                        .foregroundStyle(Palette.accent)
                        .accessibilityIdentifier("listen.stats.showMore")
                }
            }
        }
        .padding(.bottom, 22)
    }

    private func statTile(title: LocalizedStringKey, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(Typography.headline)
            Text(title)
                .font(Typography.caption)
                .foregroundStyle(Palette.inkTertiary)
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
                            colors: [Palette.accent, Palette.accent.opacity(0.7)],
                            startPoint: .top, endPoint: .bottom))
                        .frame(height: max(3, CGFloat(bar.seconds / maxSeconds) * 44))
                        .accessibilityHidden(true)
                    Text(bar.label)
                        .font(Typography.caption)
                        .foregroundStyle(Palette.inkTertiary)
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

    /// Tappable Top 10 Songs list (replaces the old single "Top Track" line —
    /// owner feedback, plan §3.4). Each row opens `TrackDetailCard` like
    /// every other track tap on this screen.
    private func topTracksList(_ ranks: [ListeningStats.TrackRank]) -> some View {
        let top = Array(ranks.prefix(10))
        return VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Top 10 Songs")
            VStack(spacing: 0) {
                ForEach(Array(top.enumerated()), id: \.element.id) { index, rank in
                    Button {
                        selectedTrackForDetail = rank.row
                    } label: {
                        HStack(spacing: 10) {
                            Text("\(index + 1)")
                                .font(Typography.caption)
                                .foregroundStyle(Palette.inkTertiary)
                                .frame(width: 18, alignment: .leading)
                            Text(rank.row.track.title)
                                .font(Typography.callout)
                                .lineLimit(1)
                            Spacer()
                            Text("\(rank.playCount) plays")
                                .font(Typography.caption)
                                .foregroundStyle(Palette.inkTertiary)
                        }
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("listen.topSongs.row.\(index)")
                    if index < top.count - 1 {
                        Divider().opacity(0.15)
                    }
                }
            }
            .padding(.top, 4)
        }
        .padding(.top, 6)
    }

    /// Tappable Top 10 Artists list (replaces the old single "Top Artist"
    /// line — owner feedback, plan §3.4). Tapping lands on that artist in
    /// My Music via `appState.pendingArtistFilter` (one-shot launch intent,
    /// consumed by `MyMusicView`).
    private func topArtistsList(_ ranks: [ListeningStats.NameRank]) -> some View {
        let top = Array(ranks.prefix(10))
        return VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Top 10 Artists")
            VStack(spacing: 0) {
                ForEach(Array(top.enumerated()), id: \.element.id) { index, rank in
                    Button {
                        appState.pendingArtistFilter = rank.name
                        appState.tab = .myMusic
                    } label: {
                        HStack(spacing: 10) {
                            Text("\(index + 1)")
                                .font(Typography.caption)
                                .foregroundStyle(Palette.inkTertiary)
                                .frame(width: 18, alignment: .leading)
                            Text(rank.name)
                                .font(Typography.callout)
                                .lineLimit(1)
                            Spacer()
                            Text("\(rank.playCount) plays")
                                .font(Typography.caption)
                                .foregroundStyle(Palette.inkTertiary)
                        }
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("listen.topArtists.row.\(index)")
                    if index < top.count - 1 {
                        Divider().opacity(0.15)
                    }
                }
            }
            .padding(.top, 4)
        }
        .padding(.top, 6)
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
                .font(Typography.callout)
                .lineLimit(1)
                .padding(.top, 7)
            Text(row.artist?.name ?? row.album?.artist ?? (row.asset?.kind == .remote ? PlaybackDisplayPolicy.providerName(for: row.source) : String(localized: "On device")))
                .font(Typography.caption)
                .foregroundStyle(Palette.inkTertiary)
                .lineLimit(1)
                .padding(.top, 1)
        }
        .frame(width: 132)
    }
}
