import SwiftUI
import TonearmWatchCore
import TonearmWatchProtocol

enum WatchSearchMode: Hashable, Sendable {
    case allMusic, thisWatch
    var title: LocalizedStringKey {
        switch self { case .allMusic: "Search All Music"; case .thisWatch: "Search This Watch" }
    }
}

/// Search is intentionally backed only by WatchLibraryModel. A connected phone changes download
/// availability, never the source of search results.
struct WatchSearchView: View {
    let mode: WatchSearchMode
    @ObservedObject private var model = WatchAppAssembly.shared.model
    @StateObject private var presenter: WatchSearchPresenter
    @FocusState private var fieldFocused: Bool
    @State private var pendingDownload: WatchTrackRequest?
    @State private var downloadNavigation: WatchTrackRequest?
    @State private var showDownloadConfirmation = false

    init(mode: WatchSearchMode) {
        self.mode = mode
        let model = WatchAppAssembly.shared.model
        _presenter = StateObject(wrappedValue: WatchSearchPresenter(
            mode: .offline,
            connectedSearch: { _, _ in .failed(.init(code: .phoneUnavailable)) },
            offlineSearch: { query in await model.search(query: query, onWatchOnly: mode == .thisWatch) }))
    }

    private var rows: [WatchResultRow] {
        switch presenter.phase {
        case .results(let rows), .offlineResults(let rows): rows
        default: []
        }
    }

    private var isSearching: Bool { presenter.phase == .loading }

    var body: some View {
        List {
            TextField(mode == .allMusic ? "Search synced catalog" : "Search downloaded music", text: $presenter.query)
                .focused($fieldFocused).submitLabel(.search).onSubmit { presenter.submit() }
                .accessibilityIdentifier("watch.search.field")
                .listRowBackground(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(WatchPalette.surface))
            if isSearching {
                HStack { ProgressView(); Text("Searching this watch…").font(.caption2) }
                    .listRowBackground(Color.clear)
            } else if rows.isEmpty {
                Text(presenter.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                     ? (mode == .allMusic ? "Search the synced music catalog." : "Search audio downloaded to this watch.")
                     : "No matches in this watch catalog.")
                    .font(.caption2).foregroundStyle(.secondary).listRowBackground(Color.clear)
            } else {
                ForEach(rows) { row in resultRow(row) }
            }
        }
        .listStyle(.plain).navigationTitle(mode.title)
        .onChange(of: model.tracks) { _, _ in presenter.refresh() }
        .onChange(of: model.playlists) { _, _ in presenter.refresh() }
        .onAppear { if !ProcessInfo.processInfo.arguments.contains("UI_TESTING") { fieldFocused = true } }
        .navigationDestination(item: $downloadNavigation) { request in
            WatchTrackDownloadView(trackID: request.trackID, title: request.title)
        }
        .confirmationDialog("Download to Apple Watch?", isPresented: $showDownloadConfirmation,
                            titleVisibility: .visible) {
            Button("Download to Watch") {
                downloadNavigation = pendingDownload
                pendingDownload = nil
            }
            Button("Cancel", role: .cancel) { pendingDownload = nil }
        } message: {
            Text("The selected track is in your synced catalog but is not fully downloaded on this watch.")
        }
    }

    @ViewBuilder
    private func resultRow(_ row: WatchResultRow) -> some View {
        if let ref = row.collectionRef {
            NavigationLink(value: ref.kind == .playlist ? WatchNav.playlist(ref.id) : WatchNav.album(ref.id)) {
                label(row)
            }.watchCardRow()
        } else {
            Button { activate(row) } label: { label(row).contentShape(Rectangle()) }
                .buttonStyle(.plain).watchCardRow()
        }
    }

    private func label(_ row: WatchResultRow) -> some View {
        HStack(spacing: 8) {
            WatchLocalArtTile(filename: model.track(id: row.id)?.artworkFilename, tintKey: row.title,
                              size: 30, systemImage: WatchSearchGroup.icon(for: row.kind))
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title).font(.body).lineLimit(1)
                Text(detail(row)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 2)
            if row.isDownloadedOnWatch {
                Image(systemName: "checkmark.circle.fill").font(.caption2).foregroundStyle(WatchPalette.success)
                    .accessibilityLabel(Text("Downloaded to this watch"))
            } else if row.kind == .track {
                Image(systemName: "arrow.down.circle").font(.caption2).foregroundStyle(.secondary)
                    .accessibilityLabel(Text("Available to download"))
            }
        }
    }

    private func detail(_ row: WatchResultRow) -> String {
        let kind = WatchSearchGroup.kindLabel(row.kind)
        guard let subtitle = row.subtitle, !subtitle.isEmpty else { return kind }
        return "\(kind) · \(subtitle)"
    }

    private func activate(_ row: WatchResultRow) {
        guard row.kind == .track, let track = model.track(id: row.id) else { return }
        if track.isReady {
            WatchPlayer.shared.startLocalPlayback(tracks: [track], selectedTrackID: track.id)
        } else {
            pendingDownload = WatchTrackRequest(trackID: row.id, title: row.title)
            showDownloadConfirmation = true
        }
    }

}

private struct WatchTrackRequest: Identifiable, Hashable {
    let trackID: String
    let title: String
    var id: String { trackID }
}

struct WatchTrackDownloadView: View {
    let trackID: String
    let title: String
    @ObservedObject private var model = WatchAppAssembly.shared.model
    @Environment(\.dismiss) private var dismiss
    @State private var started = false
    @State private var failed = false

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.down.circle.fill").font(.largeTitle).foregroundStyle(WatchPalette.accent)
            Text(title).font(.headline).multilineTextAlignment(.center)
            if let fraction = model.transferFraction(forTrackID: trackID) {
                ProgressView(value: fraction)
                Text("Downloading… \(Int(fraction * 100))%").font(.caption2).foregroundStyle(.secondary)
            } else if model.track(id: trackID)?.isReady == true {
                Text("Downloaded. Starting playback…").font(.caption2).foregroundStyle(WatchPalette.success)
            } else if model.downloadStatus?.roots.first(where: { $0.rootID == "track:\(trackID)" })?.state == .failed {
                Text("The iPhone could not prepare this track. Try again.")
                    .font(.caption2).foregroundStyle(.orange).multilineTextAlignment(.center)
            } else if failed {
                Text("Keep the iPhone available to download this track.")
                    .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
            } else {
                ProgressView().controlSize(.small)
                Text("Waiting for the iPhone to send this track…")
                    .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .padding().navigationTitle("Download to Watch")
        .task {
            guard !started else { return }
            started = true
            await WatchAppAssembly.shared.requestDownloads([WatchTrackID(trackID)])
            for _ in 0..<120 {
                await model.refresh()
                if let track = model.track(id: trackID), track.isReady {
                    WatchPlayer.shared.startLocalPlayback(tracks: [track], selectedTrackID: track.id)
                    dismiss(); return
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
            failed = true
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
