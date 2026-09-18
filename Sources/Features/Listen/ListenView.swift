import SwiftUI
import TonearmCore
import TonearmDiscovery

struct ListenView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var player: AudioPlayer
    @ObservedObject private var support = SupportDevelopmentStore.shared

    /// Deliberately NOT the same instance "Find by sound" uses — see
    /// `DiscoveryRuntimeController.makeSearchViewModel`'s doc comment
    /// (docs/plans/mood-based-listening-plan.md §2's audit note). Built once
    /// on first appear.
    @State private var moodModel: DiscoverySearchViewModel?
    @State private var selectedPillIDs: Set<MoodPill.ID> = []
    /// The Era/Vibe pill category — generated from this library's own
    /// BPM/key/energy/duration distribution (`SuggestionChips`), not a fixed
    /// list (plan §3.2).
    @State private var eraVibePills: [MoodPill] = []
    @State private var promptDraft: String = ""
    /// Backs the shared `trackDetailSheet` (plan §3.6) — every track tap on
    /// this screen sets this instead of calling `player.play(...)` directly.
    @State private var selectedTrackForDetail: TrackRow?
    /// Cycles the prompt field's placeholder (plan §3.1 point 2: "rotating
    /// through a few evocative examples"). A real, missed requirement caught
    /// re-auditing against the plan — the first pass shipped one static
    /// placeholder instead.
    @State private var placeholderIndex = 0
    /// `fileprivate` (not `private`) — `MoodEntryPointSection` below, a
    /// separate type in this same file, reads it too.
    fileprivate static let promptPlaceholders = [
        "sunday morning coffee", "focus, no vocals", "storm outside"
    ]

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

                // `moodModel` is only `@State` here (its identity, not its
                // `@Published` internals, is what this view needs to react
                // to) — real bug caught re-auditing against the plan:
                // reading `moodModel?.results`/`.searchText` directly inside
                // THIS view's own body, with no `@ObservedObject` anywhere,
                // means SwiftUI never re-renders when the view model
                // publishes new results — tap a pill, the query resolves
                // async, and the Play button / results row would silently
                // never update. `MoodEntryPointSection` below takes
                // `@ObservedObject var moodModel`, matching the exact
                // pattern `DiscoverySearchView` → `DiscoverySearchContent`
                // already establishes in this codebase.
                if let moodModel {
                    MoodEntryPointSection(
                        moodModel: moodModel,
                        selectedPillIDs: $selectedPillIDs,
                        eraVibePills: eraVibePills,
                        promptDraft: $promptDraft,
                        placeholderIndex: placeholderIndex,
                        selectedTrackForDetail: $selectedTrackForDetail)
                        .padding(.bottom, 26)
                } else {
                    moodEntryPointLoading
                        .padding(.bottom, 26)
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
        .task {
            await appState.reload()
            await prepareMoodModel()
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.25)) {
                    placeholderIndex = (placeholderIndex + 1) % Self.promptPlaceholders.count
                }
            }
        }
        .trackDetailSheet(for: $selectedTrackForDetail)
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

    // MARK: - Mood entry point (plan §3.1/§3.2/§3.3/§5 steps 5/8/9)

    private func prepareMoodModel() async {
        guard moodModel == nil else { return }
        let vm = await DiscoveryRuntimeController.shared.makeSearchViewModel(
            appState: appState, player: player)
        moodModel = vm
        let summary = await SuggestionChips.summary(library: appState.store)
        eraVibePills = SuggestionChips.seed(from: summary).map { chip in
            MoodPill(id: chip, label: chip, queryTerm: chip)
        }
    }

    /// Shown only during the brief window before `prepareMoodModel()`
    /// resolves (mirrors `DiscoverySearchView`'s "Preparing search…" state).
    private var moodEntryPointLoading: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "What's the mood?")
            ProgressView()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 14)
        }
    }

    // MARK: - Jump Back In / Favorites

    private func cardRow(title: String, rows: [TrackRow]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: title)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(rows) { row in
                        Button {
                            selectedTrackForDetail = row
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
                                selectedTrackForDetail = row
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

    // MARK: - Listening Stats

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

            if !stats.topTracks.isEmpty {
                topTracksList(stats.topTracks)
            }
            if !stats.topArtists.isEmpty {
                topArtistsList(stats.topArtists)
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
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Palette.ink3)
                                .frame(width: 18, alignment: .leading)
                            Text(rank.row.track.title)
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(1)
                            Spacer()
                            Text("\(rank.playCount) plays")
                                .font(.system(size: 11.5))
                                .foregroundStyle(Palette.ink3)
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
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Palette.ink3)
                                .frame(width: 18, alignment: .leading)
                            Text(rank.name)
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(1)
                            Spacer()
                            Text("\(rank.playCount) plays")
                                .font(.system(size: 11.5))
                                .foregroundStyle(Palette.ink3)
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

/// The prompt bar + pill row + Play/Shake-it-up CTA + live mood results
/// (plan §3.1–§3.3). Split out of `ListenView` itself so `moodModel` can be
/// held as `@ObservedObject` — `ListenView` only needs `moodModel`'s
/// *identity* (nil vs. built), but everything in here needs to react to its
/// `@Published` `searchText`/`positiveRefinements`/`results` changing,
/// which a plain `@State` reference never triggers a re-render for. Matches
/// `DiscoverySearchView` → `DiscoverySearchContent`'s existing split in
/// this codebase for exactly the same reason.
private struct MoodEntryPointSection: View {
    @ObservedObject var moodModel: DiscoverySearchViewModel
    @Binding var selectedPillIDs: Set<MoodPill.ID>
    let eraVibePills: [MoodPill]
    @Binding var promptDraft: String
    let placeholderIndex: Int
    @Binding var selectedTrackForDetail: TrackRow?
    @EnvironmentObject var player: AudioPlayer
    @StateObject private var indexStatusModel = IndexStatusModel()
    @State private var showIndexStatus = false

    private var allMoodPills: [MoodPill] {
        MoodPillTaxonomy.fixedCategories + eraVibePills
    }

    private var promptBinding: Binding<String> {
        Binding(
            get: { moodModel.searchText },
            set: { newValue in
                promptDraft = newValue
                moodModel.searchText = newValue
            })
    }

    /// Toggling a pill adds/removes its `queryTerm` from the mood model's
    /// `positiveRefinements` — additive combination (plan §3.3), never a
    /// replace.
    private var pillSelectionBinding: Binding<Set<MoodPill.ID>> {
        Binding(
            get: { selectedPillIDs },
            set: { newSelection in
                let pills = allMoodPills
                for id in newSelection.subtracting(selectedPillIDs) {
                    if let pill = pills.first(where: { $0.id == id }) {
                        moodModel.addMoreLike(pill.queryTerm)
                    }
                }
                for id in selectedPillIDs.subtracting(newSelection) {
                    if let pill = pills.first(where: { $0.id == id }) {
                        moodModel.removeMoreLike(pill.queryTerm)
                    }
                }
                selectedPillIDs = newSelection
            })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "What's the mood?")

            TextField(ListenView.promptPlaceholders[placeholderIndex], text: promptBinding)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .glassSurface(cornerRadius: 12)
                .accessibilityIdentifier("listen.mood.prompt")

            MoodPillPicker(pills: allMoodPills, selection: pillSelectionBinding)

            HStack(spacing: 10) {
                Button {
                    startMoodPlayback()
                } label: {
                    Label("Play", systemImage: "play.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 11)
                        .background(
                            LinearGradient(colors: [Palette.brass, Palette.brassDeep],
                                          startPoint: .top, endPoint: .bottom),
                            in: Capsule())
                        .foregroundStyle(Color.black)
                }
                .buttonStyle(.plain)
                .disabled(moodModel.results.isEmpty)
                .accessibilityIdentifier("listen.mood.play")

                Button {
                    startMoodPlayback(shuffle: true)
                } label: {
                    Label("Shake it up", systemImage: "shuffle")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 11)
                        .background(Color.white.opacity(0.07), in: Capsule())
                        .foregroundStyle(Palette.ink2)
                }
                .buttonStyle(.plain)
                .disabled(moodModel.results.isEmpty)
                .accessibilityIdentifier("listen.mood.shakeItUp")
            }

            if !moodModel.results.isEmpty {
                moodResultsRow
            } else {
                moodStatusHint
            }
        }
        .sheet(isPresented: $showIndexStatus) {
            IndexStatusView(model: indexStatusModel)
        }
    }

    /// Real report: "the Play button is greyed out... I can't play anything
    /// from there" — the mood section never surfaced WHY there were no
    /// results (model still downloading, nothing indexed yet, a genuine "no
    /// matches"...), just silently showed nothing, leaving Play/"Shake it
    /// up" permanently disabled with zero explanation. Violates CLAUDE.md's
    /// "no silent/magic background work" rule and is missing exactly the
    /// state handling `DiscoverySearchView.resultsSection` already has for
    /// the same `DiscoverySearchScreenState` — mirrored here.
    @ViewBuilder
    private var moodStatusHint: some View {
        switch moodModel.screen {
        case .idle:
            EmptyView()
        case .loading:
            HStack(spacing: 8) {
                ProgressView()
                Text("Searching…").foregroundStyle(Palette.ink3)
            }
            .font(.callout)
        case .modelMissing:
            VStack(alignment: .leading, spacing: 8) {
                hint("Mood search needs the sound-search model.")
                HStack {
                    Button("Download models") { moodModel.downloadModels() }
                        .buttonStyle(.borderedProminent)
                    Button("Sound-index status") { showIndexStatus = true }
                        .buttonStyle(.bordered)
                }
            }
        case .modelDownloadFailed:
            VStack(alignment: .leading, spacing: 8) {
                hint("The sound-search model could not be loaded.")
                Button("Try again") { moodModel.retry() }.buttonStyle(.bordered)
            }
        case .zeroIndexed:
            VStack(alignment: .leading, spacing: 8) {
                hint("Nothing in your library is indexed for sound yet.")
                Button("Open sound-index status") { showIndexStatus = true }
                    .buttonStyle(.bordered)
            }
        case .noMatches:
            hint("No tracks matched that mood yet. Try different pills or fewer of them.")
        case .emptyLibrary:
            hint("Your library is empty. Add music to try a mood.")
        case .emptyScope, .sourceUnavailable:
            hint("That source isn't available right now.")
        case .searchFailed:
            VStack(alignment: .leading, spacing: 8) {
                hint("Something went wrong running that search.")
                Button("Retry") { moodModel.retry() }.buttonStyle(.bordered)
            }
        case .validationError, .analyzeReference, .staleSuppressed, .results:
            EmptyView()
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(Palette.ink3)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Starts (or updates) playback from the mood query's current results,
    /// tagging the queue `.mood(moodModel)` so Keep Playing re-queries this
    /// same mood instead of falling back to generic similarity (plan §3.3,
    /// `AudioPlayer+KeepPlaying.swift`). "Shake it up" reshuffles the same
    /// result set rather than issuing a new query — the pills/prompt are the
    /// mood the person asked for; shaking gives a different order through it,
    /// not a different mood.
    ///
    /// If a mood queue from THIS view model is already playing, both
    /// buttons update the *upcoming* queue non-destructively instead of
    /// restarting from track 0 — mirrors Acalum's "Update upcoming" vs.
    /// "Play now" distinction (plan §3.1 point 5): changing pills mid-
    /// listen shouldn't yank the currently-playing track.
    private func startMoodPlayback(shuffle: Bool = false) {
        guard !moodModel.results.isEmpty else { return }
        var tracks = moodModel.results.map(\.track)
        if shuffle { tracks.shuffle() }
        if player.isPlaying, case .mood(let active) = player.queueSource, active === moodModel {
            player.updateUpcoming(with: tracks, source: .mood(moodModel))
        } else {
            player.play(tracks: tracks, startAt: 0, source: .mood(moodModel))
        }
    }

    private var moodResultsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(moodModel.results, id: \.track.id) { result in
                    Button {
                        selectedTrackForDetail = result.track
                    } label: {
                        RecentCard(row: result.track)
                    }
                    .buttonStyle(.plain)
                    .trackContextMenu(result.track)
                }
            }
            .padding(.horizontal, 2)
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
