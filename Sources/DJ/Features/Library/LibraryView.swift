import SwiftUI
import UniformTypeIdentifiers

/// Bare library list (spec §41.2, mockup `ipad/02-library.html`): the track
/// table with title/artist/album/BPM/key/analysis status, a single search field,
/// and an "Add music" folder importer. Remote providers, crates and the analysis
/// health cards arrive in later milestones. Vibe Search is reachable from the
/// toolbar ("Find by feel") and per-track "More like this" (audio-to-audio,
/// FR-SEM-7) — both free.
public struct LibraryView: View {
    @StateObject private var model: LibraryModel
    @State private var showFolderImporter = false
    @State private var showImportSummary = false
    @State private var vibeDestination: VibeDestination?
    @State private var vibeModel: VibeSearchModel?
    @State private var showPlaylistBrief = false
    @State private var playlistModel: AutoPlaylistModel?

    /// Where a Vibe Search navigation lands: a fresh query, or audio-to-audio
    /// seeded by a track row.
    public enum VibeDestination: Hashable {
        case fresh
        case moreLike(Int64)
    }

    public init(store: DJLibraryStore = .shared) {
        _model = StateObject(wrappedValue: LibraryModel(store: store))
    }

    public var body: some View {
        NavigationStack {
            Group {
                if model.rows.isEmpty {
                    ContentUnavailableView {
                        Label("No music yet", systemImage: "music.note.list")
                    } description: {
                        Text("Add a folder to start building your library.")
                    } actions: {
                        Button("Add music") { showFolderImporter = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    List(model.filteredRows) { row in
                        LibraryTrackRowView(row: row)
                            .contextMenu {
                                Button {
                                    openVibeSearch(.moreLike(row.id))
                                } label: {
                                    Label("More like this", systemImage: "sparkle.magnifyingglass")
                                }
                            }
                    }
                    .listStyle(.inset)
                }
            }
            .navigationTitle("Music")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        openPlaylistBrief()
                    } label: {
                        Label("Make a playlist", systemImage: "wand.and.stars")
                    }
                    .accessibilityLabel("Make a playlist")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        openVibeSearch(.fresh)
                    } label: {
                        Label("Find by feel", systemImage: "sparkle.magnifyingglass")
                    }
                    .accessibilityLabel("Find by feel")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showFolderImporter = true
                    } label: {
                        Label("Add music", systemImage: "plus")
                    }
                    .accessibilityLabel("Add music")
                }
            }
            .searchable(text: $model.searchText, prompt: "Search titles and artists")
            .fileImporter(isPresented: $showFolderImporter,
                          allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result {
                    Task { await model.importFolder(url) }
                }
            }
            .onChange(of: model.lastImport) { _, _ in
                if model.lastImport != nil { showImportSummary = true }
            }
            .alert("Import finished", isPresented: $showImportSummary,
                   presenting: model.lastImport) { _ in
                Button("OK", role: .cancel) {}
            } message: { summary in
                Text("Added \(summary.added) tracks. Skipped \(summary.skipped).")
            }
            .navigationDestination(item: $vibeDestination) { destination in
                if let vibeModel {
                    VibeSearchView(model: vibeModel)
                }
            }
            .sheet(isPresented: $showPlaylistBrief) {
                if let playlistModel {
                    NavigationStack {
                        PlaylistBriefView(model: playlistModel)
                    }
                }
            }
            .task { model.start() }
            .onDisappear { model.stop() }
        }
    }

    /// Lazily assemble the auto-playlist stack on first use; a missing store is
    /// an honest absence and simply leaves the entry point inert.
    private func openPlaylistBrief() {
        if playlistModel == nil {
            playlistModel = AutoPlaylistAssembly.makeModel(pool: model.store.pool)
        }
        showPlaylistBrief = playlistModel != nil
    }

    /// Lazily assemble the search stack on first use; a missing store is an
    /// honest absence (FR-SEM-6) and simply leaves the entry points inert.
    private func openVibeSearch(_ destination: VibeDestination) {
        if vibeModel == nil {
            vibeModel = VibeSearchAssembly.makeModel(pool: model.store.pool)
        }
        guard let vibeModel else { return }
        vibeDestination = destination
        if case .moreLike(let trackID) = destination {
            Task { await vibeModel.searchSimilar(to: trackID) }
        }
    }
}

private struct LibraryTrackRowView: View {
    let row: DJTrackRow

    var body: some View {
        HStack(spacing: 12) {
            Text(row.title)
                .font(.system(size: 14, weight: .medium))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(row.artistNames)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 150, alignment: .leading)
            Text(row.albumTitle ?? "—")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 130, alignment: .leading)
            Text(bpmText)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
            Text(row.camelot ?? "—")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
            Text(row.analysisState)
                .font(.system(size: 12))
                .foregroundStyle(analysisColor)
                .frame(width: 76, alignment: .trailing)
        }
        .padding(.vertical, 2)
    }

    private var bpmText: String {
        guard let bpm = row.bpm else { return "—" }
        return String(format: "%.1f", bpm)
    }

    private var analysisColor: Color {
        row.analysisState == "ready" ? .green : .orange
    }
}
