import Foundation
import SwiftUI
import TonearmCore

enum AppTab: Int, CaseIterable {
    case listen, playlists, library, sources, settings
}

enum PendingImport: Equatable {
    case folder, files, smbFolder
}

@MainActor
final class AppState: ObservableObject {
    let store: LibraryStore

    @Published var tab: AppTab = .listen
    @Published var sources: [Source] = []
    @Published var playlists: [Playlist] = []
    @Published var allTracks: [TrackRow] = []
    @Published var recentlyPlayed: [TrackRow] = []
    @Published var recentlyAdded: [TrackRow] = []
    @Published var favoriteRows: [TrackRow] = []
    @Published var favoriteIds: Set<Int64> = []
    @Published var listeningStats: ListeningStats.Summary = .empty
    @Published var searchText: String = ""
    @Published var searchResults: [TrackRow] = []
    @Published var showAddMenu = false
    @Published var showNowPlaying = false
    @Published var showAddSource = false
    @Published var showAddRemoteLibrary = false
    @Published var showProPaywall = false
    @Published var proPaywallEntryPoint: ProPaywallEntryPoint = .generic
    @Published var showAddRemoteLibraryProCompletion = false
    @Published var showCreatePlaylist = false
    @Published var backgroundTitle: String?
    @Published var backgroundDone = false
    @Published var backgroundFailed = false
    @Published var pickedFolder: URL?
    @Published var pickedFolderBookmark: Data?
    @Published var pendingImport: PendingImport?
    // Settings-backed values
    @AppStorage("streamOnCellular") var streamOnCellular = true
    @AppStorage("preferFLAC") var preferFLAC = false
    @AppStorage("prefetchDepth") var prefetchDepth = 2
    @AppStorage("artworkLookup") var artworkLookup = true
    @AppStorage("didOnboard") var didOnboard = false

    init(store: LibraryStore = .shared) {
        self.store = store
    }

    func bootstrap() async {
        await fixLegacySourceTitles()
        await ArtworkService.shared.migrateCacheIfNeeded()
        applySettingsToPlayer()
        // Restore the queue before the first widget/native now-playing publish.
        await AudioPlayer.shared.restorePersistedQueue()
        await reload()
        await CacheStore.shared.garbageCollectStalePartials()
        Task { await warmLocalSourceArtwork() }
    }

    /// Resolves and caches a representative cover for local sources that don't yet
    /// have one remembered, so app-update installs pick up embedded artwork without
    /// waiting for each tile to appear. Runs off the launch critical path.
    private func warmLocalSourceArtwork() async {
        let locals = sources.filter { $0.kind == .local && $0.artworkTrackId == nil }
        guard !locals.isEmpty else { return }
        for source in locals {
            _ = await resolvedArtwork(for: source)
        }
        // Pick up the persisted artworkTrackId values so tiles use the remembered
        // pick directly instead of rescanning.
        await reload()
    }

    /// One-time repair for sources saved before the list/collection naming fix:
    /// re-derive human-readable titles from the stored originalURL slug.
    func fixLegacySourceTitles() async {
        guard let existing = try? await store.allSources() else { return }
        for source in existing {
            guard let id = source.id else { continue }
            var newTitle: String?

            switch source.kind {
            case .iaList:
                if let raw = source.originalURL,
                   case .list(_, _, let slug)? = try? URLGrammar.parse(raw).get(),
                   let slug, !slug.isEmpty {
                    newTitle = SourceService.prettify(slug)
                }
            case .iaCollection:
                // Buggy rows stored the raw identifier as the title.
                if let idf = source.iaIdentifier, source.title == idf {
                    newTitle = SourceService.prettify(idf)
                }
            default:
                break
            }

            if let newTitle, !newTitle.isEmpty, newTitle != source.title {
                try? await store.updateSourceTitle(id: id, title: newTitle)
            }
        }
    }

    func applySettingsToPlayer() {
        AudioPlayer.shared.streamOnCellular = streamOnCellular
        AudioPlayer.shared.prefetchDepth = PrefetchDepthPolicy.clamp(prefetchDepth)
        AudioPlayer.shared.preferFLAC = preferFLAC
        let lookup = artworkLookup
        Task { await ArtworkService.shared.setArtworkLookupEnabled(lookup) }
    }

    func reload() async {
        do {
            let loadedSources = try await store.allSources()
            let loadedPlaylists = try await store.allPlaylists()
            let loadedTracks = try await store.allTrackRows()
            let loadedRecentlyPlayed = try await store.recentlyPlayedRows()
            let loadedRecentlyAdded = try await store.recentlyAddedRows()
            let loadedFavoriteRows = try await store.favoriteRows()
            let loadedFavoriteIds = try await store.favoriteTrackIds()
            let playEvents = try await store.allPlayEvents()

            sources = loadedSources
            playlists = loadedPlaylists
            allTracks = loadedTracks
            recentlyPlayed = loadedRecentlyPlayed
            recentlyAdded = loadedRecentlyAdded
            favoriteRows = loadedFavoriteRows
            favoriteIds = loadedFavoriteIds
            listeningStats = ListeningStats.summarize(events: playEvents, tracks: loadedTracks)
            WidgetSnapshotPublisher.publish(appState: self, player: AudioPlayer.shared)
        } catch {
            print("reload error: \(error)")
        }
    }

    func runSearch() async {
        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else {
            searchResults = []
            return
        }
        searchResults = (try? await store.search(searchText)) ?? []
    }

    func tracks(for source: Source) async -> [TrackRow] {
        guard let id = source.id else { return [] }
        return (try? await store.tracks(forSource: id)) ?? []
    }

    func firstArtworkId(for source: Source) async -> String? {
        guard let id = source.id else { return nil }
        guard let ids = try? await store.artworkIds(forSource: id), !ids.isEmpty else { return nil }
        return await ArtworkService.shared.firstAvailableIdentifier(ids)
    }

    /// Resolved artwork inputs for a source tile: an IA identifier and/or a local
    /// track carrying embedded art, plus the per-kind fallback icon. For local
    /// sources the representative track is chosen once and remembered (cached)
    /// via `artworkTrackId`.
    struct ResolvedSourceArtwork {
        var identifier: String?
        var trackRow: TrackRow?
        var fallbackIcon: String
    }

    func resolvedArtwork(for source: Source) async -> ResolvedSourceArtwork {
        let icon = source.fallbackIcon
        guard let id = source.id else {
            return ResolvedSourceArtwork(identifier: nil, trackRow: nil, fallbackIcon: icon)
        }

        if source.kind == .local {
            let row = await representativeLocalTrackRow(for: source, sourceId: id)
            return ResolvedSourceArtwork(identifier: nil, trackRow: row, fallbackIcon: icon)
        }

        // IA: prefer a resolvable IA identifier cover.
        if let identifier = await firstArtworkId(for: source) {
            return ResolvedSourceArtwork(identifier: identifier, trackRow: nil, fallbackIcon: icon)
        }
        // No IA cover: fall back to a representative track so the tile can still get
        // an iTunes cover from the album's artist/title (same path as Now Playing).
        if let row = try? await store.firstTrackRow(forSource: id),
           await ArtworkService.shared.artwork(forTrackRow: row) != nil {
            return ResolvedSourceArtwork(identifier: nil, trackRow: row, fallbackIcon: icon)
        }
        return ResolvedSourceArtwork(identifier: nil, trackRow: nil, fallbackIcon: icon)
    }

    /// Picks the first local track with resolvable artwork, preferring a previously
    /// remembered `artworkTrackId`. Only a strong (persistable) match is remembered
    /// as the source's representative; weak iTunes guesses are shown but not locked in.
    private func representativeLocalTrackRow(for source: Source, sourceId: Int64) async -> TrackRow? {
        if let remembered = source.artworkTrackId,
           let row = try? await store.trackRow(id: remembered),
           await ArtworkService.shared.artwork(forTrackRow: row) != nil {
            return row
        }

        let rows = (try? await store.tracks(forSource: sourceId)) ?? []
        var firstWithArt: TrackRow?
        for row in rows {
            guard let result = await ArtworkService.shared.trackArtwork(forTrackRow: row) else { continue }
            if firstWithArt == nil { firstWithArt = row }
            if result.persistable {
                try? await store.setSourceArtworkTrack(id: sourceId, trackId: row.id)
                return row
            }
        }
        // No strong match: show the first weak guess without remembering it.
        return firstWithArt
    }

    func deleteSource(_ source: Source) async {
        guard let id = source.id else { return }
        // Delete custom artwork files from disk before the cascade removes DB rows.
        if let artworkIds = try? await store.customArtworkIds(forSource: id) {
            for aid in artworkIds { await ArtworkStore.shared.delete(id: aid) }
        }
        for account in RemoteLibraryProviderFactory.credentialAccounts(for: id, kind: source.kind) {
            try? CredentialStore().delete(account: account)
        }
        try? await store.deleteSource(id: id)
        await reload()
    }

    func requestAddRemoteLibrary() {
        switch RemoteLibraryGate.entryPointDecision(isPro: ProGating.isEnabled(.remoteLibraries)) {
        case .openSheet:
            tab = .sources
            showAddRemoteLibrary = true
        case .showPaywall:
            proPaywallEntryPoint = .addRemoteLibrary
            showProPaywall = true
        }
    }

    func requestGenericProPaywall() {
        proPaywallEntryPoint = .generic
        showProPaywall = true
    }

    func handleProCompletion() {
        switch AddRemoteLibraryProFlow.presentationAfterProCompletion(
            entryPoint: proPaywallEntryPoint,
            didBecomePro: ProGating.isEnabled(.remoteLibraries)
        ) {
        case .showAddRemoteLibraryCompletion:
            showProPaywall = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                self.showAddRemoteLibraryProCompletion = true
            }
        case .none:
            break
        }
    }

    func applyAddRemoteLibraryPostPurchaseAction(_ action: RemoteLibraryPostPurchaseAction) {
        let outcome = AddRemoteLibraryProFlow.outcome(for: action)
        showAddRemoteLibraryProCompletion = false
        if outcome.openLibrariesTab {
            tab = .sources
        }
        if outcome.openAddServerSheet {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                self.showAddRemoteLibrary = true
            }
        }
    }

    func addSubsonicServer(url rawURL: String, username rawUsername: String, password: String) async throws {
        try requireRemoteLibrary(.connect(.subsonic))
        let baseURL = try SubsonicServerPolicy.normalizeBaseURL(rawURL)
        let username = rawUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        let provider = SubsonicProvider(baseURL: baseURL, username: username, password: password)
        try await provider.refresh()

        var source = Source(
            id: nil,
            kind: .subsonic,
            iaIdentifier: username,
            originalURL: baseURL.absoluteString,
            title: SubsonicServerPolicy.displayName(baseURL: baseURL),
            addedAt: Date(),
            lastResolvedAt: Date(),
            followUpdates: false,
            licenseText: nil,
            memberCapHit: false
        )
        source = try await store.insertSource(source)
        guard let sourceID = source.id else { return }
        do {
            try CredentialStore().save(Data(password.utf8),
                                       account: SubsonicServerPolicy.credentialAccount(sourceID: sourceID))
        } catch {
            try? await store.deleteSource(id: sourceID)
            throw error
        }
        await reload()
        tab = .sources
    }

    func addWebDAVServer(url rawURL: String, username rawUsername: String, password: String) async throws {
        try requireRemoteLibrary(.connect(.webDAV))
        let baseURL = try WebDAVServerPolicy.normalizeBaseURL(rawURL)
        let username = rawUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        let provider = WebDAVProvider(baseURL: baseURL, username: username, password: password)
        try await provider.refresh()

        let credential = WebDAVCredential(username: username, password: password)
        try await insertRemoteSource(
            kind: .webDAV,
            title: WebDAVServerPolicy.displayName(baseURL: baseURL),
            originalURL: baseURL.absoluteString,
            iaIdentifier: username,
            credential: try JSONEncoder().encode(credential),
            credentialAccount: WebDAVServerPolicy.credentialAccount
        )
    }

    func addJellyfinServer(url rawURL: String, username rawUsername: String, password: String) async throws {
        try requireRemoteLibrary(.connect(.jellyfin))
        let baseURL = try JellyfinServerPolicy.normalizeBaseURL(rawURL)
        let username = rawUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = try JellyfinAPI.request(
            baseURL: baseURL,
            endpoint: .authenticate(username: username, password: password)
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            throw URLError(.userAuthenticationRequired)
        }
        let auth = try JellyfinAPI.decodeAuthentication(data)
        let provider = JellyfinProvider(baseURL: baseURL, userID: auth.userID, accessToken: auth.accessToken)
        try await provider.refresh()

        try await insertRemoteSource(
            kind: .jellyfin,
            title: JellyfinServerPolicy.displayName(baseURL: baseURL),
            originalURL: baseURL.absoluteString,
            iaIdentifier: auth.userID,
            credential: Data(auth.accessToken.utf8),
            credentialAccount: JellyfinServerPolicy.credentialAccount
        )
    }

    func addPlexServer(url rawURL: String, token rawToken: String) async throws {
        try requireRemoteLibrary(.connect(.plex))
        let baseURL = try PlexServerPolicy.normalizeBaseURL(rawURL)
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let provider = PlexProvider(baseURL: baseURL, token: token)
        try await provider.refresh()

        try await insertRemoteSource(
            kind: .plex,
            title: PlexServerPolicy.displayName(baseURL: baseURL),
            originalURL: baseURL.absoluteString,
            iaIdentifier: nil,
            credential: Data(token.utf8),
            credentialAccount: PlexServerPolicy.credentialAccount
        )
    }

    func addCloudDrive(provider cloudProvider: CloudDriveAPI.Provider, accessToken rawToken: String) async throws {
        try requireRemoteLibrary(.connect(cloudProvider.sourceKind))
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let provider = CloudDriveProvider(provider: cloudProvider, accessToken: token)
        try await provider.refresh()

        try await insertRemoteSource(
            kind: cloudProvider.sourceKind,
            title: CloudDriveServerPolicy.displayName(provider: cloudProvider),
            originalURL: nil,
            iaIdentifier: nil,
            credential: Data(token.utf8),
            credentialAccount: { sourceID in
                CloudDriveServerPolicy.credentialAccount(sourceID: sourceID, provider: cloudProvider)
            }
        )
    }

    func addCloudDrive(provider cloudProvider: CloudDriveAPI.Provider, oauthToken token: OAuthToken) async throws {
        try requireRemoteLibrary(.connect(cloudProvider.sourceKind))
        let provider = CloudDriveProvider(
            provider: cloudProvider,
            accessProvider: OAuthCloudDriveAccessProvider(token: token)
        )
        try await provider.refresh()

        try await insertRemoteSource(
            kind: cloudProvider.sourceKind,
            title: CloudDriveServerPolicy.displayName(provider: cloudProvider),
            originalURL: nil,
            iaIdentifier: token.accountLabel,
            credential: try JSONEncoder().encode(token),
            credentialAccount: { sourceID in
                CloudDriveServerPolicy.credentialAccount(sourceID: sourceID, provider: cloudProvider)
            }
        )
    }

    func addSMBFolder(_ folderURL: URL, bookmark folderBookmark: Data?) async throws {
        try requireRemoteLibrary(.connect(.smb))
        let bookmark = folderBookmark ?? BookmarkVault.makeBookmark(for: folderURL)
        guard let bookmark else { throw IngestError.failedToCreateBookmark }

        try await insertRemoteSource(
            kind: .smb,
            title: SMBFolderPolicy.displayName(rootURL: folderURL),
            originalURL: folderURL.absoluteString,
            iaIdentifier: nil,
            credential: bookmark,
            credentialAccount: SMBFolderPolicy.credentialAccount
        )
    }

    func addIASource(url rawURL: String, username: String?, password: String?) async throws {
        try requireRemoteLibrary(.connect(.iaList))
        let url = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let service = SourceService(preferFLAC: preferFLAC)
        let preview = try await service.preview(from: url)

        let followUpdates = preview.kind != .iaItem

        let source = try await service.add(preview: preview, followUpdates: followUpdates, store: store)

        if let _ = username, let password, let sourceID = source.id {
            let data = Data(password.utf8)
            let account = "ia-private:\(sourceID)"
            try CredentialStore().save(data, account: account)
        }

        await reload()
        tab = .sources
    }

    func browseRemote(source: Source, path: String) async throws -> [RemoteNode] {
        try requireRemoteLibrary(.browse(source.kind))
        return try await remoteProvider(for: source).browse(path: path)
    }

    func renameSource(_ source: Source, title: String) async {
        guard let id = source.id else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try? await store.updateSourceTitle(id: id, title: trimmed)
        await reload()
    }

    func remoteAccountLabel(for source: Source) -> String? {
        switch source.kind {
        case .subsonic, .webDAV, .jellyfin:
            return source.iaIdentifier
        case .plex:
            return "Token saved"
        case .dropbox, .googleDrive, .oneDrive, .pCloud:
            return source.iaIdentifier
        case .smb:
            return "Folder bookmark saved"
        case .iaItem, .iaList, .iaCollection, .iaFavorites:
            if let id = source.id,
               let _ = try? CredentialStore().read(account: "ia-private:\(id)") {
                return "Credentials saved"
            }
            return source.originalURL
        default:
            return nil
        }
    }

    func remoteCredentialStatus(for source: Source) -> String? {
        switch source.kind {
        case .subsonic, .webDAV, .jellyfin:
            return "Password saved"
        case .plex:
            return "Token saved"
        case .dropbox, .googleDrive, .oneDrive, .pCloud:
            return "OAuth token saved"
        case .smb:
            return "Bookmark saved"
        case .iaItem, .iaList, .iaCollection, .iaFavorites:
            if let id = source.id,
               let _ = try? CredentialStore().read(account: "ia-private:\(id)") {
                return "Password saved"
            }
            return nil
        default:
            return nil
        }
    }

    func remoteStats(for source: Source) async -> RemoteLibraryStats? {
        guard let sourceID = source.id else { return nil }
        switch source.kind {
        case .subsonic:
            let provider = try? SubsonicProvider.from(source: source)
            return try? await provider?.gatherStats()
        case .iaItem, .iaList, .iaCollection, .iaFavorites:
            let tracks = (try? await store.tracks(forSource: sourceID)) ?? []
            let totalBytes = tracks.compactMap { $0.asset?.sizeBytes }.reduce(0, +)
            let uniqueAlbums = Set(tracks.compactMap { $0.album?.id })
            let uniqueArtists = Set(tracks.compactMap { $0.artist?.id })
            return RemoteLibraryStats(
                artistCount: uniqueArtists.isEmpty ? nil : uniqueArtists.count,
                albumCount: uniqueAlbums.isEmpty ? nil : uniqueAlbums.count,
                trackCount: tracks.count,
                totalBytes: totalBytes > 0 ? totalBytes : nil
            )
        default:
            return nil
        }
    }

    func remoteTrackRows(source: Source, nodes: [RemoteNode]) async throws -> [TrackRow] {
        try requireRemoteLibrary(.resolve(source.kind))
        let provider = try remoteProvider(for: source)
        var rows: [TrackRow] = []
        for (index, node) in nodes.filter({ $0.kind == .audio }).enumerated() {
            let resolved = try await provider.resolve(node: node)
            rows.append(RemoteTrackRowFactory.row(source: source, node: node, resolved: resolved, index: index))
        }
        return rows
    }

    private func insertRemoteSource(kind: SourceKind,
                                    title: String,
                                    originalURL: String?,
                                    iaIdentifier: String?,
                                    credential: Data,
                                    credentialAccount: (Int64) -> String) async throws {
        var source = Source(
            id: nil,
            kind: kind,
            iaIdentifier: iaIdentifier,
            originalURL: originalURL,
            title: title,
            addedAt: Date(),
            lastResolvedAt: Date(),
            followUpdates: false,
            licenseText: nil,
            memberCapHit: false
        )
        source = try await store.insertSource(source)
        guard let sourceID = source.id else { return }
        do {
            try CredentialStore().save(credential, account: credentialAccount(sourceID))
        } catch {
            try? await store.deleteSource(id: sourceID)
            throw error
        }
        await reload()
        tab = .sources
    }

    private func remoteProvider(for source: Source) throws -> any RemoteLibraryProvider {
        try RemoteLibraryProviderFactory.provider(for: source)
    }

    private func requireRemoteLibrary(_ action: RemoteLibraryAction) throws {
        try RemoteLibraryGate.require(action, isPro: ProGating.isEnabled(.remoteLibraries))
    }

    @discardableResult
    func createSmartPlaylistSnapshot(title rawTitle: String, playlist: SmartPlaylist) async throws -> Playlist {
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let rows = try await store.smartPlaylistRows(playlist)
        let trackIDs = rows.compactMap(\.track.id)
        let created = try await store.createManualPlaylist(
            title: title.isEmpty ? "Smart Playlist" : title,
            trackIds: trackIDs
        )
        await reload()
        tab = .playlists
        return created
    }

    @discardableResult
    func applyTagEdit(trackIDs: Set<Int64>, proposal: TagEdit.Proposal) async throws -> Int {
        let rows = try await store.allTrackRows()
        let selection = rows
            .filter { row in row.track.id.map(trackIDs.contains) ?? false }
            .map(TagEdit.editableTrack)
        let plan = TagEdit.makePlan(selection: selection, proposal: proposal)
        let applied = try await store.applyTagEditPlan(plan)
        if applied > 0 {
            await reload()
        }
        return applied
    }

    func duplicateGroups(limit: Int = 200) async throws -> [DuplicateDetection.Group] {
        let rows = try await store.allTrackRows()
        var candidates: [DuplicateDetection.Candidate] = []
        for row in rows.prefix(limit) {
            guard let data = localAudioBytes(for: row),
                  let trackID = row.track.id else { continue }
            candidates.append(DuplicateDetection.Candidate(id: "\(trackID): \(row.track.title)", bytes: data))
        }
        return DuplicateDetection.groups(from: candidates)
    }

    private func localAudioBytes(for row: TrackRow) -> Data? {
        guard let asset = row.asset else { return nil }
        let url: URL?
        if let bookmark = asset.bookmark, let resolved = BookmarkVault.resolve(bookmark) {
            url = resolved.url
        } else if let remote = asset.remoteURL.flatMap(URL.init(string:)), remote.isFileURL {
            url = remote
        } else if let relPath = asset.relPath {
            let base = try? FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: false
            )
            url = base?.appendingPathComponent(relPath)
        } else {
            url = nil
        }
        guard let url else { return nil }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        return try? Data(contentsOf: url, options: [.mappedIfSafe])
    }

    func addSourceInBackground(preview: SourcePreview, followUpdates: Bool) {
        let title = preview.title
        backgroundTitle = title
        backgroundDone = false
        backgroundFailed = false

        let pre = preview
        let upd = followUpdates
        let db = store
        let flac = preferFLAC

        Task {
            let service = SourceService(preferFLAC: flac)
            let source = try? await service.add(preview: pre, followUpdates: upd, store: db)
            if source != nil {
                backgroundDone = true
            } else {
                backgroundFailed = true
            }
            await reload()
            try? await Task.sleep(for: .seconds(4))
            backgroundTitle = nil
            backgroundDone = false
            backgroundFailed = false
        }
    }

    func handleIncomingURL(_ url: URL) async {
        guard let action = TonearmDeepLink.parse(url) else { return }
        switch action {
        case .addSource(let rawURL):
            await handleSharedSourceURL(rawURL)
        case .nowPlaying:
            showNowPlaying = AudioPlayer.shared.currentTrack != nil
        case .resumePlayback:
            await AudioPlayer.shared.withRestoredQueue { AudioPlayer.shared.resumePlayback() }
        case .pausePlayback:
            await AudioPlayer.shared.withRestoredQueue { AudioPlayer.shared.pausePlayback() }
        case .togglePlayback:
            await AudioPlayer.shared.withRestoredQueue { AudioPlayer.shared.togglePlayPause() }
        case .nextTrack:
            await AudioPlayer.shared.withRestoredQueue { AudioPlayer.shared.next() }
        case .previousTrack:
            await AudioPlayer.shared.withRestoredQueue { AudioPlayer.shared.previous() }
        }
    }

    private func handleSharedSourceURL(_ rawURL: String) async {
        do {
            let service = SourceService(preferFLAC: preferFLAC)
            let preview = try await service.preview(from: rawURL)
            addSourceInBackground(preview: preview, followUpdates: true)
            tab = .sources
        } catch {
            backgroundTitle = "Shared source"
            backgroundDone = false
            backgroundFailed = true
        }
    }

    func playSource(_ source: Source, startAt: Int = 0) async {
        let tracks = await tracks(for: source)
        guard !tracks.isEmpty else { return }
        AudioPlayer.shared.play(tracks: tracks, startAt: startAt, source: .source(source))
    }

    // MARK: - Favorites (TF7)

    func isFavorite(_ row: TrackRow) -> Bool {
        favoriteIds.contains(row.id)
    }

    func toggleFavorite(_ row: TrackRow) async {
        let makeFavorite = !favoriteIds.contains(row.id)
        try? await store.setFavorite(trackId: row.id, makeFavorite)
        if makeFavorite { favoriteIds.insert(row.id) } else { favoriteIds.remove(row.id) }
        favoriteRows = (try? await store.favoriteRows()) ?? favoriteRows
    }

    // MARK: - Playlists (TF6)

    func createPlaylist(title: String, trackIds: [Int64]) async {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        _ = try? await store.createManualPlaylist(title: name, trackIds: trackIds)
        await reload()
        tab = .playlists
    }

    func deletePlaylist(_ playlist: Playlist) async {
        guard let id = playlist.id else { return }
        try? await store.deletePlaylist(id: id)
        await reload()
    }

    func renamePlaylist(_ playlist: Playlist, title: String) async {
        guard let id = playlist.id else { return }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        try? await store.renamePlaylist(id: id, title: name)
        await reload()
    }

    func reorderPlaylist(_ playlist: Playlist, from source: Int, to destination: Int) async {
        guard let id = playlist.id else { return }
        try? await store.reorderPlaylist(id: id, from: source, to: destination)
    }

    func reorderPlaylist(_ playlist: Playlist, fromOffsets offsets: IndexSet, toOffset destination: Int) async {
        guard let id = playlist.id else { return }
        try? await store.reorderPlaylist(id: id, fromOffsets: offsets, toOffset: destination)
    }

    func removeFromPlaylist(_ playlist: Playlist, atOffsets offsets: IndexSet) async {
        guard let id = playlist.id else { return }
        try? await store.removeFromPlaylist(playlistId: id, atOffsets: offsets)
    }

    // MARK: - Onboarding (TF5, TF9)

    /// Adds the given archive.org libraries, persisting all of their tracks to the
    /// library (never caching), then builds the "Classical Piano Sonatas"
    /// starter playlist from every track that was added.
    func completeOnboarding(sourceURLs: [String]) async {
        let service = SourceService(preferFLAC: preferFLAC)
        var addedTrackIds: [Int64] = []
        for raw in sourceURLs {
            do {
                let preview = try await service.preview(from: raw)
                if let source = try? await service.add(preview: preview, followUpdates: true, store: store),
                   let sid = source.id {
                    let rows = (try? await store.tracks(forSource: sid)) ?? []
                    addedTrackIds.append(contentsOf: rows.map { $0.id })
                }
            } catch {
                print("onboarding add error for \(raw): \(error)")
            }
        }
        if !addedTrackIds.isEmpty {
            _ = try? await store.createManualPlaylist(title: "Classical Piano Sonatas",
                                                      trackIds: addedTrackIds)
        }
        didOnboard = true
        await reload()
    }
}
