import SwiftUI

struct RootView: View {    @EnvironmentObject var appState: AppState
    @EnvironmentObject var player: AudioPlayer

    var body: some View {
        ZStack(alignment: .bottom) {
            backgroundLayer.ignoresSafeArea()

            Group {
                switch appState.tab {
                case .listen: ListenView()
                case .playlists: PlaylistsView()
                case .library: LibraryView()
                case .sources: SourcesView()
                case .settings: SettingsView()
                }
            }

            GlassDock()
                .padding(.bottom, 8)

            if let title = appState.backgroundTitle {
                backgroundBanner(title)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .animation(.easeInOut(duration: 0.3), value: appState.backgroundTitle)
            }
        }
        .tint(Palette.brass)
        .fullScreenCover(isPresented: Binding(
            get: { !appState.didOnboard },
            set: { if $0 == false { appState.didOnboard = true } })) {
            OnboardingView()
        }
        .sheet(isPresented: $appState.showAddMenu) {
            AddMenuSheet()
                .presentationDetents([.height(300)])
                .presentationBackground(.clear)
        }
        .sheet(isPresented: $appState.showCreatePlaylist) {
            CreatePlaylistSheet()
        }
        .sheet(isPresented: $appState.showNowPlaying) {
            NowPlayingView()
        }
        .sheet(isPresented: $appState.showAddSource) {
            AddSourceSheet()
        }
        .sheet(item: $appState.pickedFolder) { url in
            AddFolderSheet(folderURL: url, folderBookmark: appState.pickedFolderBookmark)
        }
        .fileImporter(
            isPresented: Binding(get: { appState.pendingImport != nil },
                                 set: { if !$0 { appState.pendingImport = nil } }),
            allowedContentTypes: appState.pendingImport == .folder ? [.folder] : [.audio],
            allowsMultipleSelection: appState.pendingImport == .files
        ) { result in
            guard case .success(let urls) = result else {
                appState.pendingImport = nil
                return
            }
            switch ImportRouter.route(urls) {
            case .folder(let url):
                let didScope = url.startAccessingSecurityScopedResource()
                let bookmark = try? url.bookmarkData(options: [.minimalBookmark],
                                                      includingResourceValuesForKeys: nil,
                                                      relativeTo: nil)
                if didScope { url.stopAccessingSecurityScopedResource() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
                    appState.pickedFolder = url
                    appState.pickedFolderBookmark = bookmark
                }
            case .files(let urls):
                Task {
                    await IngestService().addFiles(urls, into: appState.store)
                    await appState.reload()
                    appState.tab = .library
                }
            case .none:
                break
            }
            appState.pendingImport = nil
        }
    }

    private var backgroundLayer: some View {
        Group {
            switch appState.tab {
            case .sources: Palette.sourcesBackground
            default: Palette.libraryBackground
            }
        }
    }

    private func backgroundBanner(_ title: String) -> some View {
        VStack {
            HStack(spacing: 10) {
                if appState.backgroundDone {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Palette.ok)
                } else if appState.backgroundFailed {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Palette.danger)
                } else {
                    ProgressView()
                        .tint(Palette.brass)
                }
                Text(appState.backgroundDone ? "Added \"\(title)\""
                     : appState.backgroundFailed ? "Failed to add \"\(title)\""
                     : "Adding \"\(title)\"…")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Palette.ink)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 16)
            .padding(.top, 8)

            Spacer()
        }
    }
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}
