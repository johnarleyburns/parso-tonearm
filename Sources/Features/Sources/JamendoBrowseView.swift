import SwiftUI
import TonearmCore

/// Ad-hoc Jamendo browsing — distinct from the existing "Add Remote Library"
/// per-genre subscription flow (`GenrePickerSheet`/`addGenreLibrary`, which
/// pins a genre as a persisted `Source`). This is a zero-configuration
/// "Services" entry: pick a genre (top tracks by popularity) or search the
/// full catalogue by text, tap a track to play it immediately. No `Source`
/// row is created — a synthetic, unpersisted one (`id: nil`) is used only to
/// satisfy `RemoteTrackRowFactory`'s signature, matching how the rest of the
/// remote-library pipeline already shapes a played row.
struct JamendoBrowseView: View {
    @EnvironmentObject var player: AudioPlayer
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let allowsImport: Bool
    let showsBackButton: Bool

    init(allowsImport: Bool = false, showsBackButton: Bool = true) {
        self.allowsImport = allowsImport
        self.showsBackButton = showsBackButton
    }

    @State private var selectedGenre: JamendoGenreNode = JamendoBrowseView.defaultGenre
    @State private var searchText = ""
    @State private var activeQuery: String?
    @State private var nodes: [RemoteNode] = []
    @State private var offset = 0
    @State private var canLoadMore = true
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var errorText: String?
    @State private var importingIDs: Set<String> = []
    @State private var importedIDs: Set<String> = []
    @State private var importMessage: String?
    @State private var visibleTrackID: String?
    @State private var loadedGenrePath: String?

    /// "Dance" isn't a literal node in the curated tree's original set — it's
    /// added alongside Techno/House/etc. under Electronic specifically for
    /// this screen's requested default (electronic dance music, tag "dance").
    private static let defaultGenre = JamendoGenreTree.all.first { $0.path == "electronic/dance" }
        ?? JamendoGenreTree.roots[0]

    /// A page per request, not the full 100 at once — keeps each request
    /// fast and the list responsive; "show more" (via `.onAppear` on the
    /// last row) pages in further batches up to the 100 the user asked for
    /// as a reasonable top-N, and beyond if they keep scrolling.
    private static let pageSize = 50

    private var provider: JamendoGenreProvider {
        JamendoGenreProvider(clientID: JamendoAppConfig.clientID)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if allowsImport {
                Text(JamendoImportPolicy.explanation)
                    .font(Typography.callout)
                    .foregroundStyle(Palette.inkTertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
                    .accessibilityIdentifier("mymusic.jamendo.explanation")
            }
            searchField
            if activeQuery == nil {
                genrePicker
            }
            content
            if let importMessage {
                Text(importMessage)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.accent)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 8)
            }
        }
        .background(Palette.sourcesBackground.ignoresSafeArea())
        .foregroundStyle(Palette.ink)
        .navigationBarBackButtonHidden()
        .task(id: selectedGenre.path) {
            guard activeQuery == nil, loadedGenrePath != selectedGenre.path else { return }
            await reload()
        }
    }

    // `SourcesView` hides the system navigation bar for every pushed screen
    // (`.toolbar(.hidden, for: .navigationBar)`), so — matching
    // `SourceDetailView`'s own `navRow` exactly — this draws its own back
    // chevron rather than relying on one that doesn't exist. This screen is
    // still a normal push onto that same `NavigationStack`, which is what
    // lets Now Playing's dismiss return here with scroll position and
    // genre/search state intact: SwiftUI keeps this view instance alive
    // underneath, it's never recreated.
    private var header: some View {
        HStack {
            if showsBackButton {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(Typography.body)
                        .foregroundStyle(Palette.accent)
                        .frame(width: 33, height: 33)
                        .glassSurface(cornerRadius: 16.5)
                }
                .accessibilityLabel("Back")
            } else {
                Color.clear.frame(width: 33, height: 33)
            }
            Spacer()
            Text("Jamendo").font(Typography.headline)
            Spacer()
            Color.clear.frame(width: 33, height: 33)
        }
        .padding(.top, 8)
        .padding(.horizontal, 18)
    }

    private var searchField: some View {
        SearchField(text: $searchText, placeholder: "Search Jamendo…")
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .onSubmit {
                let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                activeQuery = trimmed.isEmpty ? nil : trimmed
                Task { await reload() }
            }
            .onChange(of: searchText) { _, newValue in
                guard newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, activeQuery != nil else { return }
                // Clearing the search bar returns to genre browsing.
                activeQuery = nil
                Task { await reload() }
            }
    }

    private var genrePicker: some View {
        Menu {
            ForEach(JamendoGenreTree.roots) { root in
                Menu(root.name) {
                    Button(root.name) { selectedGenre = root }
                    ForEach(root.children) { child in
                        Button(child.name) { selectedGenre = child }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(selectedGenre.name).font(Typography.callout)
                Image(systemName: "chevron.down").font(Typography.caption)
            }
            .foregroundStyle(Palette.accent)
            .padding(.horizontal, 14)
            .frame(height: 36)
            .glassSurface(cornerRadius: 18)
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if isLoading {
                    ProgressView().tint(Palette.accent).padding(.top, 30)
                } else if let errorText {
                    Text(errorText)
                        .font(Typography.callout)
                        .foregroundStyle(Palette.danger)
                        .multilineTextAlignment(.center)
                        .padding(.top, 24)
                } else if nodes.isEmpty {
                    Text(activeQuery == nil ? "No tracks found for \(selectedGenre.name)." : "No matches for \u{201c}\(activeQuery ?? "")\u{201d}.")
                        .font(Typography.callout)
                        .foregroundStyle(Palette.inkTertiary)
                        .padding(.top, 24)
                } else {
                    ForEach(Array(nodes.enumerated()), id: \.element.id) { index, node in
                        VStack(spacing: 0) {
                        resultRow(node: node, index: index)
                        .onAppear {
                            guard index == nodes.count - 1 else { return }
                            Task { await loadMore() }
                        }
                        Divider().overlay(Palette.hairline)
                        }
                        .id(node.id)
                    }
                    if isLoadingMore {
                        ProgressView().tint(Palette.accent).padding(.vertical, 16)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, 18)
            .padding(.bottom, 160)
        }
        .scrollPosition(id: $visibleTrackID, anchor: .top)
        .accessibilityIdentifier("mymusic.jamendo.tracks")
    }

    private func reload() async {
        visibleTrackID = nil
        offset = 0
        canLoadMore = true
        isLoading = true
        errorText = nil
        defer { isLoading = false }
        do {
            nodes = try await fetchPage(offset: 0)
            offset = nodes.count
            loadedGenrePath = activeQuery == nil ? selectedGenre.path : nil
        } catch {
            nodes = []
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func loadMore() async {
        guard !isLoading, !isLoadingMore, canLoadMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await fetchPage(offset: offset)
            canLoadMore = !page.isEmpty
            // Popularity changes can overlap page boundaries. Duplicate SwiftUI IDs
            // invalidate scroll anchors; advance the server cursor by the raw page.
            var existingIDs = Set(nodes.map(\.id))
            nodes.append(contentsOf: page.filter { existingIDs.insert($0.id).inserted })
            offset += page.count
        } catch {
            // A load-more failure isn't worth replacing the whole list with
            // an error — just stop paging quietly.
            canLoadMore = false
        }
    }

    private func fetchPage(offset: Int) async throws -> [RemoteNode] {
        if let activeQuery {
            let page = try await provider.api.search(query: activeQuery, offset: offset, limit: Self.pageSize)
            return JamendoGenreProvider.nodes(from: page.tracks)
        }
        let page = try await provider.api.tracks(tag: selectedGenre.tag, offset: offset, limit: Self.pageSize)
        return JamendoGenreProvider.nodes(from: page.tracks)
    }

    private func play(node: RemoteNode, index: Int) async {
        do {
            let resolved = try await provider.resolve(node: node)
            let source = JamendoQueueSource.makeSource(query: activeQuery, genre: selectedGenre)
            let row = RemoteTrackRowFactory.row(source: source, node: node, resolved: resolved, index: index)
            let continuation = JamendoQueueSource(provider: provider, source: source,
                                                  query: activeQuery, genre: selectedGenre,
                                                  nextOffset: index + 1)
            player.play(tracks: [row], startAt: 0, source: .continuation(continuation))
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    @ViewBuilder
    private func resultRow(node: RemoteNode, index: Int) -> some View {
        if allowsImport {
            HStack(spacing: 8) {
                Button { Task { await play(node: node, index: index) } } label: {
                    JamendoTrackRow(node: node)
                }
                .buttonStyle(.plain)
                Button { Task { await importNode(node) } } label: {
                    Image(systemName: importedIDs.contains(node.id) ? "checkmark.circle.fill" : "plus.circle")
                        .font(Typography.headline)
                        .foregroundStyle(importedIDs.contains(node.id) ? .green : Palette.accent)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .disabled(importingIDs.contains(node.id) || importedIDs.contains(node.id))
                .accessibilityLabel(importedIDs.contains(node.id) ? "Added to My Music" : "Add to My Music")
                .accessibilityIdentifier("mymusic.jamendo.import.\(node.id)")
            }
        } else {
            Button { Task { await play(node: node, index: index) } } label: {
                JamendoTrackRow(node: node)
            }
            .buttonStyle(.plain)
        }
    }

    private func importNode(_ node: RemoteNode) async {
        guard importingIDs.insert(node.id).inserted else { return }
        importMessage = nil
        defer { importingIDs.remove(node.id) }
        if await appState.importJamendoTrack(node: node) {
            importedIDs.insert(node.id)
            importMessage = String(localized: "Added to My Music and queued for indexing.")
        } else {
            importMessage = String(localized: "Couldn't add this Jamendo track. Try again.")
        }
    }
}

/// Keeps a Jamendo browse queue alive after the tapped track. The initial
/// browse result is intentionally not persisted as a library source, so the
/// continuation owns the API cursor and resolves each next row into the same
/// playable shape as the tapped row.
@MainActor
private final class JamendoQueueSource: QueueContinuationSource {
    private let provider: JamendoGenreProvider
    private let source: Source
    private let query: String?
    private let genre: JamendoGenreNode
    private var nextOffset: Int
    private var exhausted = false

    init(provider: JamendoGenreProvider, source: Source, query: String?,
         genre: JamendoGenreNode, nextOffset: Int) {
        self.provider = provider
        self.source = source
        self.query = query
        self.genre = genre
        self.nextOffset = max(0, nextOffset)
    }

    static func makeSource(query: String?, genre: JamendoGenreNode) -> Source {
        let identifier = query.map { "search:\($0)" } ?? genre.path
        return Source(id: nil, kind: .jamendoGenre, iaIdentifier: identifier,
                      originalURL: nil, title: "Jamendo", addedAt: Date(),
                      lastResolvedAt: nil, followUpdates: false, licenseText: nil,
                      memberCapHit: false)
    }

    func nextTracks(excluding: Set<Int64>, limit: Int) async -> [TrackRow] {
        guard !exhausted, limit > 0 else { return [] }
        do {
            let page: JamendoAPI.Page
            if let query {
                page = try await provider.api.search(query: query, offset: nextOffset, limit: limit)
            } else {
                page = try await provider.api.tracks(tag: selectedTag, offset: nextOffset, limit: limit)
            }
            let pageStart = nextOffset
            nextOffset += page.tracks.count
            exhausted = page.tracks.isEmpty || page.tracks.count < limit

            let nodes = JamendoGenreProvider.nodes(from: page.tracks)
            var rows: [TrackRow] = []
            rows.reserveCapacity(nodes.count)
            for (offset, node) in nodes.enumerated() {
                guard let resolved = try? await provider.resolve(node: node) else { continue }
                let row = RemoteTrackRowFactory.row(source: source, node: node,
                                                    resolved: resolved, index: pageStart + offset)
                if let id = row.track.id, !excluding.contains(id) {
                    rows.append(row)
                }
            }
            return rows
        } catch {
            exhausted = true
            return []
        }
    }

    private var selectedTag: String {
        String(genre.path.split(separator: "/").last ?? Substring(genre.path))
    }
}

private struct JamendoTrackRow: View {
    let node: RemoteNode

    var body: some View {
        HStack(spacing: 11) {
            // Jamendo results are remote `RemoteNode`s, not yet-imported
            // `TrackRow`s — this never routed through `ArtworkView`/
            // `TrackRowView` at all, so it never showed artwork even though
            // Jamendo provides real per-track album art (real report:
            // "I'm seeing the artwork EXCEPT for Jamendo top search"). Reuse
            // the same `RemoteArtworkImageView` `SourceDetailView`'s remote
            // browser already uses for exactly this "artwork for a node
            // that isn't imported yet" case.
            if let artwork = node.metadata?.artwork {
                RemoteArtworkImageView(artwork: artwork, seed: node.title, cornerRadius: 6)
                    .frame(width: 36, height: 36)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(node.title)
                    .font(Typography.callout)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                Text(subtitle)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.inkTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let durationSec = node.durationSec {
                Text(formattedDuration(durationSec))
                    .font(Typography.mono)
                    .foregroundStyle(Palette.inkTertiary)
            }
        }
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        let artist = node.metadata?.artist ?? String(localized: "Unknown artist")
        if let album = node.metadata?.album, !album.isEmpty {
            return "\(artist) · \(album)"
        }
        return artist
    }

    private func formattedDuration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
