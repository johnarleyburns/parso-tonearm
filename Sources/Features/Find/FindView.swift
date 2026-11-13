import SwiftUI
import TonearmCore
import TonearmDiscovery

/// Search and discovery surface. My Music intentionally remains a browsing
/// surface; all text, mix, and sound search controls live here.
struct FindView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var player: AudioPlayer
    @State private var mode: MyMusicSearchMode = .all
    @State private var browseMode: LibraryBrowseMode = FindResultScopePolicy.initialMode
    @State private var bpmPreset: MixBPMPreset?
    @State private var mixKey: String?
    @State private var soundSearchRows: [TrackRow]?
    @State private var soundSearchRevision = 0
    @State private var queryFocused = false

    // Reduced from 320 — a tall header (BPM/Key's two chip rows) plus a 320pt floor could still
    // exceed a small device's available content height even once the header itself can compress
    // (see the `.fixedSize` removal below). This floor only needs to keep the empty/placeholder
    // state from looking cramped; it doesn't need to match LibraryView's own internal minimum
    // (LibraryView.contentAreaMinHeight), which lives inside LibraryView's own ScrollView and so
    // can never itself force this screen to overflow.
    static let contentMinHeight: CGFloat = 160

    private var filter: MyMusicFilter {
        guard mode == .mix else { return .init() }
        return MyMusicFilter(
            mixBPM: bpmPreset.map { ($0.range.lowerBound + $0.range.upperBound) / 2 },
            mixBPMRange: bpmPreset?.range,
            mixKey: mixKey)
    }

    private var hasSearchInput: Bool {
        switch mode {
        case .all: LibrarySearchPolicy.shouldSearch(appState.searchText)
        case .mix: bpmPreset != nil || mixKey != nil
        case .sound: soundSearchRows != nil
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        MyMusicSearchControls(mode: $mode, bpmPreset: $bpmPreset,
                                              mixKey: $mixKey,
                                              onSoundRows: { rows in
                                                  soundSearchRows = rows
                                                  soundSearchRevision &+= 1
                                              },
                                              isQueryFocused: $queryFocused)
                        findScopePicker
                    }

                Group {
                if hasSearchInput {
                LibraryView(ownsNavigationStack: false,
                            externalMode: $browseMode,
                            filter: filter,
                            searchRows: mode == .sound ? soundSearchRows : nil,
                            searchRowsRevision: soundSearchRevision,
                            showsSearchField: false,
                            showsHeader: false)
                    .accessibilityIdentifier("find.results")
                } else {
                    Text("Search your music to see results.")
                        .font(Typography.callout)
                        .foregroundStyle(Palette.inkSecondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityIdentifier("find.awaitingQuery")
                }
                }
                .frame(minHeight: Self.contentMinHeight, alignment: .top)
            }
            .background(Palette.libraryBackground.ignoresSafeArea())
            .navigationTitle("Find")
            .largeNavigationTitle()
            .hiddenNavigationBar(when: queryFocused && mode != .mix)
            .rootTabChrome(.find)
        }
        .onChange(of: queryFocused) { _, focused in
            appState.findQueryFocused = focused
        }
        .onChange(of: appState.tab) { _, tab in
            if tab != .find { queryFocused = false }
        }
        .onChange(of: appState.showNowPlaying) { _, showing in
            if showing { queryFocused = false }
        }
        .onDisappear {
            queryFocused = false
            appState.findQueryFocused = false
        }
        .task(id: appState.didLoadLibraryOnce) {
            guard appState.didLoadLibraryOnce else { return }
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
                    .accessibilityValue(selected ? "selected" : "not selected")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.top, 4)
        .padding(.bottom, 8)
        .accessibilityIdentifier("find.scope")
    }
}
