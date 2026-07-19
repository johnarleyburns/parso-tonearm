import Foundation

public enum RemoteTrackRowFactory {
    public static func row(source: Source,
                           node: RemoteNode,
                           resolved: ResolvedAsset,
                           index: Int) -> TrackRow {
        let metadata = mergedMetadata(node: node, resolved: resolved)
        let trackID = -Int64(index + 1)
        let title = clean(metadata?.title) ?? node.title
        let trackNumber = metadata?.trackNumber ?? index + 1
        let bitDepthOrBitrate = metadata?.bitRateKbps.map { "\($0) kbps" }

        let album = albumContext(source: source, metadata: metadata)
        let artist = artistContext(metadata: metadata)
        let track = Track(
            id: trackID,
            albumId: nil,
            sourceId: source.id ?? 0,
            title: title,
            trackNo: trackNumber,
            discNo: metadata?.discNumber,
            durationSec: metadata?.durationSec ?? node.durationSec,
            codec: clean(metadata?.codec)?.uppercased(),
            sampleRate: metadata?.sampleRate,
            bitDepthOrBitrate: bitDepthOrBitrate,
            sortKey: String(format: "%06d", trackNumber),
            genre: clean(metadata?.genre),
            artistId: nil
        )
        var asset = Asset(
            id: nil,
            trackId: trackID,
            kind: resolved.url.isFileURL ? .localRef : .remote,
            bookmark: resolved.url.isFileURL ? BookmarkVault.makeBookmark(for: resolved.url) : nil,
            relPath: nil,
            remoteURL: resolved.url.absoluteString,
            altRemoteURL: nil,
            sizeBytes: resolved.sizeBytes ?? node.sizeBytes,
            unsupportedReason: nil
        )
        asset.transientRemoteHeaders = resolved.headers
        asset.transientRemoteSupportsByteRanges = resolved.supportsByteRanges
        asset.transientArtwork = metadata?.artwork
        return TrackRow(track: track, album: album, source: source, asset: asset, artist: artist)
    }

    private static func mergedMetadata(node: RemoteNode, resolved: ResolvedAsset) -> RemoteTrackMetadata? {
        switch (node.metadata, resolved.metadata) {
        case (.none, .none):
            return nil
        case (.some(let nodeMetadata), .none):
            return nodeMetadata
        case (.none, .some(let resolvedMetadata)):
            return resolvedMetadata
        case (.some(let nodeMetadata), .some(let resolvedMetadata)):
            return nodeMetadata.merged(overriding: resolvedMetadata)
        }
    }

    private static func albumContext(source: Source, metadata: RemoteTrackMetadata?) -> Album? {
        guard let metadata, metadata.hasDisplayContext else { return nil }
        let artist = clean(metadata.artist) ?? clean(metadata.albumArtist)
        let albumArtist = clean(metadata.albumArtist) ?? artist
        return Album(
            id: nil,
            sourceId: source.id ?? 0,
            title: clean(metadata.album) ?? source.title,
            artist: artist,
            albumArtist: albumArtist,
            genre: clean(metadata.genre),
            artworkId: clean(metadata.artwork?.id)
        )
    }

    private static func artistContext(metadata: RemoteTrackMetadata?) -> Artist? {
        guard let name = clean(metadata?.artist) ?? clean(metadata?.albumArtist) else { return nil }
        return Artist(id: nil, name: name, sortName: ArtistNamePolicy.sortName(for: name))
    }

    private static func clean(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
