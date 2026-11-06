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

/// Navigation value for a connected provider's own instance list (`ProviderInstancesView`).
/// Carries only the connector's id, not the `RemoteConnector` itself — `RemoteConnector` isn't
/// `Hashable` (and making it so would cascade through `RemoteConnectorTier`/`RemoteConnectorAuthKind`/
/// `RemoteConnectorGuide`), while `NavigationLink(value:)` needs `Hashable`. The destination looks
/// the connector back up by id.
private struct ProviderInstancesTarget: Hashable {
    let connectorID: String
}

/// Every place the user pulls music from: local folders, plus one row per remote provider this
/// app knows how to connect, Jamendo included — not just the ones already connected. A real
/// report: the old "Personal" list only ever showed connections you'd already made, with no way
/// to see or reach the rest except through one shared, multi-provider "Add Remote Library" sheet.
/// Each provider's own row now opens that provider's own connect dialog directly.
struct SourcesView: View {
    @EnvironmentObject var appState: AppState
    /// Settings already owns a `NavigationStack` when pushing this as
    /// "Music Libraries" — a second nested stack there makes the push
    /// unstable (same reasoning as `LibraryView.ownsNavigationStack`).
    private let ownsNavigationStack: Bool
    /// Drives the per-provider connect sheet (`AddServerSheet(fixedConnector:)`) — set by tapping
    /// any not-yet-connected row, remote-catalog or Jamendo's "set a key" fallback alike.
    @State private var connectingConnector: RemoteConnector?
    @State private var showJamendoCredential = false
    /// Owned here (not just a plain `NavigationStack {}`) so a successful connect can push
    /// straight into the new source's browse view — real report: connecting Dropbox left the
    /// user back at this connector list instead of inside the new Dropbox library. Shared with
    /// `ProviderInstancesView` (passed down as a binding) so "Connect Another" from there pushes
    /// onto this same stack too. Only meaningful when `ownsNavigationStack` is true; the
    /// Settings-nested case has no stack of its own to push onto and falls back to the old
    /// dismiss-only behavior, unchanged from before.
    @State private var navigationPath = NavigationPath()

    init(ownsNavigationStack: Bool = true) {
        self.ownsNavigationStack = ownsNavigationStack
    }

    var body: some View {
        Group {
            if ownsNavigationStack {
                NavigationStack(path: $navigationPath) { content }
            } else {
                content
            }
        }
    }

    private var localSources: [Source] {
        appState.sources.filter { $0.kind == .local }
    }

    private func instances(of connector: RemoteConnector) -> [Source] {
        appState.sources.filter { connector.sourceKinds.contains($0.kind) }
    }

    /// Jamendo has no "connect" step of its own — just an app-level API key, shipped in the
    /// build and overridable per-user in Settings (`JamendoCredentialView`) — so "enabled" here
    /// means that key actually resolved, the same honest check the browse screen itself uses.
    private var jamendoEnabled: Bool { !JamendoAppConfig.clientID.isEmpty }

    @ViewBuilder
    private var content: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ScreenHeader(title: "Libraries")
                        .padding(.bottom, 12)

                    SectionHeader(title: "On This Device")
                    if localSources.isEmpty {
                        EmptyStateView(icon: "folder",
                                       title: "No folders yet",
                                       message: "Add a local folder to play music straight from your device.")
                            .padding(.top, 10).padding(.bottom, 12)
                    } else {
                        ForEach(localSources) { source in
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
                    Button { appState.pendingImport = .folder } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "plus")
                                .font(Typography.body).foregroundStyle(Palette.accent)
                                .frame(width: 42, height: 42)
                                .glassSurface(cornerRadius: 9)
                                .accessibilityHidden(true)
                            Text("Add Local Folder").font(Typography.callout)
                            Spacer()
                        }
                        .padding(.vertical, 9)
                        .contentShape(Rectangle())
                        .foregroundStyle(Palette.ink)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("Add Local Folder Row")
                    .accessibilityLabel("Add Local Folder")

                    SectionHeader(title: "Remote")
                        .padding(.top, 18)

                    jamendoRow
                    Divider().overlay(Palette.hairline)
                    ForEach(RemoteConnectorCatalog.all) { connector in
                        remoteCatalogRow(connector)
                        Divider().overlay(Palette.hairline)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 160)
            }
            .background(Palette.sourcesBackground.ignoresSafeArea())
            .foregroundStyle(Palette.ink)
            // Harmless when reached from Settings' own sheet instead of the Libraries tab:
            // `nowPlaying` there compares against a tab that's never actually `.libraries`,
            // and the mini-player clearance inset defaults to zero outside RootView's own
            // environment — this only does anything while this screen really is the tab.
            .rootTabChrome(.libraries)
            .navigationDestination(for: Source.self) { source in
                SourceDetailView(source: source)
            }
            .navigationDestination(for: LibraryService.self) { service in
                switch service {
                case .jamendo: JamendoBrowseView()
                }
            }
            .navigationDestination(for: ProviderInstancesTarget.self) { target in
                if let connector = RemoteConnectorCatalog.connector(byID: target.connectorID) {
                    ProviderInstancesView(connector: connector, navigationPath: $navigationPath)
                }
            }
            .sheet(item: $connectingConnector) { connector in
                AddServerSheet(fixedConnector: connector) { source in
                    navigationPath.append(source)
                }
            }
            .sheet(isPresented: $showJamendoCredential) {
                JamendoCredentialView()
            }
            .hiddenNavigationBar()
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
                    let bookmark = BookmarkVault.makeBookmark(for: url)
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
                                "Imported \(summary.imported), skipped \(summary.skippedDuplicates) already in your library")
                        }
                    }
                case .none:
                    break
                }
                appState.pendingImport = nil
            }
    }

    @ViewBuilder
    private var jamendoRow: some View {
        if jamendoEnabled {
            NavigationLink(value: LibraryService.jamendo) {
                LibraryCatalogRow(icon: "dot.radiowaves.left.and.right", title: LibraryService.jamendo.title,
                                  subtitle: "Browse by genre or search · streams from Jamendo", isEnabled: true)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("Service Jamendo")
        } else {
            Button { showJamendoCredential = true } label: {
                LibraryCatalogRow(icon: "dot.radiowaves.left.and.right", title: LibraryService.jamendo.title,
                                  subtitle: "Browse by genre or search · streams from Jamendo", isEnabled: false)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("Service Jamendo")
        }
    }

    @ViewBuilder
    private func remoteCatalogRow(_ connector: RemoteConnector) -> some View {
        let enabled = !instances(of: connector).isEmpty
        if enabled {
            NavigationLink(value: ProviderInstancesTarget(connectorID: connector.id)) {
                LibraryCatalogRow(icon: connector.icon, title: connector.title, subtitle: connector.subtitle, isEnabled: true)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("Remote Library \(connector.connectorID)")
        } else {
            Button { connectingConnector = connector } label: {
                LibraryCatalogRow(icon: connector.icon, title: connector.title, subtitle: connector.subtitle, isEnabled: false)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("Remote Library \(connector.connectorID)")
        }
    }
}

/// One catalog row: icon, title/subtitle, and a trailing green checkmark (connected) or question
/// mark (not yet — tap to connect). The glyph shape differs, not just its color, so the state
/// reads without relying on color alone (CLAUDE.md accessibility expectations).
struct LibraryCatalogRow: View {
    let icon: String
    let title: String
    let subtitle: String
    let isEnabled: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(Typography.body)
                .foregroundStyle(Palette.accent)
                .frame(width: 42, height: 42)
                .glassSurface(cornerRadius: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Typography.callout).lineLimit(1)
                Text(subtitle).font(Typography.caption).foregroundStyle(Palette.inkTertiary).lineLimit(1)
            }
            Spacer()
            Image(systemName: isEnabled ? "checkmark.circle.fill" : "questionmark.circle")
                .font(Typography.body)
                .foregroundStyle(isEnabled ? Palette.success : Palette.inkTertiary)
        }
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .foregroundStyle(Palette.ink)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(subtitle)")
        .accessibilityValue(isEnabled ? "Connected" : "Not connected")
        .accessibilityHint(isEnabled ? "" : "Double tap to connect")
    }
}

struct SourceRow: View {
    let source: Source

    var body: some View {
        HStack(spacing: 12) {
            SourceArtworkView(source: source, cornerRadius: 9)
                .frame(width: 42, height: 42)
            VStack(alignment: .leading, spacing: 2) {
                Text(source.title).font(Typography.callout).lineLimit(1)
                Text(subtitle).font(Typography.caption).foregroundStyle(Palette.inkTertiary).lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right").font(Typography.callout).foregroundStyle(Palette.inkTertiary)
        }
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        switch source.kind {
        case .local: return String(localized: "On device")
        case .iaItem: return String(localized: "Item · streams from archive.org")
        case .iaList: return String(localized: "List · streams from archive.org")
        case .iaCollection: return String(localized: "Collection · streams from archive.org")
        case .iaFavorites: return String(localized: "Favorites · streams from archive.org")
        case .subsonic, .webDAV, .smb, .jellyfin, .emby, .plex, .dropbox, .googleDrive, .oneDrive, .pCloud, .box, .yandexDisk, .jamendoGenre:
            return "\(RemoteConnectorCatalog.connector(for: source.kind)?.title ?? "Remote") library"
        }
    }
}

/// A connected provider's own instance(s) — usually one, occasionally more (e.g. two Subsonic
/// servers). Reuses `SourceRow` so an instance looks exactly like it already does everywhere
/// else; "Connect Another" reopens the same per-provider sheet the catalog row itself would.
struct ProviderInstancesView: View {
    let connector: RemoteConnector
    /// Shared with the presenting `SourcesView` so "Connect Another" pushes the newly-connected
    /// source onto the same stack this screen itself lives on, instead of just dismissing back
    /// to here with no visible change until the next manual tap.
    @Binding var navigationPath: NavigationPath
    @EnvironmentObject var appState: AppState
    @State private var connectingConnector: RemoteConnector?

    private var matches: [Source] {
        appState.sources.filter { connector.sourceKinds.contains($0.kind) }
    }

    var body: some View {
        // A plain ScrollView/VStack, not `List` — matching SourcesView's own catalog list
        // instead (a real report: `List` draws its own disclosure chevron on every
        // `NavigationLink` row *in addition to* `SourceRow`'s own, so each row showed two).
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(matches) { source in
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
                Button { connectingConnector = connector } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "plus.circle").foregroundStyle(Palette.accent)
                        Text("Connect Another \(connector.title) Library").font(Typography.callout)
                        Spacer()
                    }
                    .padding(.vertical, 9)
                    .contentShape(Rectangle())
                    .foregroundStyle(Palette.ink)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 40)
        }
        .foregroundStyle(Palette.ink)
        .background(Palette.sourcesBackground.ignoresSafeArea())
        .navigationTitle(connector.title)
        .sheet(item: $connectingConnector) { connector in
            AddServerSheet(fixedConnector: connector) { source in
                navigationPath.append(source)
            }
        }
    }
}
