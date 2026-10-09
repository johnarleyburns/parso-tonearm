import SwiftUI
import TonearmCore
import TonearmDiscovery

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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ScreenHeader(title: "Listen", addAction: { showSettings = true },
                             addAccessibilityIdentifier: "listen.settings",
                             actionIcon: "gearshape.fill",
                             actionAccessibilityLabel: "Settings")
                if support.isSupporter {
                    supporterBadge
                        .padding(.top, 6)
                        .padding(.bottom, 10)
                } else {
                    Spacer().frame(height: 16)
                }

                cardRow(title: "Jump Back In", rows: appState.recentlyPlayed,
                        emptyMessage: "Your recently played music will appear here.", identifier: "listen.recent")
                favorites
                statsCard(appState.listeningStats)
                    .redacted(reason: appState.didLoadLibraryOnce ? [] : .placeholder)

            }
            .padding(.horizontal, 18)
            .padding(.bottom, 160)
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
                         emptyMessage: LocalizedStringKey, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: title)
            Group {
                if !appState.didLoadLibraryOnce {
                    HStack { ProgressView(); Text("Loading…") }
                        .accessibilityIdentifier(identifier == "listen.recent" ? "listen.loading" : "listen.favorites.loading")
                } else if rows.isEmpty {
                    Text(emptyMessage).font(Typography.callout).foregroundStyle(Palette.inkTertiary)
                } else {
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
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: collectionContentHeight, alignment: .topLeading)
        }
        .padding(.bottom, 20)
        .accessibilityIdentifier(identifier)
    }

    private var favorites: some View {
        cardRow(title: "Favorites", rows: appState.favoriteRows,
                emptyMessage: "Your favorite music will appear here.", identifier: "listen.favorites")
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

/// Dedicated mood discovery tab. This used to be appended to Listen, which
/// made the listening home page a long mixed-purpose feed and hid the mood
/// workflow below unrelated content.
struct MoodView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var player: AudioPlayer
    @State private var moodModel: DiscoverySearchViewModel?
    @State private var moodReady: Bool?
    @StateObject private var indexStatusModel = IndexStatusModel()
    @State private var showIndexStatus = false
    @State private var selectedPillIDs: Set<MoodPill.ID> = []
    @State private var eraVibePills: [MoodPill] = []
    @State private var promptDraft = ""
    @State private var selectedTrackForDetail: TrackRow?
    @State private var placeholderIndex = 0
    @State private var startingPlayback = false
    @State private var playbackMessage: String?

    fileprivate static let promptPlaceholders = [
        "sunday morning coffee", "focus, no vocals", "storm outside"
    ]
    fileprivate static let moodControlsMinHeight: CGFloat = 142
    fileprivate static let moodResultsAreaMinHeight: CGFloat = 160
    private static let moodSectionMinHeight = moodControlsMinHeight + 14 + moodResultsAreaMinHeight

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ScreenHeader(title: "Mood", showAdd: false)
                if let playbackMessage {
                    Text(playbackMessage).font(Typography.caption).foregroundStyle(Palette.inkSecondary)
                }
                Group {
                    if moodReady == true, let moodModel {
                        MoodEntryPointSection(
                            moodModel: moodModel,
                            selectedPillIDs: $selectedPillIDs,
                            eraVibePills: eraVibePills,
                            promptDraft: $promptDraft,
                            placeholderIndex: placeholderIndex,
                            selectedTrackForDetail: $selectedTrackForDetail,
                            showIndexStatus: $showIndexStatus,
                            startingPlayback: startingPlayback,
                            onPlay: { Task { await playMood() } })
                    } else if moodReady == false {
                        moodNotReadyView
                    } else {
                        VStack(alignment: .leading, spacing: 14) {
                            SectionHeader(title: "What's the mood?")
                            ProgressView()
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 14)
                        }
                    }
                }
                .frame(minHeight: Self.moodSectionMinHeight, alignment: .top)
                .padding(.top, 18)
                if moodReady != true || moodModel == nil {
                    MoodActionRow(canPlay: false, starting: false,
                                  canMakeMix: appState.didLoadLibraryOnce,
                                  onPlay: {}, onMakeMix: { appState.requestBuildAMix() })
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 160)
        }
        .foregroundStyle(Palette.ink)
        .task(id: appState.didLoadLibraryOnce) {
            guard appState.didLoadLibraryOnce else { return }
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
                Motion.perform(Motion.standard) {
                    placeholderIndex = (placeholderIndex + 1) % Self.promptPlaceholders.count
                }
            }
        }
        .trackDetailSheet(for: $selectedTrackForDetail)
        .sheet(isPresented: $showIndexStatus, onDismiss: {
            Task { await refreshMoodReadiness() }
        }) {
            IndexStatusView(model: indexStatusModel)
        }
    }

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

    private func playMood() async {
        guard let moodModel, !startingPlayback else { return }
        startingPlayback = true
        playbackMessage = nil
        defer { startingPlayback = false }
        var ids = moodModel.results.map(\.trackID)
        if let reference = moodModel.matchingReferenceTrackID { ids.append(reference) }
        let metadata = (try? await appState.store.djLoadTrackInfo(trackIds: ids)) ?? [:]
        if !moodModel.playMood(metadata: metadata, onPlayQueue: { tracks in
            player.play(tracks: tracks, startAt: 0, source: .library)
        }) {
            playbackMessage = String(localized: "No mix-compatible tracks for this mood yet. Index BPM and key, or choose another mood.")
        }
    }

    private func refreshMoodReadiness() async {
        guard let snapshot = await DiscoveryRuntimeController.shared.statusSnapshot() else {
            moodReady = false
            return
        }
        moodReady = snapshot.modelResourceAvailable && snapshot.coverage.complete > 0
    }

    private var moodNotReadyView: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "What's the mood?")
            Text("Once you download the mood models and index your tracks, you can come back and search by mood here.")
                .font(Typography.callout)
                .foregroundStyle(Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button { showIndexStatus = true } label: {
                Label("Index your tracks", systemImage: "waveform.badge.magnifyingglass")
                    .font(Typography.callout)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 11)
                    .background(Palette.accent, in: Capsule())
                    .foregroundStyle(Palette.ink)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("mood.indexYourTracks")
        }
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
    @EnvironmentObject private var appState: AppState
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
    let startingPlayback: Bool
    let onPlay: () -> Void

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

            TextField(MoodView.promptPlaceholders[placeholderIndex], text: promptBinding)
                .textFieldStyle(.plain)
                .font(Typography.callout)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .frame(height: 44)
                .glassSurface(cornerRadius: 12)
                .accessibilityIdentifier("mood.prompt")

            MoodPillPicker(pills: allMoodPills, selection: pillSelectionBinding)

            if moodModel.matchingReferenceTrackID != nil {
                Toggle("Mix-compatible tracks", isOn: Binding(
                    get: { moodModel.matchingTracksOnly },
                    set: { moodModel.setMatchingTracksOnly($0) }))
                    .font(Typography.callout)
                    .tint(Palette.accent)
                    .accessibilityIdentifier("mood.matchingTracks")
            }

            MoodActionRow(canPlay: !moodModel.results.isEmpty, starting: startingPlayback,
                          canMakeMix: appState.didLoadLibraryOnce, onPlay: onPlay) {
                if moodModel.results.isEmpty { appState.requestBuildAMix() }
                else {
                    appState.mixBuilderRequest = MixBuilderRequest(rows: moodModel.results.map(\.track), lockedFirst: nil)
                }
            }

            Group {
                if !moodModel.results.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        moodResultsRow
                    }
                } else {
                    moodStatusHint
                }
            }
            .frame(minHeight: MoodView.moodResultsAreaMinHeight, alignment: .top)
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
                Text("Searching…").foregroundStyle(Palette.inkTertiary)
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
                ? "No mix-compatible tracks matched this mood. Turn off Mix-compatible tracks or try different pills."
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
                hint("Mix-compatible mood results need BPM and key analysis for the current track.")
        case .validationError, .analyzeReference, .staleSuppressed, .results:
            EmptyView()
        }
    }

    private func hint(_ text: LocalizedStringKey) -> some View {
        Text(text).font(.callout).foregroundStyle(Palette.inkTertiary)
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

private struct MoodActionRow: View {
    let canPlay: Bool
    let starting: Bool
    let canMakeMix: Bool
    let onPlay: () -> Void
    let onMakeMix: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onPlay) {
                Label(starting ? "Starting…" : "Play", systemImage: "play.fill")
                    .frame(maxWidth: .infinity).frame(height: 44)
                    .background(Palette.accent, in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(Palette.accentOnFill)
            }
            .buttonStyle(.plain).disabled(starting || !canPlay)
            .accessibilityIdentifier("mood.play")
            Button(action: onMakeMix) {
                Label("Make a Mix", systemImage: "waveform.path.ecg")
                    .frame(maxWidth: .infinity).frame(height: 44)
                    .glassSurface(cornerRadius: 12)
            }
            .buttonStyle(.plain).disabled(!canMakeMix)
            .accessibilityIdentifier("mood.makeMix")
        }
        .font(Typography.callout)
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
