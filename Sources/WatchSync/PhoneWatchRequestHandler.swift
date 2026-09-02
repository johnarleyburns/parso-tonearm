import Foundation
import TonearmWatchProtocol

/// The phone half of the §5 request protocol, backed by the real GRDB library.
///
/// Phase 3 shipped the router and the `sourceUnavailable` defaults; this is the Phase 4
/// implementation those defaults stood in for. It lives in `TonearmWatchProtocol`'s sibling
/// `Sources/WatchSync/` — part of `TonearmCore`, host-compiled — so the definition of done ("a
/// fake-transport watch searches the complete phone fixture library and plays a playlist through a
/// spy phone player") runs under `swift test` with no simulator. The concrete `AudioPlayer`-backed
/// bridge is the only piece that has to be Xcode-only, and it is (`Sources/App/Watch`).
///
/// An actor because it fans requests out to the `LibraryStore` actor and reads a revision counter;
/// none of that needs main-actor isolation and all of it must be `Sendable`.
public actor PhoneWatchRequestHandler: WatchPhoneRequestHandling {
    private let store: LibraryStore
    private let player: any PhoneWatchPlaybackBridge
    private let libraryID: WatchPairedLibraryID
    private let revisionStore: any WatchPhoneRevisionStore
    private let capabilities: [WatchCapability]
    private let downloadedProvider: @Sendable () async -> Set<WatchTrackID>
    private let artworkBindingProvider: @Sendable (String) async -> (coverArtworkID: String?, customArtworkID: String?)
    private let onManifest: @Sendable (WatchManifestPayload) async -> Void
    private let onReconciliation: @Sendable (WatchReconciliationRequest) async -> Void
    private let onDownloadRequest: @Sendable (WatchDownloadRequest) async -> Void

    public init(store: LibraryStore,
                player: any PhoneWatchPlaybackBridge,
                libraryID: WatchPairedLibraryID,
                revisionStore: any WatchPhoneRevisionStore,
                capabilities: [WatchCapability] = WatchCapability.allCases,
                downloadedProvider: @escaping @Sendable () async -> Set<WatchTrackID> = { [] },
                artworkBindingProvider: @escaping @Sendable (String) async -> (coverArtworkID: String?, customArtworkID: String?) = { _ in (nil, nil) },
                onManifest: @escaping @Sendable (WatchManifestPayload) async -> Void = { _ in },
                onReconciliation: @escaping @Sendable (WatchReconciliationRequest) async -> Void = { _ in },
                onDownloadRequest: @escaping @Sendable (WatchDownloadRequest) async -> Void = { _ in }) {
        self.store = store
        self.player = player
        self.libraryID = libraryID
        self.revisionStore = revisionStore
        self.capabilities = capabilities
        self.downloadedProvider = downloadedProvider
        self.artworkBindingProvider = artworkBindingProvider
        self.onManifest = onManifest
        self.onReconciliation = onReconciliation
        self.onDownloadRequest = onDownloadRequest
    }

    // MARK: - Negotiation

    public func handleHello(_ payload: WatchHello) async -> WatchHelloReply {
        WatchHelloReply(pairedLibraryID: libraryID, capabilities: capabilities,
                        phoneRevision: await revisionStore.currentRevision())
    }

    // MARK: - Search

    public func handleSearch(_ request: WatchSearchRequest) async throws -> WatchSearchResponse {
        let trimmed = request.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= WatchSearchRequest.minimumQueryLength else {
            return WatchSearchResponse(generation: request.generation, query: request.query, rows: [])
        }

        let downloaded = await downloadedProvider()
        var rows: [WatchResultRow] = []

        if request.scope == .all || request.scope == .tracks {
            let hits = try await store.search(trimmed)
            rows += hits.map { PhoneWatchProjection.trackRow(from: $0, downloadedOnWatch: downloaded) }
        }
        if request.scope == .all || request.scope == .albums {
            let hits = try await store.allAlbums()
                .filter { Self.matches($0.title, trimmed) || Self.matches($0.albumArtist ?? $0.artist ?? "", trimmed) }
                .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            rows += hits.map { PhoneWatchProjection.albumRow(from: $0, trackCount: nil) }
        }
        if request.scope == .all || request.scope == .playlists {
            let hits = try await store.allPlaylists().filter { Self.matches($0.title, trimmed) }
            rows += hits.map { PhoneWatchProjection.playlistRow(from: $0, trackCount: nil) }
        }
        if request.scope == .all || request.scope == .artists {
            let hits = try await store.allArtists().filter { Self.matches($0.name, trimmed) }
            rows += hits.map(PhoneWatchProjection.artistRow(from:))
        }

        let offset = PhoneWatchPageToken.decode(request.pageToken).offset
        let (slice, next) = PhoneWatchPageToken.page(rows, offset: offset, limit: request.limit)
        return WatchSearchResponse(generation: request.generation, query: request.query,
                                   rows: Array(slice), nextPageToken: next)
    }

    // MARK: - Browse

    public func handleBrowse(_ request: WatchBrowseRequest) async throws -> WatchBrowseResponse {
        let downloaded = await downloadedProvider()
        let offset = PhoneWatchPageToken.decode(request.pageToken).offset

        switch request.category {
        case .playlists:
            let all = try await store.allPlaylists()
                .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            let (slice, next) = PhoneWatchPageToken.page(all, offset: offset, limit: request.limit)
            var rows: [WatchResultRow] = []
            for playlist in slice {
                var count: Int?
                if let pid = playlist.id { count = try? await store.playlistTrackRows(playlistId: pid).count }
                rows.append(PhoneWatchProjection.playlistRow(from: playlist, trackCount: count))
            }
            return WatchBrowseResponse(category: .playlists, generation: request.generation,
                                       rows: rows, nextPageToken: next)

        case .albums:
            let all = try await store.allAlbums()
                .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            let (slice, next) = PhoneWatchPageToken.page(all, offset: offset, limit: request.limit)
            var rows: [WatchResultRow] = []
            for album in slice {
                var count: Int?
                if let aid = album.id { count = try? await store.albumTrackRows(albumId: aid).count }
                rows.append(PhoneWatchProjection.albumRow(from: album, trackCount: count))
            }
            return WatchBrowseResponse(category: .albums, generation: request.generation,
                                       rows: rows, nextPageToken: next)

        case .songs:
            let all = try await store.allTrackRows()
            let (slice, next) = PhoneWatchPageToken.page(all, offset: offset, limit: request.limit)
            let rows = slice.map { PhoneWatchProjection.trackRow(from: $0, downloadedOnWatch: downloaded) }
            return WatchBrowseResponse(category: .songs, generation: request.generation,
                                       rows: Array(rows), nextPageToken: next)

        case .recent:
            let all = try await store.recentlyPlayedRows(limit: 200)
            let (slice, next) = PhoneWatchPageToken.page(all, offset: offset, limit: request.limit)
            let rows = slice.map { PhoneWatchProjection.trackRow(from: $0, downloadedOnWatch: downloaded) }
            return WatchBrowseResponse(category: .recent, generation: request.generation,
                                       rows: Array(rows), nextPageToken: next)
        }
    }

    // MARK: - Collection detail

    public func handleCollection(_ request: WatchCollectionRequest) async throws -> WatchCollectionResponse {
        let downloaded = await downloadedProvider()
        let resolved = try await resolveCollection(request.collection)
        let offset = PhoneWatchPageToken.decode(request.pageToken).offset
        let (slice, next) = PhoneWatchPageToken.page(resolved.rows, offset: offset, limit: request.limit)
        var tracks: [WatchTrackSummary] = []
        for row in slice {
            let binding = await artworkBindingProvider(PhoneWatchID.track(row.track).rawValue)
            tracks.append(PhoneWatchProjection.trackSummary(from: row, downloadedOnWatch: downloaded,
                                                             coverArtworkID: binding.coverArtworkID,
                                                             customArtworkID: binding.customArtworkID))
        }
        return WatchCollectionResponse(collection: request.collection, title: resolved.title,
                                       tracks: Array(tracks), totalCount: resolved.rows.count,
                                       nextPageToken: next)
    }

    // MARK: - Playback

    public func handlePlayCommand(_ command: WatchPlayCommand) async -> WatchCommandReply {
        do {
            switch command.action {
            case .playCollection:
                guard let ref = command.collection else { return .rejected(.contentNotFound) }
                let resolved = try await resolveCollection(ref)
                guard !resolved.rows.isEmpty else { return .rejected(.contentNotFound) }
                let start = min(max(0, command.startIndex ?? 0), resolved.rows.count - 1)
                await player.play(resolved.rows, startIndex: start,
                                  collection: ref, collectionTitle: resolved.title)

            case .playTrack:
                guard let trackID = command.trackID else { return .rejected(.contentNotFound) }
                if let ref = command.collection {
                    let resolved = try await resolveCollection(ref)
                    guard let index = resolved.rows.firstIndex(where: {
                        PhoneWatchID.track($0.track) == trackID
                    }) else { return .rejected(.contentNotFound) }
                    await player.play(resolved.rows, startIndex: index,
                                      collection: ref, collectionTitle: resolved.title)
                } else {
                    guard let row = try await resolveTrack(trackID) else {
                        return .rejected(.contentNotFound)
                    }
                    await player.play([row], startIndex: 0, collection: nil, collectionTitle: nil)
                }

            case .play:
                await player.setPlaying(true)
            case .pause:
                await player.setPlaying(false)
            case .togglePlayPause:
                await player.togglePlayPause()
            case .next:
                await player.advance(by: 1)
            case .previous:
                await player.advance(by: -1)
            case .jumpToIndex:
                guard let index = command.startIndex else { return .rejected(.contentNotFound) }
                await player.jump(toIndex: index)
            case .seek:
                guard let seconds = command.seekSeconds else { return .rejected(.contentNotFound) }
                await player.seek(toSeconds: seconds)
            case .setShuffle:
                guard let enabled = command.shuffleEnabled else { return .rejected(.contentNotFound) }
                await player.setShuffle(enabled)
            case .setRepeat:
                guard let mode = command.repeatMode else { return .rejected(.contentNotFound) }
                await player.setRepeat(mode)
            case .requestSnapshot:
                break  // read-only: fall through to the snapshot reply below
            }
        } catch let fault as WatchProtocolFault {
            return .rejected(fault.code)
        } catch {
            return .rejected(.playbackItemFailed)
        }

        let snapshot = await player.snapshot(revision: await revisionStore.currentRevision())
        return .accepted(snapshot)
    }

    // MARK: - Durable inbound

    public func handleWatchManifest(_ payload: WatchManifestPayload) async {
        await onManifest(payload)
    }

    public func handleReconciliationRequest(_ request: WatchReconciliationRequest) async {
        await onReconciliation(request)
    }

    public func handleDownloadRequest(_ request: WatchDownloadRequest) async {
        await onDownloadRequest(request)
    }

    // MARK: - Resolution

    private struct ResolvedCollection {
        var title: String
        var rows: [TrackRow]
    }

    private func resolveCollection(_ ref: WatchCollectionRef) async throws -> ResolvedCollection {
        switch ref.kind {
        case .playlist:
            guard let pid = try await localRowID(ref.id, prefix: PhoneWatchID.playlistRowPrefix,
                                                 table: "playlist"),
                  let playlist = try await store.playlist(id: pid) else {
                throw WatchProtocolFault(code: .contentNotFound)
            }
            let rows = try await store.playlistTrackRows(playlistId: pid).map(\.row)
            return ResolvedCollection(title: playlist.title, rows: rows)
        case .album:
            guard let aid = try await localRowID(ref.id, prefix: PhoneWatchID.albumRowPrefix,
                                                 table: "album") else {
                throw WatchProtocolFault(code: .contentNotFound)
            }
            let rows = try await store.albumTrackRows(albumId: aid)
            if rows.isEmpty {
                let albumExists = try await store.allAlbums().contains { $0.id == aid }
                guard albumExists else { throw WatchProtocolFault(code: .contentNotFound) }
            }
            return ResolvedCollection(title: rows.first?.album?.title ?? "", rows: rows)
        }
    }

    private func resolveTrack(_ id: WatchTrackID) async throws -> TrackRow? {
        if let rowID = PhoneWatchID.rowID(id.rawValue, prefix: PhoneWatchID.trackRowPrefix) {
            return try await store.trackRow(id: rowID)
        }
        return try await store.trackRow(syncID: id.rawValue)
    }

    private func localRowID(_ raw: String, prefix: String, table: String) async throws -> Int64? {
        if let direct = PhoneWatchID.rowID(raw, prefix: prefix) { return direct }
        return try await store.localID(table: table, syncID: raw)
    }

    private static func matches(_ haystack: String, _ needle: String) -> Bool {
        guard !needle.isEmpty else { return true }
        let options: String.CompareOptions = [.diacriticInsensitive, .caseInsensitive]
        return haystack.range(of: needle, options: options) != nil
    }
}
