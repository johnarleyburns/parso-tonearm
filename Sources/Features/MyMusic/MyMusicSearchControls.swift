import SwiftUI
import TonearmCore
import TonearmDiscovery

enum MyMusicSearchMode: String, CaseIterable, Identifiable {
    case all = "By Name"
    case sound = "By Mood"
    case mix = "By BPM/Key"

    var id: String { rawValue }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if mode != .mix { allSearchField }
            HStack(spacing: 8) {
                ForEach(MyMusicSearchMode.allCases) { option in
                    Button { mode = option } label: {
                        Text(option.rawValue)
                            .font(Typography.callout)
                            .foregroundStyle(mode == option ? Palette.accentOnFill : Palette.inkSecondary)
                            .padding(.horizontal, 16).padding(.vertical, 8)
                            .background(mode == option ? Palette.accent : Palette.ink.opacity(0.07), in: Capsule())
                    }.buttonStyle(.plain)
                        .accessibilityIdentifier("find.mode.\(option == .all ? "all" : option == .sound ? "mood" : "mix")")
                }
            }
            .accessibilityIdentifier("mymusic.search.mode")

            switch mode {
            case .all:
                EmptyView()
            case .mix:
                mixControls
            case .sound:
                if let soundModel {
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
                onSoundRows(nil)
                return
            }
            if soundModel == nil {
                let model = await DiscoveryRuntimeController.shared.makeSearchViewModel(
                    appState: appState, player: player)
                model.inputMode = .findBySound
                model.searchText = appState.searchText
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
