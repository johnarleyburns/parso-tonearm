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
    @Environment(\.dismiss) private var dismiss

    @State private var selectedGenre: JamendoGenreNode = JamendoBrowseView.defaultGenre
    @State private var searchText = ""
    @State private var activeQuery: String?
    @State private var nodes: [RemoteNode] = []
    @State private var offset = 0
    @State private var canLoadMore = true
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var errorText: String?

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
            searchField
            if activeQuery == nil {
                genrePicker
            }
            content
        }
        .background(Palette.sourcesBackground.ignoresSafeArea())
        .foregroundStyle(Palette.ink)
        .navigationBarBackButtonHidden()
        .task(id: selectedGenre.path) {
            guard activeQuery == nil else { return }
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
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15))
                    .foregroundStyle(Palette.brass)
                    .frame(width: 33, height: 33)
                    .glassSurface(cornerRadius: 16.5)
            }
            Spacer()
            Text("Jamendo").font(.system(size: 17, weight: .bold))
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
                Text(selectedGenre.name).font(.system(size: 14, weight: .semibold))
                Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(Palette.brass)
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
                    ProgressView().tint(Palette.brass).padding(.top, 30)
                } else if let errorText {
                    Text(errorText)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Palette.danger)
                        .multilineTextAlignment(.center)
                        .padding(.top, 24)
                } else if nodes.isEmpty {
                    Text(activeQuery == nil ? "No tracks found for \(selectedGenre.name)." : "No matches for \u{201c}\(activeQuery ?? "")\u{201d}.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Palette.ink3)
                        .padding(.top, 24)
                } else {
                    ForEach(Array(nodes.enumerated()), id: \.element.id) { index, node in
                        Button {
                            Task { await play(node: node, index: index) }
                        } label: {
                            JamendoTrackRow(node: node)
                        }
                        .buttonStyle(.plain)
                        .onAppear {
                            guard index == nodes.count - 1 else { return }
                            Task { await loadMore() }
                        }
                        Divider().overlay(Palette.hairline)
                    }
                    if isLoadingMore {
                        ProgressView().tint(Palette.brass).padding(.vertical, 16)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 160)
        }
    }

    private func reload() async {
        offset = 0
        canLoadMore = true
        isLoading = true
        errorText = nil
        defer { isLoading = false }
        do {
            nodes = try await fetchPage(offset: 0)
            offset = nodes.count
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
            nodes.append(contentsOf: page)
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
            let source = Source(id: nil, kind: .jamendoGenre, iaIdentifier: selectedGenre.path,
                                originalURL: nil, title: "Jamendo", addedAt: Date(),
                                lastResolvedAt: nil, followUpdates: false, licenseText: nil,
                                memberCapHit: false)
            let row = RemoteTrackRowFactory.row(source: source, node: node, resolved: resolved, index: index)
            player.play(tracks: [row], startAt: 0, source: .source(source))
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

private struct JamendoTrackRow: View {
    let node: RemoteNode

    var body: some View {
        HStack(spacing: 11) {
            VStack(alignment: .leading, spacing: 2) {
                Text(node.title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.ink3)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let durationSec = node.durationSec {
                Text(formattedDuration(durationSec))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Palette.ink3)
            }
        }
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        let artist = node.metadata?.artist ?? "Unknown artist"
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
