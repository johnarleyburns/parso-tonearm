import SwiftUI
import TonearmWatchCore
import TonearmWatchProtocol

enum WatchSearchMode: Hashable, Sendable {
    case thisWatch
    var title: LocalizedStringKey { "Search" }
}

/// Search only installed audio, regardless of phone reachability.
struct WatchSearchView: View {
    let mode: WatchSearchMode
    @ObservedObject private var model = WatchAppAssembly.shared.model
    @StateObject private var presenter: WatchSearchPresenter
    @FocusState private var fieldFocused: Bool

    init(mode: WatchSearchMode) {
        self.mode = mode
        let model = WatchAppAssembly.shared.model
        _presenter = StateObject(wrappedValue: WatchSearchPresenter(
            mode: .offline,
            connectedSearch: { _, _ in .failed(.init(code: .phoneUnavailable)) },
            offlineSearch: { query in await model.search(query: query, onWatchOnly: true) }))
    }

    private var rows: [WatchResultRow] {
        switch presenter.phase {
        case .results(let rows), .offlineResults(let rows): rows
        default: []
        }
    }

    var body: some View {
        List {
            TextField("Search downloaded music", text: $presenter.query)
                .focused($fieldFocused).submitLabel(.search).onSubmit { presenter.submit() }
                .accessibilityIdentifier("watch.search.field")
            if presenter.phase == .loading {
                ProgressView("Searching this watch…")
            } else if rows.isEmpty {
                Text(presenter.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                     ? "Search audio downloaded to this watch." : "No matching downloaded music.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                ForEach(rows) { row in
                    if let ref = row.collectionRef {
                        NavigationLink(value: ref.kind == .playlist ? WatchNav.playlist(ref.id) : WatchNav.album(ref.id)) {
                            label(row)
                        }.watchCardRow()
                    } else {
                        Button {
                            guard let track = model.track(id: row.id), track.isReady else { return }
                            WatchPlayer.shared.startLocalPlayback(tracks: [track], selectedTrackID: track.id)
                        } label: { label(row) }.watchCardRow()
                    }
                }
            }
        }
        .listStyle(.plain).navigationTitle(mode.title)
        .onChange(of: model.tracks) { _, _ in presenter.refresh() }
        .onChange(of: model.playlists) { _, _ in presenter.refresh() }
        .onAppear { if !ProcessInfo.processInfo.arguments.contains("UI_TESTING") { fieldFocused = true } }
    }

    private func label(_ row: WatchResultRow) -> some View {
        HStack(spacing: 8) {
            WatchLocalArtTile(filename: model.track(id: row.id)?.artworkFilename, tintKey: row.title,
                              size: 30, systemImage: WatchSearchGroup.icon(for: row.kind))
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title).lineLimit(1)
                if let subtitle = row.subtitle { Text(subtitle).font(.caption2).foregroundStyle(.secondary) }
            }
        }
    }
}

enum WatchSearchGroup {
    static func icon(for kind: WatchResultKind) -> String {
        switch kind { case .track: "music.note"; case .album: "square.stack"; case .playlist: "music.note.list"; case .artist: "person" }
    }
    static func kindLabel(_ kind: WatchResultKind) -> String {
        switch kind { case .track: "Song"; case .album: "Album"; case .playlist: "Playlist"; case .artist: "Artist" }
    }
}
