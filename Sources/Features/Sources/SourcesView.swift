import SwiftUI
import TonearmCore

/// A zero-configuration "Services" entry, distinct from a persisted `Source`
/// (see `JamendoBrowseView`'s doc comment) — its own navigation value so it
/// can push alongside `Source` on the same stack without pretending to be one.
enum LibraryService: String, Hashable, Identifiable {
    case jamendo
    var id: String { rawValue }
    var title: String { "Jamendo" }
}

struct SourcesView: View {
    @EnvironmentObject var appState: AppState
    /// Settings already owns a `NavigationStack` when pushing this as
    /// "Music Libraries" — a second nested stack there makes the push
    /// unstable (same reasoning as `LibraryView.ownsNavigationStack`).
    private let ownsNavigationStack: Bool

    init(ownsNavigationStack: Bool = true) {
        self.ownsNavigationStack = ownsNavigationStack
    }

    var body: some View {
        Group {
            if ownsNavigationStack {
                NavigationStack { content }
            } else {
                content
            }
        }
    }

    @ViewBuilder
    private var content: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ScreenHeader(title: "Libraries")
                        .padding(.bottom, 12)

                    SectionHeader(title: "Services")
                    NavigationLink(value: LibraryService.jamendo) {
                        LibraryServiceRow(service: .jamendo)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("Service Jamendo")
                    Divider().overlay(Palette.hairline)

                    SectionHeader(title: "Personal")
                        .padding(.top, 18)

                    if appState.sources.isEmpty {
                        EmptyStateView(icon: "cloud",
                                       title: "No libraries yet",
                                       message: "Paste an archive.org link, add a local folder, or connect a remote library.")
                            .padding(.top, 40)
                    } else {
                        ForEach(appState.sources) { source in
                            NavigationLink(value: source) {
                                SourceRow(source: source)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("Source \(source.title)")
                            .contextMenu {
                                Button("Play") { Task { await appState.playSource(source) } }
                                Button("Remove", role: .destructive) {
                                    Task { await appState.deleteSource(source) }
                                }
                            }
                            Divider().overlay(Palette.hairline)
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 160)
            }
            .background(Palette.sourcesBackground.ignoresSafeArea())
            .foregroundStyle(Palette.ink)
            .navigationDestination(for: Source.self) { source in
                SourceDetailView(source: source)
            }
            .navigationDestination(for: LibraryService.self) { service in
                switch service {
                case .jamendo: JamendoBrowseView()
                }
            }
            #if !os(macOS)
            .toolbar(.hidden, for: .navigationBar)
            #endif
            // Real report: "Settings -> Libraries -> '+' does nothing." Root
            // cause: `ScreenHeader`'s default "+" sets `appState.showAddMenu`,
            // which only `RootView` listens for via `.sheet(isPresented:)` —
            // but this screen is always reached nested inside Settings' own
            // `.sheet(item: $activeSheet)` (SettingsView.swift), so RootView's
            // copy of the view hierarchy is already covered by that sheet and
            // can't present a second one on top of it. Attaching the same
            // sheet here too lets it present from the actually-frontmost
            // context (same SwiftUI multi-sheet-nesting issue already fixed
            // once for Settings itself — see SettingsSheet's doc comment).
            .sheet(isPresented: Binding(
                get: { appState.showAddMenu },
                set: { appState.showAddMenu = $0 })) {
                AddMenuSheet()
            }
            // Same nested-sheet issue as above, one step further down the
            // flow: AddMenuSheet's own choices (RootView.swift) set these
            // same three things, which RootView also listens for — but by
            // the time AddMenuSheet's 0.35s dismiss delay fires, the
            // frontmost context is this screen's own sheet again, not
            // RootView's. Mirrors RootView's identical modifiers so "Add
            // Remote Library" / "Add Local Folder" / "Add Audio Files"
            // actually present from here too.
            .sheet(isPresented: Binding(
                get: { appState.showAddSource },
                set: { appState.showAddSource = $0 })) {
                AddSourceSheet()
            }
            .sheet(isPresented: Binding(
                get: { appState.showAddRemoteLibrary },
                set: { appState.showAddRemoteLibrary = $0 })) {
                AddServerSheet()
            }
            .sheet(item: Binding(
                get: { appState.pickedFolder },
                set: { appState.pickedFolder = $0 })) { url in
                AddFolderSheet(folderURL: url, folderBookmark: appState.pickedFolderBookmark)
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
    }
}

struct LibraryServiceRow: View {
    let service: LibraryService

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Palette.brass)
                .frame(width: 42, height: 42)
                .glassSurface(cornerRadius: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text(service.title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                Text("Browse by genre or search · streams from Jamendo")
                    .font(.system(size: 11.5)).foregroundStyle(Palette.ink3).lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 13)).foregroundStyle(Palette.ink3)
        }
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }
}

struct SourceRow: View {
    let source: Source

    var body: some View {
        HStack(spacing: 12) {
            SourceArtworkView(source: source, cornerRadius: 9)
                .frame(width: 42, height: 42)
            VStack(alignment: .leading, spacing: 2) {
                Text(source.title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                Text(subtitle).font(.system(size: 11.5)).foregroundStyle(Palette.ink3).lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 13)).foregroundStyle(Palette.ink3)
        }
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        switch source.kind {
        case .local: return "On device"
        case .iaItem: return "Item · streams from archive.org"
        case .iaList: return "List · streams from archive.org"
        case .iaCollection: return "Collection · streams from archive.org"
        case .iaFavorites: return "Favorites · streams from archive.org"
        case .subsonic, .webDAV, .smb, .jellyfin, .plex, .dropbox, .googleDrive, .oneDrive, .pCloud, .jamendoGenre:
            return "\(RemoteConnectorCatalog.connector(for: source.kind)?.title ?? "Remote") library"
        }
    }
}
