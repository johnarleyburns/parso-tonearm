import SwiftUI
import TonearmCore
import TonearmDiscovery

enum MyMusicSearchMode: String, CaseIterable, Identifiable {
    case all = "Name"
    case sound = "Mood"
    case mix = "BPM/Key"

    var id: String { rawValue }

    var identifier: String {
        switch self {
        case .all: "find.mode.all"
        case .sound: "find.mode.mood"
        case .mix: "find.mode.mix"
        }
    }
}

/// Host-testable layout decision for the Find mode selector.
enum FindModeSelectorLayoutPolicy {
    /// Accessibility text sizes never attempt a single row; all modes are stacked.
    static func alwaysStacked(isAccessibilitySize: Bool) -> Bool { isAccessibilitySize }
}

enum MixBPMPreset: String, CaseIterable, Identifiable {
    case ambient = "Ambient"
    case hipHop = "Hip-hop"
    case rAndB = "R&B"
    case house = "House"
    case techno = "Techno"
    case trance = "Trance"
    case drumAndBass = "Drum & Bass"

    var id: String { rawValue }

    var range: ClosedRange<Double> {
        switch self {
        case .ambient: 60...90
        case .hipHop: 80...110
        case .rAndB: 70...110
        case .house: 120...130
        case .techno: 125...140
        case .trance: 130...145
        case .drumAndBass: 160...180
        }
    }

    var label: String {
        "\(rawValue): \(Int(range.lowerBound))–\(Int(range.upperBound))"
    }
}

enum CamelotSelector {
    static let keys: [String] = (1...12).flatMap { number in
        ["\(number)A", "\(number)B"]
    }
}

struct MyMusicSearchControls: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var player: AudioPlayer
    @Binding var mode: MyMusicSearchMode
    @Binding var bpmPreset: MixBPMPreset?
    @Binding var mixKey: String?
    let onSoundRows: ([TrackRow]?) -> Void
    /// Mirrors keyboard focus of the query field (By Name / By Mood only).
    var isQueryFocused: Binding<Bool> = .constant(false)

    @State private var soundModel: DiscoverySearchViewModel?
    /// Mirrors the standalone Mood tab's pill selection (`MoodEntryPointSection` in
    /// ListenView.swift) so Find's own Mood mode behaves identically: pills combine additively
    /// into `soundModel.positiveRefinements`, never replace it.
    @State private var selectedMoodPillIDs: Set<MoodPill.ID> = []
    @State private var eraVibePills: [MoodPill] = []
    @State private var genres: [String] = []

    /// A to Z, so a mood is easy to find — same ordering as the standalone Mood tab.
    private var allMoodPills: [MoodPill] {
        (MoodPillTaxonomy.fixedCategories + eraVibePills)
            .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }

    private var genrePills: [MoodPill] {
        genres.map { MoodPill(id: $0, label: JamendoGenreTree.humanizedGenre($0), queryTerm: $0) }
    }

    private func moodPillSelectionBinding(_ model: DiscoverySearchViewModel) -> Binding<Set<MoodPill.ID>> {
        Binding(
            get: { selectedMoodPillIDs },
            set: { newSelection in
                let pills = allMoodPills
                for id in newSelection.subtracting(selectedMoodPillIDs) {
                    if let pill = pills.first(where: { $0.id == id }) { model.addMoreLike(pill.queryTerm) }
                }
                for id in selectedMoodPillIDs.subtracting(newSelection) {
                    if let pill = pills.first(where: { $0.id == id }) { model.removeMoreLike(pill.queryTerm) }
                }
                selectedMoodPillIDs = newSelection
            })
    }

    private func genreSelectionBinding(_ model: DiscoverySearchViewModel) -> Binding<Set<MoodPill.ID>> {
        Binding(get: { model.genres }, set: { model.genres = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if mode != .mix { allSearchField }
            modeSelector

            switch mode {
            case .all:
                EmptyView()
            case .mix:
                mixControls
            case .sound:
                if let soundModel {
                    MoodPillPicker(pills: allMoodPills, selection: moodPillSelectionBinding(soundModel),
                                  kind: "find.mood")
                    if !genrePills.isEmpty {
                        MoodPillPicker(pills: genrePills, selection: genreSelectionBinding(soundModel),
                                      kind: "find.genre")
                    }
                    MyMusicSoundQuery(model: soundModel, onRows: onSoundRows)
                } else {
                    ProgressView("Preparing sound search…")
                        .font(Typography.caption)
                        .tint(Palette.accent)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .foregroundStyle(Palette.ink)
        .task(id: mode) {
            guard mode == .sound else {
                soundModel = nil
                selectedMoodPillIDs = []
                onSoundRows(nil)
                return
            }
            if soundModel == nil {
                let model = await DiscoveryRuntimeController.shared.makeSearchViewModel(
                    appState: appState, player: player)
                model.inputMode = .findBySound
                model.searchText = appState.searchText
                let summary = await SuggestionChips.summary(library: appState.store)
                eraVibePills = SuggestionChips.seed(from: summary).map { chip in
                    MoodPill(id: chip, label: chip, queryTerm: chip)
                }
                genres = (try? await appState.store.genres()) ?? []
                // Real report (Mood tab): a greyed-out Play button with no explanation when
                // nothing was selected yet. Same fix here — default to "calm" so Mood search in
                // Find is never empty on first entry, exactly like the standalone Mood tab.
                if selectedMoodPillIDs.isEmpty, model.positiveRefinements.isEmpty,
                   let calm = MoodPillTaxonomy.energy.first(where: { $0.id == "calm" }) {
                    selectedMoodPillIDs = [calm.id]
                    model.addMoreLike(calm.queryTerm)
                }
                let trackID = player.currentTrack?.id
                model.setMatchingReferenceTrackID(trackID, enabled: isReadyForMatching(trackID))
                soundModel = model
            }
        }
        .onChange(of: mode) { _, newMode in
            // The single top text field exists in By Name and By Mood only; By BPM/Key has no
            // free-text input, so a query left behind would filter with nothing to clear it.
            if newMode == .mix {
                appState.searchText = ""
                isQueryFocused.wrappedValue = false
            }
            if newMode != .mix {
                bpmPreset = nil
                mixKey = nil
            }
            if newMode != .sound {
                onSoundRows(nil)
            }
        }
        .onChange(of: appState.searchText) { _, text in
            // One text box: the top field's keystrokes also drive the mood search.
            if mode == .sound, let soundModel, soundModel.searchText != text {
                soundModel.searchText = text
            }
        }
        // Same graceful degrade the standalone Mood tab uses (MoodView.isReadyForMatching):
        // mix-compatible ordering against the currently-playing track is attempted only once
        // that track's own BPM/camelot analysis has actually finished, never hard-blocked the
        // way Find's explicit "More like this" similar-track mode intentionally still is.
        .onChange(of: player.currentTrack?.id) { _, trackID in
            soundModel?.setMatchingReferenceTrackID(trackID, enabled: isReadyForMatching(trackID))
        }
        .onChange(of: appState.musicalInfoRevision) { _, _ in
            let trackID = player.currentTrack?.id
            soundModel?.setMatchingReferenceTrackID(trackID, enabled: isReadyForMatching(trackID))
        }
    }

    /// Real report (Mood tab): mix-compatible matching auto-enabled against whatever track
    /// happened to be loaded, with no check it was actually analyzed yet, constantly hitting
    /// `SearchService`'s intentional hard block (`.matchingReferenceUnavailable`) in practice —
    /// a reference track's BPM/camelot analysis is a background job racing everything else.
    /// Checking readiness first means Find's Mood mode just shows plain semantic results
    /// instead of blocking; mix-compatible ordering kicks in automatically once analysis lands.
    private func isReadyForMatching(_ trackID: Int64?) -> Bool {
        guard let trackID, let info = appState.musicalInfo[trackID] else { return false }
        return info.bpm != nil && info.camelotKey != nil
    }

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private func modeButton(_ option: MyMusicSearchMode) -> some View {
        Button { mode = option } label: {
            Text(option.rawValue)
                .font(Typography.callout)
                .foregroundStyle(mode == option ? Palette.accentOnFill : Palette.inkSecondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 16).padding(.vertical, 8)
                .frame(minHeight: 44)
                .background(mode == option ? Palette.accent : Palette.ink.opacity(0.07), in: Capsule())
                .contentShape(Capsule())
        }.buttonStyle(.plain)
            .accessibilityAddTraits(mode == option ? .isSelected : [])
            .accessibilityIdentifier(option.identifier)
    }

    /// Single row when it fits; otherwise stacked, so every mode stays visible and tappable.
    private var modeSelector: some View {
        Group {
            if FindModeSelectorLayoutPolicy.alwaysStacked(isAccessibilitySize: dynamicTypeSize.isAccessibilitySize) {
                stackedModes
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { ForEach(MyMusicSearchMode.allCases) { modeButton($0) } }
                    stackedModes
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("mymusic.search.mode")
    }

    private var stackedModes: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(MyMusicSearchMode.allCases) { modeButton($0) }
        }
    }

    @ViewBuilder
    private var allSearchField: some View {
        // Plain text search by title, artist, album and the other general fields. The
        // library list below doesn't show its own field inside My Music, so this is it.
        // On Mac the same search lives in the window toolbar (⌘F).
        #if os(iOS)
        SearchField(text: $appState.searchText, placeholder: mode == .sound ? "Describe a sound, e.g. warm analog pads" : "Search all your music…",
                    isFocused: isQueryFocused)
            .accessibilityIdentifier("mymusic.search.text")
        #else
        EmptyView()
        #endif
    }

    private var mixControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Track BPM")
                .font(Typography.caption)
                .foregroundStyle(Palette.inkTertiary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(MixBPMPreset.allCases) { preset in
                        chip(preset.label, selected: bpmPreset == preset) {
                            bpmPreset = bpmPreset == preset ? nil : preset
                        }
                    }
                }
            }
            .accessibilityIdentifier("mymusic.mix.bpm")

            Text("Camelot Key")
                .font(Typography.caption)
                .foregroundStyle(Palette.inkTertiary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(CamelotSelector.keys, id: \.self) { key in
                        chip(key, selected: mixKey == key) {
                            mixKey = mixKey == key ? nil : key
                        }
                    }
                }
            }
            .accessibilityIdentifier("mymusic.mix.key")
        }
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Typography.caption)
                .foregroundStyle(selected ? Palette.accentOnFill : Palette.inkSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(selected ? Palette.accent : Palette.ink.opacity(0.07),
                            in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct MyMusicSoundQuery: View {
    @ObservedObject var model: DiscoverySearchViewModel
    let onRows: ([TrackRow]?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch model.screen {
            case .loading:
                Label("Searching your library…", systemImage: "magnifyingglass")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.inkTertiary)
            case .results(let kind, let count, _):
                Text(kind == .semantic ? "\(count) sound results" : "\(count) matching results")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.inkTertiary)
            case .noMatches:
                Text("No sound matches")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.inkTertiary)
            case .modelMissing:
                Text("Sound search needs the on-device sound model.")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.inkTertiary)
            default:
                EmptyView()
            }
        }
        .onChange(of: model.screen) { _, _ in publishRows() }
        .onChange(of: model.results.map(\.trackID)) { _, _ in publishRows() }
        .onAppear { publishRows() }
    }

    private func publishRows() {
        switch model.screen {
        case .results:
            onRows(model.results.map(\.track))
        case .noMatches:
            onRows([])
        case .idle:
            onRows(nil)
        default:
            break
        }
    }
}
