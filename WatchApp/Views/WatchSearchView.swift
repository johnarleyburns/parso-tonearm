import SwiftUI
import TonearmWatchCore
import TonearmWatchProtocol

/// W2 — the watch's one search surface. Connected: typed iPhone-library results with a bounded wait.
/// Offline: local downloaded tracks only. Recent searches lead when nothing is typed.
struct WatchSearchView: View {
    @ObservedObject private var presenter = WatchAppAssembly.shared.search
    @ObservedObject private var chrome = WatchAppAssembly.shared.chrome
    @ObservedObject private var player = WatchPlayer.shared

    var body: some View {
        List {
            TextField(chrome.showsConnectedFeatures ? "Search iPhone" : "Search Downloads",
                      text: $presenter.query)
                .accessibilityIdentifier("watch.search.field")
                .submitLabel(.search)
                .onSubmit { presenter.submit() }

            content
        }
        .listStyle(.carousel)
        .navigationTitle("Search")
    }

    @ViewBuilder
    private var content: some View {
        switch presenter.phase {
        case .recent(let queries):
            if queries.isEmpty {
                Text("Type to search\(chrome.showsConnectedFeatures ? " your iPhone library" : " your downloads").")
                    .font(.system(.caption2)).foregroundStyle(.secondary)
            } else {
                Section("Recent") {
                    ForEach(queries, id: \.self) { q in
                        Button(q) { presenter.submit(q) }
                    }
                    Button("Clear", role: .destructive) { presenter.clearRecents() }
                }
            }

        case .tooShort:
            Text("Keep typing…").font(.system(.caption2)).foregroundStyle(.secondary)

        case .loading:
            HStack { ProgressView(); Text("Searching…").font(.system(.caption2)) }
                .accessibilityIdentifier("watch.search.loading")

        case .results(let rows), .offlineResults(let rows):
            ForEach(rows) { row in resultRow(row) }

        case .noResults, .offlineNoResults:
            Text("No results").font(.system(.caption2)).foregroundStyle(.secondary)

        case .unreachable:
            VStack(alignment: .leading, spacing: 8) {
                Text("Couldn't reach iPhone")
                    .font(.system(.headline, design: .default))
                Text("Try again, or search your downloads.")
                    .font(.system(.caption2)).foregroundStyle(.secondary)
                Button("Try Again") { presenter.submit() }
                    .accessibilityIdentifier("watch.search.retry")
                Button("Search Downloads") { presenter.setMode(.offline) }
                    .accessibilityIdentifier("watch.search.downloads")
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func resultRow(_ row: WatchResultRow) -> some View {
        if let ref = row.collectionRef, chrome.showsConnectedFeatures {
            NavigationLink(value: WatchNav.phoneCollection(ref)) { rowLabel(row) }
                .accessibilityIdentifier("watch.search.result.\(row.id)")
        } else {
            Button { activate(row) } label: { rowLabel(row).contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .accessibilityIdentifier("watch.search.result.\(row.id)")
        }
    }

    private func rowLabel(_ row: WatchResultRow) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon(for: row.kind))
                .font(.system(size: 13)).foregroundStyle(.tint).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title).font(.system(.body)).lineLimit(1)
                if let subtitle = row.subtitle {
                    Text(subtitle).font(.system(.caption2)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if row.isDownloadedOnWatch {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11)).foregroundStyle(.green)
                    .accessibilityLabel("Downloaded on watch")
            }
        }
    }

    private func activate(_ row: WatchResultRow) {
        switch (row.kind, chrome.showsConnectedFeatures) {
        case (.track, false):
            if let track = WatchAppAssembly.shared.model.track(id: row.id) {
                player.play(tracks: [track], startAt: 0)
            }
        case (.track, true):
            Task { await WatchAppAssembly.shared.playOnPhone(.playTrack(WatchTrackID(row.id))) }
        default:
            break
        }
    }

    private func icon(for kind: WatchResultKind) -> String {
        switch kind {
        case .track: "music.note"
        case .album: "square.stack"
        case .playlist: "music.note.list"
        case .artist: "person"
        }
    }
}
