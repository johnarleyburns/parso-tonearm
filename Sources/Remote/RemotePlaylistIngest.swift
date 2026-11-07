import Foundation

private enum JamendoIngestError: Error { case invalidProviderTrackID }

public struct RemotePlaylistIngest: Sendable {
    public struct Result: Sendable, Equatable {
        public let trackIDs: [Int64]
        public let skipped: Int
        public init(trackIDs: [Int64], skipped: Int) {
            self.trackIDs = trackIDs
            self.skipped = skipped
        }
    }

    public static func persist(
        nodes: [RemoteNode],
        resolve: @Sendable (RemoteNode) async throws -> ResolvedAsset,
        source: Source,
        store: LibraryStore,
        catalogUpsert: @Sendable (LibraryStore, String, URL) async throws -> Void = { store, nodeID, url in
            try await store.upsertJamendoCatalogTrack(trackID: nodeID, cachedURL: url)
        }
    ) async -> Result {
        guard let sourceID = source.id else { return Result(trackIDs: [], skipped: nodes.count) }
        let existingRows = (try? await store.tracks(forSource: sourceID)) ?? []
        var existing = Dictionary(uniqueKeysWithValues: existingRows.compactMap { row in
            row.asset?.remoteURL.map { ($0, row.id) }
        })
        // A provider node ID, unlike a stream URL, survives locator refresh.
        var existingJamendoNode: [String: Int64] = [:]
        if source.kind == .jamendoGenre {
            for row in existingRows {
                if let nodeID = row.asset?.remoteNodeID, !nodeID.isEmpty { existingJamendoNode[nodeID] = row.id }
            }
        }
        // Real report: re-browsing to and replaying the same Dropbox/Google Drive file created a
        // genuine duplicate track every time, instead of finding the one already imported.
        // URL-only dedup has more moving parts than it looks (base-URL construction, query
        // encoding) across two independent `resolve()` calls than a stable provider-native id
        // does. Jamendo already dedupes by `node.id` for exactly this class of reason ("a shared
        // stream URL must not merge distinct tracks" — the same identity check, used the other
        // direction, means a *different*-looking resolved URL must not be treated as a different
        // track when the provider's own id says it's the same one). Extend that same node-id
        // identity to every remote provider, not just Jamendo, checked before falling back to the
        // URL match below.
        var existingByNodeID: [String: Int64] = [:]
        for row in existingRows {
            if let nodeID = row.asset?.remoteNodeID, !nodeID.isEmpty { existingByNodeID[nodeID] = row.id }
        }
        let oldAssets = Dictionary(existingRows.map { ($0.id, $0.asset) }, uniquingKeysWith: { a, _ in a })
        let album: Album
        if let found = try? await store.firstAlbum(sourceId: sourceID, title: source.title) {
            album = found
        } else if let inserted = try? await store.insertAlbum(Album(
            id: nil, sourceId: sourceID, title: source.title, artist: nil,
            year: nil, artworkId: nil)) {
            album = inserted
        } else {
            return Result(trackIDs: [], skipped: nodes.count)
        }

        var ids: [Int64] = []
        var skipped = 0
        for (index, node) in nodes.enumerated() {
            do {
                if source.kind == .jamendoGenre {
                    guard !node.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          Int64(node.id) != nil else { throw JamendoIngestError.invalidProviderTrackID }
                }
                let resolved = try await resolve(node)
                let url = resolved.url.absoluteString
                if source.kind == .jamendoGenre, let id = existingJamendoNode[node.id] {
                    // Refresh cache data and the asset URL, but never make a second library track.
                    let old = oldAssets[id] ?? nil
                    try await store.updateRemoteAssetURL(trackID: id, remoteURL: resolved.url,
                                                         sizeBytes: resolved.sizeBytes ?? node.sizeBytes)
                    do {
                        try await catalogUpsert(store, node.id, resolved.url)
                    } catch {
                        // Keep asset and catalog from diverging: restore the previous locator.
                        if let oldURL = old?.remoteURL.flatMap(URL.init(string:)) {
                            try? await store.updateRemoteAssetURL(trackID: id, remoteURL: oldURL,
                                                                  sizeBytes: old?.sizeBytes)
                        }
                        throw error
                    }
                    existing[url] = id
                    ids.append(id)
                    continue
                }
                // Checked before the URL match: see the `existingByNodeID` comment above.
                let trimmedNodeID = node.id.trimmingCharacters(in: .whitespacesAndNewlines)
                if source.kind != .jamendoGenre, !trimmedNodeID.isEmpty,
                   let id = existingByNodeID[node.id] {
                    // The resolved URL can legitimately differ from what's stored (a fresh temp
                    // link, say) even though it's the same file — refresh the stored locator so a
                    // later replay isn't working from an even-staler URL, then reuse the existing
                    // track instead of duplicating it.
                    try? await store.updateRemoteAssetURL(trackID: id, remoteURL: resolved.url,
                                                          sizeBytes: resolved.sizeBytes ?? node.sizeBytes)
                    existing[url] = id
                    ids.append(id)
                    continue
                }
                // Jamendo identity is the node ID; a shared stream URL must not merge distinct tracks.
                if source.kind != .jamendoGenre, let id = existing[url] { ids.append(id); continue }
                let metadata = resolved.metadata ?? node.metadata
                let number = metadata?.trackNumber ?? index + 1
                let track = try await store.insertTrack(Track(
                    id: nil, albumId: album.id, sourceId: sourceID,
                    title: metadata?.title ?? node.title, trackNo: number,
                    discNo: metadata?.discNumber,
                    durationSec: metadata?.durationSec ?? node.durationSec,
                    codec: metadata?.codec?.uppercased(), sampleRate: metadata?.sampleRate,
                    bitDepthOrBitrate: metadata?.bitRateKbps.map { "\($0) kbps" },
                    sortKey: String(format: "%06d", number), genre: metadata?.genre))
                guard let trackID = track.id else { skipped += 1; continue }
                // Persist the real provider node reference, not just the
                // resolved URL — this is what later lets "Make Offline"/
                // "Download" (and any future background re-index) get a fresh
                // URL/headers via `RemoteLibraryProvider.resolve(node:)`
                // instead of trusting a possibly-stale/expired `remoteURL`
                // (see `Asset.remoteNodeID`'s doc).
                _ = try await store.insertAsset(Asset(
                    id: nil, trackId: trackID, kind: .remote, bookmark: nil, relPath: nil,
                    remoteURL: url, altRemoteURL: nil,
                    sizeBytes: resolved.sizeBytes ?? node.sizeBytes, unsupportedReason: nil,
                    remoteNodeID: node.id, remoteNodePath: node.path))
                if source.kind == .jamendoGenre {
                    do {
                        // `node.id`, not the resolved URL, is the durable Jamendo identity.
                        try await catalogUpsert(store, node.id, resolved.url)
                    } catch {
                        // Never report the node as imported without its blend identity.
                        try? await store.deleteTrack(id: trackID)
                        throw error
                    }
                }
                existing[url] = trackID
                if source.kind == .jamendoGenre { existingJamendoNode[node.id] = trackID }
                ids.append(trackID)
            } catch {
                skipped += 1
            }
        }
        return Result(trackIDs: ids, skipped: skipped)
    }
}
