import Foundation

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
        store: LibraryStore
    ) async -> Result {
        guard let sourceID = source.id else { return Result(trackIDs: [], skipped: nodes.count) }
        let existingRows = (try? await store.tracks(forSource: sourceID)) ?? []
        var existing = Dictionary(uniqueKeysWithValues: existingRows.compactMap { row in
            row.asset?.remoteURL.map { ($0, row.id) }
        })
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
                let resolved = try await resolve(node)
                let url = resolved.url.absoluteString
                if let id = existing[url] { ids.append(id); continue }
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
                _ = try await store.insertAsset(Asset(
                    id: nil, trackId: trackID, kind: .remote, bookmark: nil, relPath: nil,
                    remoteURL: url, altRemoteURL: nil,
                    sizeBytes: resolved.sizeBytes ?? node.sizeBytes, unsupportedReason: nil))
                existing[url] = trackID
                ids.append(trackID)
            } catch {
                skipped += 1
            }
        }
        return Result(trackIDs: ids, skipped: skipped)
    }
}
