import SwiftUI
import TonearmCore

enum MyMusicSearchMode: String, CaseIterable, Identifiable {
    case all = "Name"
    case mix = "BPM/Key"

    var id: String { rawValue }

    var identifier: String {
        switch self {
        case .all: "find.mode.all"
        case .mix: "find.mode.mix"
        }
    }

    /// The collapsed toolbar menu (`FindModeMenu` in `FindView.swift`) shows only this icon,
    /// not the label — "Name"/"BPM/Key" text appears only inside the open menu's options.
    var icon: String {
        switch self {
        case .all: "textformat"
        case .mix: "metronome"
        }
    }
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
    @Binding var mode: MyMusicSearchMode
    @Binding var bpmPreset: MixBPMPreset?
    @Binding var mixKey: String?
    /// Mirrors keyboard focus of the query field (Name only).
    var isQueryFocused: Binding<Bool> = .constant(false)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if mode == .all { allSearchField }

            switch mode {
            case .all:
                EmptyView()
            case .mix:
                mixControls
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .foregroundStyle(Palette.ink)
        .onChange(of: mode) { _, newMode in
            // The single top text field exists in Name only; BPM/Key has no
            // free-text input, so a query left behind would filter with
            // nothing to clear it.
            if newMode == .mix {
                appState.searchText = ""
                isQueryFocused.wrappedValue = false
                return
            }
            bpmPreset = nil
            mixKey = nil
        }
    }

    @ViewBuilder
    private var allSearchField: some View {
        // Plain text search by title, artist, album and the other general fields. The
        // library list below doesn't show its own field inside My Music, so this is it.
        // On Mac the same search lives in the window toolbar (⌘F).
        #if os(iOS)
        SearchField(text: $appState.searchText, placeholder: "Search all your music…",
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
