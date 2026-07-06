import SwiftUI

struct LibraryView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var player: AudioPlayer

    private var rows: [TrackRow] {
        appState.searchText.isEmpty ? appState.allTracks : appState.searchResults
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ScreenHeader(title: "Library")
                SearchField(text: $appState.searchText, placeholder: "Search all your music…")
                    .padding(.top, 12)
                    .padding(.bottom, 16)
                    .onChange(of: appState.searchText) { _, _ in
                        Task { await appState.runSearch() }
                    }

                if rows.isEmpty {
                    EmptyStateView(icon: "music.note",
                                   title: appState.searchText.isEmpty ? "Your library is empty" : "No matches",
                                   message: appState.searchText.isEmpty
                                        ? "Add a source or a local folder to fill your library."
                                        : "Nothing in your library matches that.")
                        .padding(.top, 60)
                } else {
                    SectionHeader(title: "All Music", trailing: "\(rows.count)")
                    ForEach(rows) { row in
                        Button {
                            if let idx = rows.firstIndex(where: { $0.id == row.id }) {
                                player.play(tracks: rows, startAt: idx)
                            }
                        } label: {
                            TrackRowView(row: row)
                        }
                        .buttonStyle(.plain)
                        .trackContextMenu(row)
                        Divider().overlay(Palette.hairline)
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 160)
        }
        .foregroundStyle(Palette.ink)
        .task { await appState.reload() }
    }
}

struct SectionHeader: View {
    let title: String
    var trailing: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 18, weight: .bold))
            Spacer()
            if let trailing {
                Text(trailing).font(.system(size: 13)).foregroundStyle(Palette.brass)
            }
        }
        .padding(.horizontal, 2)
        .padding(.bottom, 10)
    }
}

struct AlbumCell: View {
    let source: Source

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ArtworkView(seed: source.title, cornerRadius: 14)
                .aspectRatio(1, contentMode: .fit)
                .overlay(alignment: .bottomLeading) {
                    ProvenanceChip(source: source).padding(8)
                }
            Text(source.title)
                .font(.system(size: 12.5, weight: .semibold))
                .lineLimit(1)
                .padding(.top, 7)
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundStyle(Palette.ink3)
                .lineLimit(1)
                .padding(.top, 1)
        }
    }

    private var subtitle: String {
        switch source.kind {
        case .local: return "On device"
        case .iaItem: return source.licenseText ?? "archive.org"
        case .iaList: return "List"
        case .iaCollection: return "Collection"
        case .iaFavorites: return "Favorites"
        }
    }
}
