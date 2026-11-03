import SwiftUI
import TonearmCore

/// Single-track picker for a deck's LOAD button, adapted from `AddTracksToPlaylistSheet`'s
/// structure (flat filtered list, no sectioned Artist/Album/Song/Genre browsing — overkill for
/// "pick one track right now") but stripped to single selection and laid out for landscape.
struct DeckLoadSheet: View {
    let onPick: (TrackRow) -> Void
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var filter = ""

    private var filteredTracks: [TrackRow] {
        let query = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return appState.allTracks }
        return appState.allTracks.filter {
            $0.track.title.lowercased().contains(query)
                || ($0.album?.title.lowercased().contains(query) ?? false)
                || ($0.album?.artist?.lowercased().contains(query) ?? false)
                || ($0.artist?.name.lowercased().contains(query) ?? false)
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                Capsule().fill(Color.white.opacity(0.35)).frame(width: 36, height: 5).padding(.top, 10)
                Text("Load Track").font(.headline).foregroundStyle(.white).padding(.vertical, 10)
                SearchField(text: $filter, placeholder: "Search all your music…")
                    .padding(.horizontal, 16).padding(.bottom, 8)
                List(filteredTracks) { row in
                    Button {
                        onPick(row)
                        dismiss()
                    } label: {
                        HStack(spacing: 11) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.track.title).lineLimit(1)
                                Text(row.artist?.name ?? row.album?.artist ?? row.album?.title ?? "")
                                    .font(.caption).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                            }
                            Spacer()
                        }
                        .foregroundStyle(.white)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("dj.load.row.\(row.id)")
                    .listRowBackground(Color.clear)
                }
                .listStyle(.plain).scrollContentBackground(.hidden)
            }
        }
        .background(Color(red: 0x09 / 255, green: 0x0b / 255, blue: 0x12 / 255))
        .presentationDetents([.large])
        .presentationBackground(Color(red: 0x09 / 255, green: 0x0b / 255, blue: 0x12 / 255))
    }
}
