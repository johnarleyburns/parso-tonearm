import SwiftUI
import TonearmCore

struct LibraryView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var player: AudioPlayer
    @State private var mode: LibraryBrowseMode = .artists

    private var rows: [TrackRow] {
        appState.searchText.isEmpty ? appState.allTracks : appState.searchResults
    }

    private var sections: [LibraryBrowse.Section] {
        LibraryBrowse.sections(for: mode, rows: rows)
    }

    private var playbackRows: [TrackRow] {
        sections.flatMap(\.entries).flatMap(\.rows)
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ZStack(alignment: .trailing) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ScreenHeader(title: "Library")
                            SearchField(text: $appState.searchText, placeholder: "Search all your music…")
                                .padding(.top, 12)
                                .padding(.bottom, 12)
                                .onChange(of: appState.searchText) { _, _ in
                                    Task { await appState.runSearch() }
                                }

                            Picker("Library View", selection: $mode) {
                                ForEach(LibraryBrowseMode.allCases) { mode in
                                    Text(mode.rawValue).tag(mode)
                                }
                            }
                            .pickerStyle(.segmented)
                            .padding(.bottom, 16)

                            if rows.isEmpty {
                                EmptyStateView(icon: "music.note",
                                               title: appState.searchText.isEmpty ? "Your library is empty" : "No matches",
                                               message: appState.searchText.isEmpty
                                                    ? "Add a source or a local folder to fill your library."
                                                    : "Nothing in your library matches that.")
                                    .padding(.top, 60)
                            } else {
                                ForEach(sections) { section in
                                    SectionHeader(title: section.indexTitle,
                                                  trailing: "\(section.entries.count)")
                                        .id(section.indexTitle)
                                        .padding(.top, 6)
                                    ForEach(section.entries) { entry in
                                        entryRow(entry)
                                        Divider().overlay(Palette.hairline)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 18)
                        .padding(.trailing, sections.count > 1 ? 22 : 0)
                        .padding(.bottom, 160)
                    }
                    indexRail(proxy)
                }
            }
            .navigationDestination(for: LibraryBrowse.Entry.self) { entry in
                LibraryGroupDetailView(entry: entry)
            }
        }
        .foregroundStyle(Palette.ink)
        .task { await appState.reload() }
    }

    @ViewBuilder
    private func entryRow(_ entry: LibraryBrowse.Entry) -> some View {
        if entry.kind == .song, let row = entry.rows.first {
            Button {
                if let idx = playbackRows.firstIndex(where: { $0.id == row.id }) {
                    player.play(tracks: playbackRows, startAt: idx, source: .library)
                }
            } label: {
                TrackRowView(row: row)
            }
            .buttonStyle(.plain)
            .trackContextMenu(row)
        } else {
            NavigationLink(value: entry) {
                LibraryBrowseEntryRow(entry: entry)
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func indexRail(_ proxy: ScrollViewProxy) -> some View {
        if sections.count > 1 {
            VStack(spacing: 2) {
                ForEach(sections.map(\.indexTitle), id: \.self) { index in
                    Button {
                        withAnimation(.snappy) {
                            proxy.scrollTo(index, anchor: .top)
                        }
                    } label: {
                        Text(index)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Palette.brass)
                            .frame(width: 18, height: 16)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.trailing, 4)
        }
    }
}

private struct LibraryBrowseEntryRow: View {
    let entry: LibraryBrowse.Entry

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.brass)
                .frame(width: 28, height: 28)
                .glassSurface(cornerRadius: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                if let subtitle = entry.subtitle {
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.ink3)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Text("\(entry.rows.count)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.ink3)
        }
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }

    private var icon: String {
        switch entry.kind {
        case .artist: return "music.mic"
        case .album: return "square.stack"
        case .song: return "music.note"
        case .genre: return "tag"
        }
    }
}

private struct LibraryGroupDetailView: View {
    let entry: LibraryBrowse.Entry
    @EnvironmentObject var player: AudioPlayer
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                navRow
                Text(entry.title)
                    .font(.system(size: 25, weight: .heavy))
                    .lineLimit(3)
                    .padding(.top, 10)
                if let subtitle = entry.subtitle {
                    Text(subtitle)
                        .font(.system(size: 14))
                        .foregroundStyle(Palette.brass)
                        .padding(.top, 4)
                }
                cta.padding(.top, 14).padding(.bottom, 12)
                ForEach(Array(entry.rows.enumerated()), id: \.element.id) { idx, row in
                    Button {
                        player.play(tracks: entry.rows, startAt: idx, source: .library)
                    } label: {
                        TrackRowView(row: row)
                    }
                    .buttonStyle(.plain)
                    .trackContextMenu(row)
                    Divider().overlay(Palette.hairline)
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 160)
        }
        .background(Palette.libraryBackground.ignoresSafeArea())
        .foregroundStyle(Palette.ink)
        .navigationBarBackButtonHidden()
    }

    private var navRow: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15))
                    .foregroundStyle(Palette.brass)
                    .frame(width: 33, height: 33)
                    .glassSurface(cornerRadius: 16.5)
            }
            Spacer()
        }
        .padding(.top, 8)
    }

    private var cta: some View {
        HStack(spacing: 10) {
            Button { player.play(tracks: entry.rows, startAt: 0, source: .library) } label: {
                ctaLabel(icon: "play.fill", title: "Play")
            }
            Button {
                player.shuffle = true
                player.play(tracks: entry.rows.shuffled(), startAt: 0, source: .library)
            } label: {
                ctaLabel(icon: "shuffle", title: "Shuffle")
            }
        }
    }

    private func ctaLabel(icon: String, title: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
            Text(title)
        }
        .font(.system(size: 14.5, weight: .semibold))
        .foregroundStyle(Palette.brass)
        .frame(maxWidth: .infinity)
        .frame(height: 42)
        .glassSurface(cornerRadius: 21)
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
            SourceArtworkView(source: source, cornerRadius: 14)
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
        case .subsonic: return "Subsonic"
        case .webDAV: return "WebDAV"
        case .smb: return "SMB"
        case .jellyfin: return "Jellyfin"
        case .plex: return "Plex"
        case .dropbox: return "Dropbox"
        case .googleDrive: return "Google Drive"
        case .oneDrive: return "OneDrive"
        case .pCloud: return "pCloud"
        }
    }
}
