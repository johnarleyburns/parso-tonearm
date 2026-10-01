import SwiftUI
import TonearmWatchCore
import TonearmWatchProtocol

/// Watch redesign §5 Q1/Q2 — dictation-first search with results you can trust. The field opens
/// the system text input (dictation, Scribble, keyboard) as soon as the screen appears; results are
/// grouped with the strongest match first; and the screen never says "No results" without saying
/// *where* it looked — a phone timeout falls back to this watch's downloads and says so.
struct WatchSearchView: View {
    @ObservedObject private var presenter = WatchAppAssembly.shared.search
    @ObservedObject private var chrome = WatchAppAssembly.shared.chrome
    @ObservedObject private var model = WatchAppAssembly.shared.model
    @ObservedObject private var coordinator = WatchPlaybackCoordinator.shared
    @FocusState private var fieldFocused: Bool
    @State private var didAutoFocus = false

    var body: some View {
        List {
            TextField(fieldPrompt, text: $presenter.query)
                .focused($fieldFocused)
                .submitLabel(.search)
                .onSubmit { presenter.submit() }
                .accessibilityIdentifier("watch.search.field")
                .listRowBackground(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(WatchPalette.surface))
            content
        }
        .listStyle(.plain)
        .navigationTitle("Search")
        .onAppear {
            // Dictation-first: open input straight away the first time, unless a UI test drives it.
            guard !didAutoFocus, presenter.query.isEmpty,
                  !ProcessInfo.processInfo.arguments.contains("UI_TESTING") else { return }
            didAutoFocus = true
            fieldFocused = true
        }
    }

    private var fieldPrompt: String {
        chrome.showsConnectedFeatures ? String(localized: "Search iPhone library")
                                      : String(localized: "Search this watch")
    }

    @ViewBuilder
    private var content: some View {
        switch presenter.phase {
        case .recent(let queries):
            if queries.isEmpty {
                (chrome.showsConnectedFeatures
                     ? Text("Say a song, album or playlist. Searches your iPhone library.")
                     : Text("Say a song or artist. Searches the music on this watch."))
                    .font(.caption2).foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            } else {
                Section("Recent") {
                    ForEach(queries, id: \.self) { query in
                        Button(query) { presenter.submit(query) }
                            .watchCardRow()
                    }
                    Button("Clear Recents", role: .destructive) { presenter.clearRecents() }
                        .listRowBackground(Color.clear)
                }
            }

        case .tooShort:
            Text("Keep going…").font(.caption2).foregroundStyle(.secondary)
                .listRowBackground(Color.clear)

        case .loading:
            HStack { ProgressView(); (chrome.showsConnectedFeatures ? Text("Searching iPhone…") : Text("Searching…")).font(.caption2) }
                .accessibilityIdentifier("watch.search.loading")
                .listRowBackground(Color.clear)

        case .results(let rows):
            grouped(rows, scope: .iPhone)

        case .offlineResults(let rows):
            scopeNote(String(localized: "On this watch"))
            grouped(rows, scope: .thisWatch)

        case .noResults:
            explanation(title: "No matches in your iPhone library",
                        message: String(localized: "Try a different word, or an artist name."))

        case .offlineNoResults:
            explanation(title: "Nothing on this watch matches",
                        message: String(localized: "Searched the \(model.tracks.count) songs on this watch."))

        case .unreachable(let fallback):
            WatchProblemCard(
                systemImage: "iphone.slash",
                title: fallback.isEmpty ? "Nothing on this watch matches" : "Showing this watch only",
                message: String(localized: "Your iPhone isn't reachable, so only the \(model.tracks.count) downloaded songs were searched."),
                actions: [.init(title: "Try iPhone Again", identifier: "watch.search.retry") { presenter.submit() }])
                .listRowBackground(Color.clear)
            if !fallback.isEmpty { grouped(fallback, scope: .thisWatch) }
        }
    }

    // MARK: Grouping

    @ViewBuilder
    private func grouped(_ rows: [WatchResultRow], scope: WatchTarget) -> some View {
        if let top = rows.first {
            Section("Top Result") { resultRow(top, scope: scope) }
        }
        let rest = Array(rows.dropFirst())
        ForEach(WatchSearchGroup.allCases, id: \.self) { group in
            let members = rest.filter { group.matches($0.kind) }
            if !members.isEmpty {
                Section(group.title) {
                    ForEach(members) { resultRow($0, scope: scope) }
                }
            }
        }
    }

    @ViewBuilder
    private func resultRow(_ row: WatchResultRow, scope: WatchTarget) -> some View {
        if let ref = row.collectionRef, scope == .iPhone {
            NavigationLink(value: WatchNav.phoneCollection(ref)) { rowLabel(row) }
                .watchCardRow()
                .accessibilityIdentifier("watch.search.result.\(row.id)")
        } else {
            Button { activate(row, scope: scope) } label: { rowLabel(row).contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .watchCardRow()
                .accessibilityIdentifier("watch.search.result.\(row.id)")
        }
    }

    private func rowLabel(_ row: WatchResultRow) -> some View {
        HStack(spacing: 8) {
            WatchLocalArtTile(filename: model.track(id: row.id)?.artworkFilename, tintKey: row.title,
                              size: 30, systemImage: WatchSearchGroup.icon(for: row.kind))
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title).font(.body).lineLimit(1)
                Text(subtitle(row)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 2)
            if row.isDownloadedOnWatch {
                Image(systemName: "arrow.down.circle.fill").font(.caption2).foregroundStyle(WatchPalette.success)
                    .accessibilityLabel(Text("On this watch"))
            }
        }
    }

    private func subtitle(_ row: WatchResultRow) -> String {
        let kind = WatchSearchGroup.kindLabel(row.kind)
        guard let detail = row.subtitle, !detail.isEmpty else { return kind }
        return "\(kind) · \(detail)"
    }

    private func activate(_ row: WatchResultRow, scope: WatchTarget) {
        guard row.kind == .track else { return }
        let local = model.track(id: row.id)
        let preferWatch = WatchPlaybackTargetStore.hasStoredPreference() && coordinator.target == .thisWatch
        if scope == .iPhone, !(preferWatch && local != nil) {
            Task { await WatchAppAssembly.shared.playOnPhone(.playTrack(WatchTrackID(row.id)), title: row.title) }
        } else if let local {
            WatchPlayer.shared.play(tracks: [local], startAt: 0)
        }
    }

    private func scopeNote(_ text: String) -> some View {
        Text(text).font(.caption2).foregroundStyle(.secondary).listRowBackground(Color.clear)
    }

    private func explanation(title: LocalizedStringKey, message: String) -> some View {
        VStack(spacing: 4) {
            Text(title).font(.headline).multilineTextAlignment(.center)
            Text(message).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .listRowBackground(Color.clear)
        .accessibilityIdentifier("watch.search.empty")
    }
}

/// Search result groups, in display order after the top result.
enum WatchSearchGroup: CaseIterable {
    case songs, albums, playlists, artists

    var title: LocalizedStringKey {
        switch self {
        case .songs: "Songs"
        case .albums: "Albums"
        case .playlists: "Playlists"
        case .artists: "Artists"
        }
    }

    func matches(_ kind: WatchResultKind) -> Bool {
        switch (self, kind) {
        case (.songs, .track), (.albums, .album), (.playlists, .playlist), (.artists, .artist): true
        default: false
        }
    }

    static func icon(for kind: WatchResultKind) -> String {
        switch kind {
        case .track: "music.note"
        case .album: "square.stack"
        case .playlist: "music.note.list"
        case .artist: "person"
        }
    }

    static func kindLabel(_ kind: WatchResultKind) -> String {
        switch kind {
        case .track: String(localized: "Song")
        case .album: String(localized: "Album")
        case .playlist: String(localized: "Playlist")
        case .artist: String(localized: "Artist")
        }
    }
}
