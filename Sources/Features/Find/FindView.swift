import SwiftUI
import TonearmCore
import TonearmDiscovery

/// Search and discovery surface. My Music intentionally remains a browsing
/// surface; all text, mix, and sound search controls live here.
struct FindView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var player: AudioPlayer
    @State private var mode: MyMusicSearchMode = .all
    @State private var browseMode: LibraryBrowseMode = .artists
    @State private var bpmPreset: MixBPMPreset?
    @State private var mixKey: String?
    @State private var soundSearchRows: [TrackRow]?
    @State private var soundSearchRevision = 0

    private var filter: MyMusicFilter {
        guard mode == .mix else { return .init() }
        return MyMusicFilter(
            mixBPM: bpmPreset.map { ($0.range.lowerBound + $0.range.upperBound) / 2 },
            mixBPMRange: bpmPreset?.range,
            mixKey: mixKey)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        ScreenHeader(title: "Find", showAdd: false)
                        MyMusicSearchControls(mode: $mode, bpmPreset: $bpmPreset,
                                              mixKey: $mixKey,
                                              onSoundRows: { rows in
                                                  soundSearchRows = rows
                                                  soundSearchRevision &+= 1
                                              })
                        findScopePicker
                    }
                }
                .frame(maxHeight: 170)

                LibraryView(ownsNavigationStack: false,
                            externalMode: $browseMode,
                            filter: filter,
                            searchRows: mode == .sound ? soundSearchRows : nil,
                            searchRowsRevision: soundSearchRevision,
                            showsSearchField: false,
                            showsHeader: false)
                    .accessibilityIdentifier("find.results")
            }
            .background(Palette.libraryBackground.ignoresSafeArea())
            .hiddenNavigationBar()
        }
        .task {
            await appState.reload()
        }
    }

    private var findScopePicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(LibraryBrowseMode.allCases) { candidate in
                    let selected = candidate == browseMode
                    Button { browseMode = candidate } label: {
                        Text(candidate.title)
                            .font(Typography.callout)
                            .foregroundStyle(selected ? Palette.accentOnFill : Palette.inkSecondary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(selected ? Palette.accent : Palette.ink.opacity(0.07),
                                        in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("find.scope.\(candidate.rawValue.lowercased())")
                }
            }
            .padding(.horizontal, 18)
        }
        .padding(.top, 4)
        .padding(.bottom, 8)
        .accessibilityIdentifier("find.scope")
    }
}
