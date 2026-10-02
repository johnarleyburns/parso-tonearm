import SwiftUI
import TonearmCore
import TonearmDiscovery

enum MyMusicSearchMode: String, CaseIterable, Identifiable {
    case all = "All"
    case mix = "Search by Mix"
    case sound = "Search by Sound"

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

    @State private var soundModel: DiscoverySearchViewModel?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Search", selection: $mode) {
                ForEach(MyMusicSearchMode.allCases) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("mymusic.search.mode")

            switch mode {
            case .all:
                // Plain text search by title, artist, album and the other general fields. The
                // library list below doesn't show its own field inside My Music, so this is it.
                // On Mac the same search lives in the window toolbar (⌘F).
                #if os(iOS)
                SearchField(text: $appState.searchText, placeholder: "Search all your music…")
                    .accessibilityIdentifier("mymusic.search.text")
                #else
                EmptyView()
                #endif
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
                soundModel = model
            }
        }
        .onChange(of: mode) { _, newMode in
            // The text field only exists in All; a query left behind would keep filtering
            // the list with nothing on screen to show or clear it.
            if newMode != .all { appState.searchText = "" }
            if newMode != .mix {
                bpmPreset = nil
                mixKey = nil
            }
            if newMode != .sound {
                onSoundRows(nil)
            }
        }
    }

    private var mixControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Mix BPM")
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

            Text("Mix Key")
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
            HStack(spacing: 8) {
                Image(systemName: "waveform.and.magnifyingglass")
                    .foregroundStyle(Palette.accent)
                TextField("Describe a sound, e.g. warm analog pads", text: $model.searchText)
                    .platformAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityLabel("Search by sound")
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .glassSurface(cornerRadius: 20)

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
