import SwiftUI
import UIKit
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
    @State private var showRename = false
    @State private var renameText = ""
    @State private var showCredentialEdit = false
    @State private var stats: RemoteLibraryStats?
    @State private var isLoadingStats = false
    @State private var statsError: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                navRow
                hero
                content
                if isRemoteLibrary {
                    remoteManagementSection
                }
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
        .task(id: source.id) {
            guard isRemoteLibrary else { return }
            await loadStats()
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
                            subtitle: subtitle(for: node),
                            artwork: node.metadata?.artwork
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
                Button {
                    Task { await appState.download(rows: tracks) }
                } label: {
                    Label("Download All", systemImage: "arrow.down.circle")
                }
                Button {
                    Task { await appState.downloadToWatch(rows: tracks) }
                } label: {
                    Label("Download All to Watch", systemImage: "applewatch")
                }
                Button {
                    Task { await appState.removeFromWatch(rows: tracks) }
                } label: {
                    Label("Remove All from Watch", systemImage: "applewatch.slash")
                }
                Divider()
                Button("Remove Library", role: .destructive) {
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
            Group {
                if isRemoteLibrary,
                   let firstArtwork = remoteNodes.lazy.compactMap({ $0.metadata?.artwork }).first {
                    RemoteArtworkImageView(artwork: firstArtwork, seed: source.title, cornerRadius: 18)
                } else {
                    SourceArtworkView(source: source, cornerRadius: 18)
                }
            }
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
            var parts: [String] = []
            if let artist = node.metadata?.artist ?? node.metadata?.albumArtist, !artist.isEmpty {
                parts.append(artist)
            }
            if let album = node.metadata?.album, !album.isEmpty {
                parts.append(album)
            }
            if let duration = node.metadata?.durationSec ?? node.durationSec {
                parts.append(durationString(duration))
            }
            return parts.isEmpty ? "Song" : parts.joined(separator: " · ")
        case .item:
            return nil
        }
    }

    private func durationString(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func loadStats() async {
        isLoadingStats = true
        statsError = nil
        defer { isLoadingStats = false }
        if let result = await appState.remoteStats(for: source) {
            stats = result
        } else {
            statsError = "Stats unavailable"
        }
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

    private var remoteManagementSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Library Settings")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Palette.ink3)
                .padding(.top, 24)
                .padding(.bottom, 10)

            VStack(spacing: 0) {
                managementRow(label: "Provider", value: remoteProviderName)
                Divider().overlay(Palette.hairline)

                if let url = source.originalURL {
                    managementRow(label: "URL", value: url)
                    Divider().overlay(Palette.hairline)
                }

                if let account = appState.remoteAccountLabel(for: source) {
                    managementRow(label: "Account", value: account)
                    Divider().overlay(Palette.hairline)
                }

                if let status = appState.remoteCredentialStatus(for: source) {
                    managementRow(label: "Credentials", value: status)
                    Divider().overlay(Palette.hairline)
                }

                Button {
                    Task { await loadStats() }
                } label: {
                    Group {
                        if isLoadingStats {
                            HStack {
                                Text("Stats")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(Palette.ink3)
                                Spacer()
                                ProgressView().tint(Palette.brass).scaleEffect(0.7)
                            }
                        } else if let _ = statsError {
                            managementRow(label: "Stats", value: "Tap to retry", chevron: false)
                        } else if let s = stats {
                            managementRow(label: "Stats", value: s.formattedSummary, chevron: false)
                        } else {
                            managementRow(label: "Stats", value: "Tap to load", chevron: false)
                        }
                    }
                }
                .buttonStyle(.plain)
                Divider().overlay(Palette.hairline)

                makeOfflineRow
                Divider().overlay(Palette.hairline)

                Button {
                    renameText = source.title
                    showRename = true
                } label: {
                    managementRow(label: "Display Name", value: source.title, chevron: true)
                }
                .buttonStyle(.plain)
                Divider().overlay(Palette.hairline)

                Button {
                    showCredentialEdit = true
                } label: {
                    managementRow(label: "Update Credentials", value: "Change password or token", chevron: true)
                }
                .buttonStyle(.plain)
            }
            .glassSurface(cornerRadius: 14)
        }
        .alert("Rename Library", isPresented: $showRename) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                if !renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Task { await appState.renameSource(source, title: renameText) }
                }
            }
        }
        .alert("Update Credentials", isPresented: $showCredentialEdit) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("To update credentials, remove and re-add this library.")
        }
    }

    @ViewBuilder
    private var makeOfflineRow: some View {
        let isThisSource = source.id == appState.offlineSourceID
        let progress = appState.offlineProgress

        if let progress, isThisSource {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Make Offline")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.ink3)
                    Spacer()
                    if progress.isDone {
                        Text("✓ \(progress.completed) of \(progress.total)")
                            .font(.system(size: 12)).foregroundStyle(Palette.ok)
                    } else if let msg = progress.message {
                        Text(msg)
                            .font(.system(size: 11)).foregroundStyle(Palette.danger)
                    } else {
                        Text("\(progress.completed) / \(progress.total)")
                            .font(.system(size: 12)).foregroundStyle(Palette.ink2)
                            .monospacedDigit()
                    }
                }
                if !progress.isDone {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.1))
                            Capsule().fill(Palette.brass)
                                .frame(width: geo.size.width * progress.fraction)
                        }
                    }
                    .frame(height: 5)

                    Button("Cancel") {
                        appState.cancelOffline()
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.danger)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
        } else {
            Button {
                Task { await appState.makeOffline(source: source) }
            } label: {
                HStack {
                    Text("Make Offline")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.ink3)
                    Spacer()
                    Text("Download for offline playback")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.ink2)
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 14))
                        .foregroundStyle(Palette.brass)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
    }

    private func managementRow(label: String, value: String, chevron: Bool = false) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.ink3)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .regular, design: label == "URL" ? .monospaced : .default))
                .foregroundStyle(Palette.ink2)
                .lineLimit(1)
                .truncationMode(.middle)
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.ink3)
                    .padding(.leading, 4)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }
}

private struct RemoteNodeRow: View {
    var icon: String
    var title: String
    var subtitle: String?
    var artwork: RemoteArtwork?

    var body: some View {
        HStack(spacing: 12) {
            if let artwork {
                RemoteArtworkImageView(artwork: artwork, seed: title, cornerRadius: 9)
                    .frame(width: 36, height: 36)
            } else {
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .foregroundStyle(Palette.brass)
                    .frame(width: 36, height: 36)
                    .glassSurface(cornerRadius: 18)
            }
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

private struct RemoteArtworkImageView: View {
    let artwork: RemoteArtwork
    let seed: String
    let cornerRadius: CGFloat

    @State private var image: UIImage?

    var body: some View {
        ArtworkView(image: image, seed: seed, cornerRadius: cornerRadius)
            .task(id: artwork.id ?? artwork.url?.absoluteString ?? seed) {
                image = await RemoteArtworkCache.shared.load(artwork)
            }
    }
}

private actor RemoteArtworkCache {
    static let shared = RemoteArtworkCache()

    private var cache: [String: UIImage] = [:]
    private var tasks: [String: Task<UIImage?, Never>] = [:]

    func load(_ artwork: RemoteArtwork) async -> UIImage? {
        let cacheKey = artwork.id ?? artwork.url?.absoluteString ?? ""
        if let img = cache[cacheKey] { return img }
        return await performFetch(artwork)
    }

    private func performFetch(_ artwork: RemoteArtwork) async -> UIImage? {
        let cacheKey = artwork.id ?? artwork.url?.absoluteString ?? UUID().uuidString
        if let existing = tasks[cacheKey] { return await existing.value }

        let task = Task<UIImage?, Never> {
            guard let url = artwork.url else { return nil }
            var request = URLRequest(url: url)
            for (key, value) in artwork.headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
            guard let (data, _) = try? await URLSession.shared.data(for: request),
                  let img = UIImage(data: data) else { return nil }
            return img
        }
        tasks[cacheKey] = task
        let result = await task.value
        if let img = result {
            cache[cacheKey] = img
        }
        tasks[cacheKey] = nil
        return result
    }
}
