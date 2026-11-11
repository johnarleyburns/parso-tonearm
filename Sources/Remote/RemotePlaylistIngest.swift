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
                // One atomic, database-enforced get-or-create per source-scoped remote identity
                // (`RemoteTrackIdentity`): a rotated URL refreshes the stored locator in place.
                let metadata = resolved.metadata ?? node.metadata
                let number = metadata?.trackNumber ?? index + 1
                let outcome = try await store.upsertRemoteTrack(
                    sourceID: sourceID,
                    track: Track(
                        id: nil, albumId: album.id, sourceId: sourceID,
                        title: metadata?.title ?? node.title, trackNo: number,
                        discNo: metadata?.discNumber,
                        durationSec: metadata?.durationSec ?? node.durationSec,
                        codec: metadata?.codec?.uppercased(), sampleRate: metadata?.sampleRate,
                        bitDepthOrBitrate: metadata?.bitRateKbps.map { "\($0) kbps" },
                        sortKey: String(format: "%06d", number), genre: metadata?.genre),
                    asset: Asset(
                        id: nil, trackId: 0, kind: .remote, bookmark: nil, relPath: nil,
                        remoteURL: url, altRemoteURL: nil,
                        sizeBytes: resolved.sizeBytes ?? node.sizeBytes, unsupportedReason: nil,
                        remoteNodeID: node.id, remoteNodePath: node.path,
                        remoteContentType: node.contentType))
                let trackID = outcome.trackID
                if !outcome.created, source.kind != .jamendoGenre {
                    existing[url] = trackID
                    ids.append(trackID)
                    continue
                }
                if source.kind == .jamendoGenre {
                    do {
                        // `node.id`, not the resolved URL, is the durable Jamendo identity.
                        try await catalogUpsert(store, node.id, resolved.url)
                    } catch {
                        // Never report the node as imported without its blend identity.
                        if outcome.created { try? await store.deleteTrack(id: trackID) }
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
