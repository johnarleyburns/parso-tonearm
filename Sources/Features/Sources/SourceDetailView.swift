import SwiftUI
import TonearmCore

struct SourceDetailView: View {
    let source: Source
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var player: AudioPlayer
    @Environment(\.dismiss) private var dismiss
    @State private var tracks: [TrackRow] = []
    @State private var heroArtworkId: String?
    @State private var remoteNodes: [RemoteNode] = []
    @State private var remotePath = ""
    @State private var remoteBackStack: [String] = []
    @State private var remoteError: String?
    @State private var isLoadingRemote = false

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                navRow
                hero
                content
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 160)
        }
        .background(Palette.sourcesBackground.ignoresSafeArea())
        .foregroundStyle(Palette.ink)
        .navigationBarBackButtonHidden()
        .task {
            await load()
        }
    }

    @ViewBuilder
    private var content: some View {
        if isRemoteLibrary {
            remoteBrowser
        } else {
            localTrackList
            Text("Streams from archive.org · played tracks stay in the cache\nand work offline until space is needed")
                .font(.system(size: 11))
                .foregroundStyle(Palette.ink3)
                .multilineTextAlignment(.center)
                .padding(.top, 16)
        }
    }

    private var localTrackList: some View {
        ForEach(Array(tracks.enumerated()), id: \.element.id) { idx, row in
            Button {
                player.play(tracks: tracks, startAt: idx, source: .source(source))
            } label: {
                TrackRowView(row: row)
            }
            .buttonStyle(.plain)
            Divider().overlay(Palette.hairline)
        }
    }

    private var remoteBrowser: some View {
        VStack(spacing: 0) {
            if !remoteBackStack.isEmpty {
                Button {
                    Task { await goBackRemote() }
                } label: {
                    RemoteNodeRow(icon: "chevron.left", title: "Back", subtitle: nil)
                }
                .buttonStyle(.plain)
                Divider().overlay(Palette.hairline)
            }

            if isLoadingRemote {
                ProgressView().tint(Palette.brass).padding(.top, 26)
            } else if let remoteError {
                Text(remoteError)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.danger)
                    .multilineTextAlignment(.center)
                    .padding(.top, 20)
            } else if remoteNodes.isEmpty {
                Text("No music found")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.ink3)
                    .padding(.top, 20)
            } else {
                ForEach(remoteNodes) { node in
                    Button {
                        Task { await selectRemoteNode(node) }
                    } label: {
                        RemoteNodeRow(
                            icon: icon(for: node),
                            title: node.title,
                            subtitle: subtitle(for: node)
                        )
                    }
                    .buttonStyle(.plain)
                    Divider().overlay(Palette.hairline)
                }
            }

            Text("Streams from your server · played tracks stay in the cache\nand work offline until space is needed")
                .font(.system(size: 11))
                .foregroundStyle(Palette.ink3)
                .multilineTextAlignment(.center)
                .padding(.top, 16)
        }
    }

    private var navRow: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15)).foregroundStyle(Palette.brass)
                    .frame(width: 33, height: 33).glassSurface(cornerRadius: 16.5)
            }
            Spacer()
            Menu {
                Button("Remove Source", role: .destructive) {
                    Task { await appState.deleteSource(source); dismiss() }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15)).foregroundStyle(Palette.brass)
                    .frame(width: 33, height: 33).glassSurface(cornerRadius: 16.5)
            }
        }
        .padding(.top, 8)
    }

    private var hero: some View {
        VStack(spacing: 0) {
            SourceArtworkView(source: source, cornerRadius: 18)
                .frame(width: 168, height: 168)
                .shadow(color: .black.opacity(0.55), radius: 20, y: 12)
            Text(source.title)
                .font(.system(size: 18, weight: .bold))
                .multilineTextAlignment(.center)
                .padding(.top, 13)
            if let artist = tracks.first?.album?.artist {
                Text(artist).font(.system(size: 14)).foregroundStyle(Palette.brass).padding(.top, 3)
            }
            badge.padding(.top, 9)
            cta.padding(.top, 14)
            if isArchiveSource,
               let id = tracks.first?.album?.artworkId ?? heroArtworkId, !id.isEmpty,
               let iaURL = ShareURLBuilder.url(identifier: id) {
                Link(destination: iaURL) {
                    HStack(spacing: 5) {
                        Image(systemName: "safari")
                        Text("View on archive.org")
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.ink3)
                }
                .padding(.top, 10)
            }
        }
        .padding(.bottom, 6)
    }

    private var badge: some View {
        HStack(spacing: 6) {
            Circle().fill(Palette.ok).frame(width: 6, height: 6)
            Text(badgeText).font(.system(size: 10.5, weight: .semibold)).kerning(0.5)
        }
        .foregroundStyle(Palette.ink2)
        .padding(.horizontal, 11).padding(.vertical, 5)
        .glassSurface(cornerRadius: 12)
    }

    private var badgeText: String {
        if source.kind == .local { return "on device" }
        if isRemoteLibrary { return "\(remoteProviderName) · private library" }
        return "archive.org · \(source.licenseText ?? "streams permitted")"
    }

    @ViewBuilder
    private var cta: some View {
        if isRemoteLibrary {
            HStack(spacing: 10) {
                Button { Task { await playVisibleRemote(startAt: 0, shuffled: false) } } label: {
                    ctaLabel(icon: "play.fill", title: "Play")
                }
                Button { Task { await playVisibleRemote(startAt: 0, shuffled: true) } } label: {
                    ctaLabel(icon: "shuffle", title: "Shuffle")
                }
            }
            .opacity(remoteNodes.contains { $0.kind == .audio } ? 1 : 0.45)
        } else {
            HStack(spacing: 10) {
                Button { player.play(tracks: tracks, startAt: 0, source: .source(source)) } label: {
                    ctaLabel(icon: "play.fill", title: "Play")
                }
                Button {
                    player.shuffle = true
                    player.play(tracks: tracks.shuffled(), startAt: 0, source: .source(source))
                } label: {
                    ctaLabel(icon: "shuffle", title: "Shuffle")
                }
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
        .frame(maxWidth: .infinity).frame(height: 42)
        .glassSurface(cornerRadius: 21)
    }

    private func load() async {
        if isRemoteLibrary {
            await loadRemote(path: remotePath)
        } else {
            tracks = await appState.tracks(for: source)
            heroArtworkId = await appState.firstArtworkId(for: source)
        }
    }

    private func loadRemote(path: String) async {
        isLoadingRemote = true
        remoteError = nil
        defer { isLoadingRemote = false }
        do {
            remoteNodes = try await appState.browseRemote(source: source, path: path)
            remotePath = path
        } catch {
            remoteNodes = []
            remoteError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func selectRemoteNode(_ node: RemoteNode) async {
        switch node.kind {
        case .directory, .collection:
            remoteBackStack.append(remotePath)
            await loadRemote(path: node.path)
        case .audio:
            let audioNodes = remoteNodes.filter { $0.kind == .audio }
            guard let start = audioNodes.firstIndex(where: { $0.id == node.id }) else { return }
            await playRemote(nodes: audioNodes, startAt: start, shuffled: false)
        case .item:
            break
        }
    }

    private func goBackRemote() async {
        guard let previous = remoteBackStack.popLast() else { return }
        await loadRemote(path: previous)
    }

    private func playVisibleRemote(startAt: Int, shuffled: Bool) async {
        let audioNodes = remoteNodes.filter { $0.kind == .audio }
        guard !audioNodes.isEmpty else { return }
        await playRemote(nodes: audioNodes, startAt: startAt, shuffled: shuffled)
    }

    private func playRemote(nodes: [RemoteNode], startAt: Int, shuffled: Bool) async {
        do {
            var rows = try await appState.remoteTrackRows(source: source, nodes: nodes)
            if shuffled {
                player.shuffle = true
                rows.shuffle()
            }
            player.play(tracks: rows, startAt: min(startAt, max(rows.count - 1, 0)), source: .source(source))
        } catch {
            remoteError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func icon(for node: RemoteNode) -> String {
        switch node.kind {
        case .directory: return "person.crop.circle"
        case .collection: return "rectangle.stack"
        case .audio: return "music.note"
        case .item: return "square.stack"
        }
    }

    private func subtitle(for node: RemoteNode) -> String? {
        switch node.kind {
        case .directory:
            return source.kind == .webDAV || source.kind == .smb || isCloudSource ? "Folder" : "Artist"
        case .collection:
            return "Album"
        case .audio:
            return node.durationSec.map(durationString) ?? "Song"
        case .item:
            return nil
        }
    }

    private func durationString(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private var isRemoteLibrary: Bool {
        RemoteLibraryAccessPolicy.isRemoteLibrary(source.kind)
    }

    private var isArchiveSource: Bool {
        switch source.kind {
        case .iaItem, .iaList, .iaCollection, .iaFavorites:
            return true
        default:
            return false
        }
    }

    private var isCloudSource: Bool {
        CloudDriveAPI.Provider(sourceKind: source.kind) != nil
    }

    private var remoteProviderName: String {
        RemoteConnectorCatalog.connector(for: source.kind)?.title ?? "Remote"
    }
}

private struct RemoteNodeRow: View {
    var icon: String
    var title: String
    var subtitle: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(Palette.brass)
                .frame(width: 36, height: 36)
                .glassSurface(cornerRadius: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13.5, weight: .medium)).lineLimit(1)
                if let subtitle {
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(Palette.ink3).lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }
}
