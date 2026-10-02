import SwiftUI
import TonearmCore
import UniformTypeIdentifiers

/// Every app-wide sheet, importer and picker that `AppState` can request —
/// onboarding, Add Music, Build a Mix, new playlist, sources/servers, the
/// file importer, custom-artwork picker and metadata editor. Shared by the
/// iPhone `RootView` and the Mac `MacRootView` so a flow added for one
/// platform can never silently be missing from the other.
struct AppPresentations: ViewModifier {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var player: AudioPlayer

    func body(content: Content) -> some View {
        content
            .modifier(OnboardingPresentation(isPresented: Binding(
                get: { !appState.didOnboard },
                set: { if $0 == false { appState.didOnboard = true } })))
            .sheet(isPresented: $appState.showAddMenu) {
                AddMenuSheet()
                    #if os(iOS)
                    .presentationDetents([.height(365)])
                    .presentationBackground(.clear)
                    #else
                    .frame(width: 420, height: 340)
                    #endif
            }
            .sheet(isPresented: $appState.showCreatePlaylist) {
                CreatePlaylistSheet()
                    .macSheetFrame(minWidth: 420, minHeight: 480)
            }
            .sheet(item: $appState.mixBuilderRequest) { request in
                MixBuilderSheet(rows: request.rows, lockedFirst: request.lockedFirst,
                                sourcePlaylist: request.sourcePlaylist,
                                picksSource: request.picksSource)
                    .macSheetFrame(minWidth: 560, minHeight: 640)
            }
            #if os(iOS)
            .sheet(isPresented: $appState.showWatchSettings) {
                WatchSettingsView()
            }
            #endif
            .sheet(isPresented: $appState.showAddSource) {
                AddSourceSheet()
                    .macSheetFrame(minWidth: 460, minHeight: 520)
            }
            .sheet(isPresented: $appState.showAddRemoteLibrary) {
                AddServerSheet()
                    .macSheetFrame(minWidth: 460, minHeight: 560)
            }
            .sheet(item: $appState.pickedFolder) { url in
                AddFolderSheet(folderURL: url, folderBookmark: appState.pickedFolderBookmark)
                    .macSheetFrame(minWidth: 460, minHeight: 420)
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
                AppImport.route(urls, asSMB: appState.pendingImport == .smbFolder, appState: appState)
                appState.pendingImport = nil
            }
            // On its own (background) view: a Mac picker is a file importer
            // too, and two importers on one view do not both present.
            .background {
                Color.clear.artworkImagePicker(isPresented: Binding(
                    get: { appState.artworkChangeTrackRow != nil },
                    set: { if !$0 { appState.artworkChangeTrackRow = nil } })) { data in
                    guard let row = appState.artworkChangeTrackRow,
                          await appState.assignCustomArtwork(toTrack: row, data: data) else { return }
                    ArtworkInvalidation.shared.invalidate()
                    appState.artworkChangeTrackRow = nil
                }
            }
            .sheet(item: $appState.metadataEditTrackRow) { row in
                EditTrackMetadataSheet(row: row)
                    .macSheetFrame(minWidth: 460, minHeight: 520)
            }
    }
}

/// What to do with folders/files the user picked in the importer or (on Mac)
/// dropped onto the window: a folder opens the Add Folder options sheet, audio
/// files are imported straight into the library.
@MainActor
enum AppImport {
    static func route(_ urls: [URL], asSMB: Bool, appState: AppState) {
        switch ImportRouter.route(urls) {
        case .folder(let url):
            let bookmark = BookmarkVault.makeBookmark(for: url)
            if asSMB {
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
                        "Imported \(summary.imported), skipped \(summary.skippedDuplicates) already in your library")
                }
            }
        case .none:
            break
        }
    }

    /// Keeps only what the library can ingest from a drop: one folder, or
    /// audio files.
    static func importable(_ urls: [URL]) -> [URL] {
        if let folder = urls.first(where: \.hasDirectoryPath) { return [folder] }
        return urls.filter { url in
            (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
                .map { $0.conforms(to: .audio) } ?? false
        }
    }
}

/// The transient top-of-window banners: "Adding <library>…" while a library
/// is being added in the background, and the network-skip notice.
struct AppStatusBanners: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var player: AudioPlayer

    var body: some View {
        ZStack(alignment: .top) {
            if let title = appState.backgroundTitle {
                backgroundBanner(title)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .motion(Motion.standard, value: appState.backgroundTitle)
            }

            if let message = player.networkSkipMessage {
                skipBanner(message)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .motion(Motion.standard, value: player.networkSkipMessage)
            }
        }
    }

    private func backgroundBanner(_ title: String) -> some View {
        VStack {
            HStack(spacing: 10) {
                if appState.backgroundDone {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Palette.success)
                } else if appState.backgroundFailed {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Palette.danger)
                } else {
                    ProgressView()
                        .tint(Palette.accent)
                }
                Text(appState.backgroundDone ? "Added \"\(title)\""
                     : appState.backgroundFailed ? "Failed to add \"\(title)\""
                     : "Adding \"\(title)\"…")
                    .font(Typography.callout)
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
                    .foregroundStyle(Palette.accent)
                Text(message)
                    .font(Typography.callout)
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

/// iPhone onboarding is a full-screen cover; a Mac has no full-screen cover,
/// so it is a sized sheet over the main window.
private struct OnboardingPresentation: ViewModifier {
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        #if os(iOS)
        content.fullScreenCover(isPresented: $isPresented) { OnboardingView() }
        #else
        content.sheet(isPresented: $isPresented) {
            OnboardingView().frame(minWidth: 640, minHeight: 560)
        }
        #endif
    }
}

extension View {
    /// A Mac sheet sizes to its content's ideal size, which for these
    /// phone-shaped forms is far too small; iPhone sheets fill the screen.
    @ViewBuilder
    func macSheetFrame(minWidth: CGFloat, minHeight: CGFloat) -> some View {
        #if os(macOS)
        frame(minWidth: minWidth, minHeight: minHeight)
        #else
        self
        #endif
    }
}
