import SwiftUI
import TonearmCore

#if os(iOS)
/// Search-and-download sheet opened by the "+" button on My Music → On My Watch. Picking a track
/// asks once before queueing it; the On My Watch list then shows the transfer's live stage.
struct WatchAddMusicView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var pendingRow: TrackRow?

    private var results: [TrackRow] {
        let sorted = appState.allTracks.sorted {
            $0.track.title.localizedCaseInsensitiveCompare($1.track.title) == .orderedAscending
        }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return sorted }
        return sorted.filter { row in
            row.track.title.localizedCaseInsensitiveContains(trimmed)
                || (row.artist?.name.localizedCaseInsensitiveContains(trimmed) ?? false)
                || (row.album?.title.localizedCaseInsensitiveContains(trimmed) ?? false)
        }
    }

    var body: some View {
        NavigationStack {
            List(results) { row in
                Button { pendingRow = row } label: { rowLabel(row) }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("mymusic.watch.pick.\(row.id)")
            }
            .listStyle(.plain)
            .overlay {
                if results.isEmpty {
                    let title: LocalizedStringKey = query.isEmpty ? "No Music Found" : "No Matches"
                    ContentUnavailableView(
                        title,
                        systemImage: "music.note",
                        description: Text(query.isEmpty
                            ? "Import or add music, then download it to your watch."
                            : "Try a different title, artist, or album."))
                }
            }
            .navigationTitle("Add to Watch")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Search your music")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog("Download to watch?", isPresented: Binding(
                get: { pendingRow != nil },
                set: { if !$0 { pendingRow = nil } }), titleVisibility: .visible) {
                Button("Yes, download") {
                    guard let row = pendingRow else { return }
                    pendingRow = nil
                    Task {
                        await appState.downloadToWatch(rows: [row])
                        dismiss()
                    }
                }
                Button("Cancel", role: .cancel) { pendingRow = nil }
            } message: {
                if let row = pendingRow {
                    Text("“\(row.track.title)” will download to your Apple Watch.")
                }
            }
        }
        .accessibilityIdentifier("mymusic.watch.addSheet")
    }

    private func rowLabel(_ row: TrackRow) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.track.title).font(Typography.callout).lineLimit(1)
                let subtitle = [row.artist?.name, row.album?.title]
                    .compactMap { $0 }
                    .filter { !$0.isEmpty }
                    .joined(separator: " — ")
                if !subtitle.isEmpty {
                    Text(subtitle).font(Typography.caption)
                        .foregroundStyle(Palette.inkTertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            switch appState.watchGlyphState(for: row) {
            case .onWatch:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.accent)
            case .transferring:
                ProgressView()
            case .failed:
                Image(systemName: "arrow.clockwise.circle").foregroundStyle(Palette.danger)
            case .notOnWatch:
                Image(systemName: "plus.circle").foregroundStyle(Palette.accent)
            }
        }
        .contentShape(Rectangle())
    }
}

#endif
