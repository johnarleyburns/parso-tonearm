import SwiftUI
import UniformTypeIdentifiers

/// Bare library list (spec §41.2, mockup `ipad/02-library.html`): the track
/// table with title/artist/album/BPM/key/analysis status, a single search field,
/// and an "Add music" folder importer. Remote providers, crates and the analysis
/// health cards arrive in later milestones.
public struct LibraryView: View {
    @StateObject private var model: LibraryModel
    @State private var showFolderImporter = false
    @State private var showImportSummary = false

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
                    }
                    .listStyle(.inset)
                }
            }
            .navigationTitle("Music")
            .toolbar {
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
            .task { model.start() }
            .onDisappear { model.stop() }
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
