import SwiftUI

struct LibraryView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var player: AudioPlayer

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ScreenHeader(title: "Library")
                SearchField(text: $appState.searchText, placeholder: "Your artists, albums, tracks…")
                    .padding(.top, 12)
                    .padding(.bottom, 16)
                    .onChange(of: appState.searchText) { _, _ in
                        Task { await appState.runSearch() }
                    }

                if !appState.searchText.isEmpty {
                    searchResults
                } else {
                    pinned
                    recentlyAdded
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 160)
        }
        .foregroundStyle(Palette.ink)
    }

    private var pinned: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Pinned", trailing: "Sources")
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(appState.sources.prefix(4)) { source in
                    Button {
                        appState.tab = .sources
                    } label: {
                        AlbumCell(source: source)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Play") { Task { await appState.playSource(source) } }
                    }
                }
            }
            .padding(.bottom, 18)
        }
    }

    private var recentlyAdded: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Recently Added", trailing: "See All")
            ForEach(appState.allTracks.prefix(8)) { row in
                Button {
                    if let idx = appState.allTracks.firstIndex(where: { $0.id == row.id }) {
                        player.play(tracks: appState.allTracks, startAt: idx)
                    }
                } label: {
                    TrackRowView(row: row)
                }
                .buttonStyle(.plain)
                Divider().overlay(Palette.hairline)
            }
        }
    }

    private var searchResults: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Results", trailing: "\(appState.searchResults.count)")
            if appState.searchResults.isEmpty {
                Text("No matches in your library.")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.ink3)
                    .padding(.vertical, 20)
            }
            ForEach(appState.searchResults) { row in
                Button {
                    if let idx = appState.searchResults.firstIndex(where: { $0.id == row.id }) {
                        player.play(tracks: appState.searchResults, startAt: idx)
                    }
                } label: { TrackRowView(row: row) }
                .buttonStyle(.plain)
                Divider().overlay(Palette.hairline)
            }
        }
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
