import SwiftUI
import PhotosUI
import TonearmCore

/// Split across files by concern: this file keeps the struct's stored state and
/// its primary layout (`body`/`content`/`localTrackList`/`remoteBrowser`/
/// `navRow`/`hero`/`badge`/`cta`); `SourceDetailView+Remote.swift` has the
/// remote-browsing logic and derived state, `SourceDetailView+ManagementSection.swift`
/// has the "Library Settings" section. Several `@State` properties and a few
/// computed properties/methods are used from those other files, so they are
/// `internal` (not `private`) here — Swift's `private` is scoped to this file.
struct SourceDetailView: View {
    let source: Source
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var player: AudioPlayer
    @Environment(\.dismiss) private var dismiss
    @State var tracks: [TrackRow] = []
    @State var heroArtworkId: String?
    @State var remoteNodes: [RemoteNode] = []
    @State var remotePath = ""
    @State var remoteBackStack: [String] = []
    @State var remoteError: String?
    @State var isLoadingRemote = false
    @State var showRename = false
    @State var renameText = ""
    @State var showCredentialEdit = false
    @State var stats: RemoteLibraryStats?
    @State var isLoadingStats = false
    @State var statsError: String?
    @State private var showAddToPlaylist = false
    @State private var showArtworkPicker = false
    @State private var artworkPickerItem: PhotosPickerItem?
    @State private var showRemoveArtworkAlert = false

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
        .sheet(isPresented: $showAddToPlaylist) {
            AddRemoteTracksSheet(source: source, nodes: audioNodesInScope, scopeTitle: scopeTitle)
        }
    }

    @ViewBuilder
    private var content: some View {
        if isBrowseableServer {
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
                    .accessibilityIdentifier("remote.node.\(node.id)")
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
            .accessibilityIdentifier("source.back")
            Spacer()
            if isRemoteLibrary {
                Button { showAddToPlaylist = true } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 15)).foregroundStyle(Palette.brass)
                        .frame(width: 33, height: 33).glassSurface(cornerRadius: 16.5)
                }
                .accessibilityLabel("Add tracks to playlist")
                .accessibilityIdentifier("source.addToPlaylist")
            }
            Menu {
                Button {
                    Task { await appState.download(rows: tracks) }
                } label: {
                    Label("Download All", systemImage: "arrow.down.circle")
                }
                #if !os(macOS)
                Button {
                    Task { await appState.downloadToWatch(rows: tracks) }
                } label: {
                    Label("Download All to Apple Watch", systemImage: "applewatch")
                }
                Button {
                    Task { await appState.removeFromWatch(rows: tracks) }
                } label: {
                    Label("Remove All from Apple Watch", systemImage: "applewatch.slash")
                }
                #endif
                Divider()
                Button {
                    showArtworkPicker = true
                } label: {
                    Label("Change Artwork", systemImage: "photo.badge.plus")
                }
                Button(role: .destructive) {
                    showRemoveArtworkAlert = true
                } label: {
                    Label("Remove Artwork", systemImage: "trash")
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
        .photosPicker(isPresented: $showArtworkPicker, selection: $artworkPickerItem, matching: .images)
        .onChange(of: artworkPickerItem) { _, item in
            guard let item, let sourceId = source.id else { return }
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self),
                      await appState.assignCustomArtwork(sourceId: sourceId, data: data) else { return }
                ArtworkInvalidation.shared.invalidate()
                artworkPickerItem = nil
            }
        }
        .alert("Remove Artwork", isPresented: $showRemoveArtworkAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) {
                guard let sourceId = source.id else { return }
                Task {
                    await appState.clearCustomArtwork(sourceId: sourceId)
                    ArtworkInvalidation.shared.invalidate()
                }
            }
        } message: {
            Text("This will remove the custom artwork for this library.")
        }
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
        if source.kind == .jamendoGenre { return "Jamendo · \(source.licenseText ?? "Creative Commons")" }
        if isArchiveSource { return "archive.org · \(source.licenseText ?? "streams permitted")" }
        if isRemoteLibrary { return "\(remoteProviderName) · private library" }
        return "archive.org · \(source.licenseText ?? "streams permitted")"
    }

    @ViewBuilder
    private var cta: some View {
        if isBrowseableServer {
            HStack(spacing: 10) {
                Button { Task { await playVisibleRemote(startAt: 0, shuffled: false) } } label: {
                    ctaLabel(icon: "play.fill", title: "Play")
                }
                Button { Task { await playVisibleRemote(startAt: 0, shuffled: true) } } label: {
                    ctaLabel(icon: "shuffle", title: "Shuffle")
                }
            }
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
}
