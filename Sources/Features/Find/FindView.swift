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
    @State private var savedBlends: [BlendDocument] = []
    @State private var selectedBlend: BlendDocument?

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
                                              })
                        findScopePicker
                    }
                    .fixedSize(horizontal: false, vertical: true)

                if mode == .all, !blendResults.isEmpty {
                    blendResultsSection
                }
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
            .background(Palette.libraryBackground.ignoresSafeArea())
            .navigationTitle("Find")
            .largeNavigationTitle()
        }
        .sheet(item: $selectedBlend) { blend in
            BlendDetailView(blend: blend)
        }
        .task(id: appState.searchText) {
            guard LibrarySearchPolicy.shouldSearch(appState.searchText) else { return }
            savedBlends = await appState.blendRepository.load().blends
        }
        .task(id: appState.didLoadLibraryOnce) {
            guard appState.didLoadLibraryOnce else { return }
            await appState.reload()
        }
    }

    private var blendResults: [FindBlendSearch.Result] {
        FindBlendSearch.results(query: appState.searchText, saved: savedBlends)
    }

    /// Saved and starter blends matching the query. Selecting never touches
    /// the library: saved blends open detail, starter blends play.
    private var blendResultsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Blends")
            ForEach(blendResults) { result in
                switch result {
                case .saved(let blend):
                    Button { selectedBlend = blend } label: {
                        blendRow(title: blend.title, kind: "Saved blend",
                                 detail: "\(blend.occurrences.count) tracks")
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("find.blend.saved")
                case .starter(let blend):
                    Button { Task { await appState.starterBlends.play(blend) } } label: {
                        blendRow(title: blend.title, kind: "Starter blend", detail: blend.summary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Plays this starter blend")
                    .accessibilityIdentifier("find.blend.\(blend.id)")
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 8)
        .accessibilityIdentifier("find.blends")
    }

    private func blendRow(title: String, kind: LocalizedStringKey, detail: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Typography.callout).foregroundStyle(Palette.ink)
                Text(detail).font(Typography.caption).foregroundStyle(Palette.inkSecondary)
            }
            Spacer(minLength: 8)
            Text(kind).font(Typography.caption).foregroundStyle(Palette.inkSecondary)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
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
