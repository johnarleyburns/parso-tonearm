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
        }
        .tint(Palette.brass)
        .fullScreenCover(isPresented: Binding(
            get: { !appState.didOnboard },
            set: { if $0 == false { appState.didOnboard = true } })) {
            OnboardingView()
        }
        .sheet(isPresented: $appState.showAddMenu, onDismiss: handlePendingImport) {
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
            AddFolderSheet(folderURL: url)
        }
        .fileImporter(isPresented: $appState.showFolderImporter,
                      allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                appState.pickedFolder = url
            }
        }
        .fileImporter(isPresented: $appState.showFileImporter,
                      allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                Task {
                    await IngestService().addFiles(urls, into: appState.store)
                    await appState.reload()
                    appState.tab = .library
                }
            }
        }
    }

    private func handlePendingImport() {
        switch appState.pendingImport {
        case .folder: appState.showFolderImporter = true
        case .files: appState.showFileImporter = true
        case .none: break
        }
        appState.pendingImport = nil
    }

    private var backgroundLayer: some View {
        Group {
            switch appState.tab {
            case .sources: Palette.sourcesBackground
            default: Palette.libraryBackground
            }
        }
    }
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}
