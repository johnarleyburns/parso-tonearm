import SwiftUI
import TonearmCore

struct AddTracksToPlaylistSheet: View {
    let playlist: Playlist
    let onFinished: () async -> Void
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var filter = ""
    @State private var selected: Set<Int64> = []

    private var filteredTracks: [TrackRow] {
        let query = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return appState.allTracks }
        return appState.allTracks.filter {
            $0.track.title.lowercased().contains(query)
                || ($0.album?.title.lowercased().contains(query) ?? false)
                || ($0.album?.artist?.lowercased().contains(query) ?? false)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Capsule().fill(Color.white.opacity(0.35)).frame(width: 36, height: 5).padding(.top, 14)
            Text("Add to \(playlist.title)").font(.system(size: 19, weight: .bold)).padding(.vertical, 12)
            SearchField(text: $filter, placeholder: "Search all your music…")
                .padding(.horizontal, 20).padding(.bottom, 10)
            List(filteredTracks) { row in
                Button { toggle(row.id) } label: {
                    HStack(spacing: 11) {
                        Image(systemName: selected.contains(row.id) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selected.contains(row.id) ? Palette.brass : Palette.ink3)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.track.title).lineLimit(1)
                            Text(row.album?.artist ?? row.album?.title ?? "")
                                .font(.caption).foregroundStyle(Palette.ink3).lineLimit(1)
                        }
                        Spacer()
                    }.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("playlist.add.row.\(row.id)")
                .listRowBackground(Color.clear)
            }
            .listStyle(.plain).scrollContentBackground(.hidden)
            HStack {
                Text("\(selected.count) selected").font(.caption).foregroundStyle(Palette.ink2)
                Spacer()
                Button {
                    Task {
                        for row in appState.allTracks where selected.contains(row.id) {
                            await appState.addToPlaylist(row, playlist: playlist)
                        }
                        await onFinished()
                        dismiss()
                    }
                } label: {
                    Text(selected.isEmpty ? "Add tracks" : "Add \(selected.count) tracks")
                        .font(.system(size: 15, weight: .bold)).foregroundStyle(Color(hex: 0x221503))
                        .padding(.horizontal, 20).frame(height: 44)
                        .background(Palette.brass, in: Capsule())
                }
                .disabled(selected.isEmpty)
                .accessibilityIdentifier("playlist.add.confirm")
            }.padding(20)
        }
        .foregroundStyle(Palette.ink)
        .presentationDetents([.large])
        .presentationBackground(.ultraThinMaterial)
    }

    private func toggle(_ id: Int64) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }
}
