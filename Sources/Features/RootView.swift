import SwiftUI
import PhotosUI
import TonearmCore

struct RootView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var player: AudioPlayer
    @State private var showSplash = !ProcessInfo.processInfo.arguments.contains("UI_TESTING")
    @State private var artworkPickerItem: PhotosPickerItem?

    var body: some View {
        ZStack(alignment: .bottom) {
            // AnimatedSplashView's own opacity fades in from 0, and it used to
            // sit as an overlay directly above the real content (tabs + dock),
            // both already built and rendering underneath — during that
            // fade-in, the real content was genuinely visible through it
            // (reported as "briefly seeing my last-used tab, very wide, then
            // the splash"). Building the real content only once the splash is
            // done removes anything for it to fade in over.
            if showSplash && appState.didOnboard {
                AnimatedSplashView(isPresented: $showSplash)
                    .zIndex(10)
            } else {
                backgroundLayer.ignoresSafeArea()

                Group {
                    switch appState.tab {
                    case .listen: ListenView()
                    case .myMusic: MyMusicView()
                    case .dj: DJView()
                    case .settings: SettingsView()
                    }
                }

                // The dock steps aside for a performance surface: the decks own
                // the bottom edge (§42.7a), and an overlay there is not merely
                // untidy — it swallows the crossfader's touches.
                if !appState.isPerformanceSurfaceFullScreen {
                    GlassDock()
                        .padding(.bottom, 8)
                }

                if let title = appState.backgroundTitle {
                    backgroundBanner(title)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .animation(.easeInOut(duration: 0.3), value: appState.backgroundTitle)
                }

                if let message = player.networkSkipMessage {
                    skipBanner(message)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .animation(.easeInOut(duration: 0.3), value: player.networkSkipMessage)
                }
            }
        }
        .toastLayer(bottomInset: 96)
        .task { await announceWatchConnection() }
        .tint(Palette.brass)
        #if os(macOS)
        .sheet(isPresented: Binding(
            get: { !appState.didOnboard },
            set: { if $0 == false { appState.didOnboard = true } })) {
            OnboardingView()
        }
        #else
        .fullScreenCover(isPresented: Binding(
            get: { !appState.didOnboard },
            set: { if $0 == false { appState.didOnboard = true } })) {
            OnboardingView()
        }
        #endif
        .sheet(isPresented: $appState.showAddMenu) {
            AddMenuSheet()
                .presentationDetents([.height(365)])
                .presentationBackground(.clear)
        }
        .sheet(isPresented: $appState.showCreatePlaylist) {
            CreatePlaylistSheet()
        }
        .sheet(isPresented: $appState.showNowPlaying) {
            NowPlayingView()
        }
        .sheet(isPresented: $appState.showWatchSettings) {
            WatchSettingsView()
        }
        .sheet(isPresented: $appState.showAddSource) {
            AddSourceSheet()
        }
        .sheet(isPresented: $appState.showAddRemoteLibrary) {
            AddServerSheet()
        }
        .sheet(item: $appState.pickedFolder) { url in
            AddFolderSheet(folderURL: url, folderBookmark: appState.pickedFolderBookmark)
        }
        .onChange(of: player.networkSkipMessage) { _, message in
            guard message != nil else { return }
            Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                await MainActor.run { player.networkSkipMessage = nil }
            }
        }
        .fileImporter(
            isPresented: Binding(get: { appState.pendingImport != nil },
                                 set: { if !$0 { appState.pendingImport = nil } }),
            allowedContentTypes: appState.pendingImport == .files ? [.audio] : [.folder],
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
                if appState.pendingImport == .smbFolder {
                    Task {
                        try? await appState.addSMBFolder(url, bookmark: bookmark)
                    }
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
                        appState.pickedFolder = url
                        appState.pickedFolderBookmark = bookmark
                    }
                }
            case .files(let urls):
                Task {
                    let summary = await IngestService().addFiles(urls, into: appState.store)
                    await appState.reload()
                    appState.tab = .myMusic
                    if summary.skippedDuplicates > 0 {
                        ToastCenter.shared.info(
                            "Imported \(summary.imported), skipped \(summary.skippedDuplicates) "
                                + "already in your library")
                    }
                }
            case .none:
                break
            }
            appState.pendingImport = nil
        }
        .photosPicker(isPresented: Binding(
            get: { appState.artworkChangeTrackRow != nil },
            set: { if !$0 { appState.artworkChangeTrackRow = nil } }),
                      selection: $artworkPickerItem,
                      matching: .images)
        .sheet(item: $appState.metadataEditTrackRow) { row in
            EditTrackMetadataSheet(row: row)
        }
        .onChange(of: artworkPickerItem) { _, item in
            guard let item,
                  let row = appState.artworkChangeTrackRow else { return }
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self),
                      await appState.assignCustomArtwork(toTrack: row, data: data) else { return }
                ArtworkInvalidation.shared.invalidate()
                artworkPickerItem = nil
                appState.artworkChangeTrackRow = nil
            }
        }
    }

    // MARK: - Apple Watch connection toast

    /// On launch, if a watch is paired, say we're connecting, then resolve to "Connected" or
    /// "not reachable" once the session settles. Skipped in UI tests.
    private func announceWatchConnection() async {
        guard !ProcessInfo.processInfo.arguments.contains("UI_TESTING") else { return }
        guard appState.watchSessionState == .installedNotReachable
                || appState.watchSessionState == .reachable else { return }

        ToastCenter.shared.progress("Connecting to Apple Watch…", icon: "applewatch", tag: "watch.link")
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline {
            if appState.watchSessionState == .reachable {
                ToastCenter.shared.success("Connected to Apple Watch", icon: "applewatch", tag: "watch.link")
                return
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        ToastCenter.shared.info("Apple Watch not reachable", icon: "applewatch.slash", tag: "watch.link")
    }

    private var backgroundLayer: some View {
        Palette.libraryBackground
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
        .onAppear {
            if !appState.didOnboard { showSplash = false }
        }
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

    private func skipBanner(_ message: String) -> some View {
        VStack {
            HStack(spacing: 10) {
                Image(systemName: "wifi.slash")
                    .foregroundStyle(Palette.brass)
                Text(message)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(2)
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
