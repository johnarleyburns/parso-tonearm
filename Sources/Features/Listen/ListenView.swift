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
    /// `nil` while the readiness check hasn't resolved yet; `false` when the
    /// CLAP model isn't downloaded or nothing is indexed yet. Real report:
    /// showing the normal prompt/pills/Play UI with everything permanently
    /// disabled (the old `.modelMissing`/`.zeroIndexed` inline hints) read as
    /// broken — "Download models"/"Sound-index status" buttons in a cramped
    /// layout underneath controls that don't work yet. Gating the whole
    /// section up front on real readiness is clearer.
    @State private var moodReady: Bool?
    @StateObject private var indexStatusModel = IndexStatusModel()
    @State private var showIndexStatus = false
    @State private var selectedPillIDs: Set<MoodPill.ID> = []
    /// Listening Stats' Top 10 Songs/Artists — collapsed by default (real
    /// report), shown via an explicit "Show More…".
    @State private var showTopLists = false
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

                if !appState.recentlyPlayed.isEmpty {
                    cardRow(title: "Jump Back In", rows: appState.recentlyPlayed)
                }
                // "Recently Added" removed at the user's request — it duplicated "Jump Back In"
                // in practice and wasn't used. `appState.recentlyAdded` is left in place (still
                // populated by `reload()`) in case another surface wants it later.
                statsCard(appState.listeningStats)
                favorites

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
                //
                // Fixed `minHeight` on all three branches (loading/not-ready/
                // ready) — real report: the page must not re-layout when this
                // section resolves from "checking" to either outcome.
                //
                // Moved to last, below Favorites, at the user's request.
                Group {
                    if moodReady == true, let moodModel {
                        MoodEntryPointSection(
                            moodModel: moodModel,
                            selectedPillIDs: $selectedPillIDs,
                            eraVibePills: eraVibePills,
                            promptDraft: $promptDraft,
                            placeholderIndex: placeholderIndex,
                            selectedTrackForDetail: $selectedTrackForDetail,
                            showIndexStatus: $showIndexStatus)
                    } else if moodReady == false {
                        moodNotReadyView
                    } else {
                        moodEntryPointLoading
                    }
                }
                .frame(minHeight: Self.moodSectionMinHeight, alignment: .top)
                .padding(.top, 26)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 160)
        }
        .foregroundStyle(Palette.ink)
        .task {
            await appState.reload()
            await prepareMoodModel()
            moodModel?.setMatchingReferenceTrackID(
                player.currentTrack?.id, enabled: player.currentTrack?.id != nil)
            await refreshMoodReadiness()
        }
        .onChange(of: player.currentTrack?.id) { _, trackID in
            moodModel?.setMatchingReferenceTrackID(trackID, enabled: trackID != nil)
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
        .sheet(isPresented: $showIndexStatus, onDismiss: {
            // Real report: going to Sound Index, doing something there, then
            // returning to Listen must re-check readiness — this view's
            // state (and `moodReady`) survives the sheet dismissal, so
            // without this the mood section would keep showing whatever it
            // decided before the trip.
            Task { await refreshMoodReadiness() }
        }) {
            IndexStatusView(model: indexStatusModel)
        }
    }

    /// Real report: the section only reserved space for the baseline prompt/
    /// pills/Play controls, not the results row that appears once a search
    /// actually returns something — so running a search still bumped
    /// everything below it down the page. Baseline controls (~142) plus the
    /// results row's own height (~160, matching `RecentCard`'s 132pt
    /// artwork + two text lines + spacing) reserved unconditionally, whether
    /// or not results are showing right now. (Was ~200 with a Play/"Shake it
    /// up" button row — removed at the user's request, "I don't use these
    /// buttons," reclaiming that ~58pt rather than leaving dead space.)
    private static let moodControlsMinHeight: CGFloat = 142
    /// `fileprivate` (not `private`) — `MoodEntryPointSection` below, a
    /// separate type in this same file, reads it too.
    fileprivate static let moodResultsAreaMinHeight: CGFloat = 160
    private static let moodSectionMinHeight: CGFloat = moodControlsMinHeight + 14 + moodResultsAreaMinHeight

    /// Real, current readiness — not assumed: the CLAP model must actually be
    /// downloaded AND at least one track must actually be indexed, or a mood
    /// query can never return anything (CLAUDE.md "no silent/magic
    /// background work" — don't show a UI implying mood search works when it
    /// structurally can't yet).
    private func refreshMoodReadiness() async {
        guard let snapshot = await DiscoveryRuntimeController.shared.statusSnapshot() else {
            moodReady = false
            return
        }
        moodReady = snapshot.modelResourceAvailable && snapshot.coverage.complete > 0
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

    /// Shown only during the brief window before `prepareMoodModel()`/
    /// `refreshMoodReadiness()` resolve (mirrors `DiscoverySearchView`'s
    /// "Preparing search…" state).
    private var moodEntryPointLoading: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "What's the mood?")
            ProgressView()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 14)
        }
    }

    /// Shown instead of the prompt/pills/Play UI when the CLAP model isn't
    /// downloaded yet or nothing is indexed yet — real report: showing the
    /// normal controls, all permanently disabled, with small inline
    /// "Download models"/"Sound-index status" buttons underneath, read as
    /// broken rather than "not ready yet." One clear sentence and one action,
    /// styled like the real Play button so it reads as the equivalent, real
    /// next step rather than a demoted afterthought.
    private var moodNotReadyView: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "What's the mood?")
            Text("Once you download the mood models and index your tracks, "
                + "you can come back and search by mood here.")
                .font(.system(size: 13))
                .foregroundStyle(Palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                showIndexStatus = true
            } label: {
                Label("Index your tracks", systemImage: "waveform.badge.magnifyingglass")
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
            .accessibilityIdentifier("listen.mood.indexYourTracks")
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
                    Button("Show Less") { withAnimation { showTopLists = false } }
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Palette.brass)
                        .accessibilityIdentifier("listen.stats.showLess")
                } else {
                    Button("Show More…") { withAnimation { showTopLists = true } }
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Palette.brass)
                        .accessibilityIdentifier("listen.stats.showMore")
                }
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
    /// Shared with `ListenView` — the same sheet the top-level readiness
    /// gate uses, so there's one "open Sound Index" trigger for this whole
    /// screen, not two independent ones.
    @Binding var showIndexStatus: Bool

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

            if moodModel.matchingReferenceTrackID != nil {
                Toggle("DJ-compatible tracks", isOn: Binding(
                    get: { moodModel.matchingTracksOnly },
                    set: { moodModel.setMatchingTracksOnly($0) }))
                    .font(.system(size: 12.5, weight: .medium))
                    .tint(Palette.brass)
                    .accessibilityIdentifier("listen.mood.matchingTracks")
            }

            Group {
                if !moodModel.results.isEmpty {
                    moodResultsRow
                } else {
                    moodStatusHint
                }
            }
            .frame(minHeight: ListenView.moodResultsAreaMinHeight, alignment: .top)
        }
        .task {
            // Real report: "to prevent nothing showing on default... by
            // default select something like calm so we are guaranteed to
            // have results there when it loads." Runs once per appearance
            // of this section (ready + moodModel just became available) —
            // only when nothing is selected yet, so it never overrides a
            // choice the person already made.
            guard selectedPillIDs.isEmpty, moodModel.positiveRefinements.isEmpty else { return }
            if let calm = MoodPillTaxonomy.energy.first(where: { $0.id == "calm" }) {
                selectedPillIDs = [calm.id]
                moodModel.addMoreLike(calm.queryTerm)
            }
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
            hint(moodModel.matchingTracksOnly
                ? "No DJ-compatible tracks matched this mood. Turn off DJ-compatible tracks or try different pills."
                : "No tracks matched that mood yet. Try different pills or fewer of them.")
        case .emptyLibrary:
            hint("Your library is empty. Add music to try a mood.")
        case .emptyScope, .sourceUnavailable:
            hint("That source isn't available right now.")
        case .searchFailed:
            VStack(alignment: .leading, spacing: 8) {
                hint("Something went wrong running that search.")
                Button("Retry") { moodModel.retry() }.buttonStyle(.bordered)
            }
        case .matchingReferenceUnavailable:
            hint("DJ-compatible mood results need BPM and key analysis for the current track.")
        case .validationError, .analyzeReference, .staleSuppressed, .results:
            EmptyView()
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(Palette.ink3)
            .frame(maxWidth: .infinity, alignment: .leading)
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
            Text(row.artist?.name ?? row.album?.artist ?? (row.asset?.kind == .remote ? PlaybackDisplayPolicy.providerName(for: row.source) : "On device"))
                .font(.system(size: 11))
                .foregroundStyle(Palette.ink3)
                .lineLimit(1)
                .padding(.top, 1)
        }
        .frame(width: 132)
    }
}
