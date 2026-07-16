import Foundation

public struct SourcePreview {
    public var kind: SourceKind
    public var title: String
    public var subtitle: String
    public var licenseText: String?
    public var licensePermitsStreaming: Bool
    public var memberCount: Int?
    public var totalCount: Int?
    public var capHit: Bool
    public var parsed: IAResolvedURL
    public var originalURL: String
    public var resolvedItem: ResolvedItem?
    public var members: [IAMember]
}

/// Orchestrates URLGrammar + resolvers. All IA network calls originate here and
/// in the resolvers under IA/ (Invariant checks reference this boundary).
public struct SourceService {
    public var preferFLAC: Bool = true

    public init(preferFLAC: Bool = true) {
        self.preferFLAC = preferFLAC
    }

    public func preview(from raw: String) async throws -> SourcePreview {
        try await IARemoteLibraryProvider(preferFLAC: preferFLAC).preview(from: raw)
    }

    /// Turns a slug/identifier into a human-readable title: dashes→spaces, title-case each word.
    public static func prettify(_ slug: String) -> String {
        slug.replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
            .joined(separator: " ")
    }

    /// Persists the source and, for items, its tracks. Members resolve lazily elsewhere.
    @discardableResult
    public func add(preview: SourcePreview, followUpdates: Bool, store: LibraryStore) async throws -> Source {
        var source = Source(id: nil, kind: preview.kind,
                            iaIdentifier: identifier(for: preview.parsed),
                            originalURL: preview.originalURL, title: preview.title,
                            addedAt: Date(), lastResolvedAt: Date(),
                            followUpdates: followUpdates,
                            licenseText: preview.licenseText,
                            memberCapHit: preview.capHit)
        source = try await store.insertSource(source)
        guard let sourceId = source.id else { return source }

        if let item = preview.resolvedItem {
            try await persistItem(item, sourceId: sourceId, store: store)
        } else {
            // For lists/collections/favorites, resolve each member item lazily but
            // persist a lightweight album placeholder for each so it appears.
            let resolver = ItemResolver(preferFLAC: preferFLAC)
            for member in preview.members.prefix(CollectionResolver.memberCap) {
                if let item = try? await resolver.resolve(identifier: member.identifier) {
                    try await persistItem(item, sourceId: sourceId, store: store)
                }
            }
        }
        return source
    }

    private func persistItem(_ item: ResolvedItem, sourceId: Int64, store: LibraryStore) async throws {
        let artworkId = item.identifier
        let albumArtistName = item.artist
        let albumArtist = try await artist(for: albumArtistName, store: store)
        var album = Album(id: nil, sourceId: sourceId, title: item.title,
                          artist: item.artist, artistId: albumArtist?.id,
                          albumArtist: ArtistNamePolicy.normalize(albumArtistName),
                          genre: item.genre, year: item.year, artworkId: artworkId)
        album = try await store.insertAlbum(album)
        guard let albumId = album.id else { return }
        for rt in item.tracks {
            let trackArtist = try await artist(for: rt.artist ?? item.artist, store: store)
            var track = Track(id: nil, albumId: albumId, sourceId: sourceId, title: rt.title,
                              trackNo: rt.trackNo, discNo: rt.discNo, durationSec: rt.durationSec,
                              codec: rt.codec, sampleRate: rt.sampleRate,
                              bitDepthOrBitrate: rt.bitDepthOrBitrate, sortKey: rt.sortKey,
                              genre: rt.genre ?? item.genre, composer: rt.composer,
                              artistId: trackArtist?.id ?? albumArtist?.id,
                              rgTrackGain: rt.rgTrackGain, rgAlbumGain: rt.rgAlbumGain,
                              rgTrackPeak: rt.rgTrackPeak, rgAlbumPeak: rt.rgAlbumPeak)
            track = try await store.insertTrack(track)
            guard let trackId = track.id else { continue }
            let asset = Asset(id: nil, trackId: trackId, kind: .remote, bookmark: nil,
                              relPath: nil, remoteURL: rt.remoteURL.absoluteString,
                              altRemoteURL: rt.altFlacURL?.absoluteString,
                              opusRemoteURL: rt.opusURL?.absoluteString,
                              sizeBytes: rt.sizeBytes, unsupportedReason: rt.unsupportedReason)
            try await store.insertAsset(asset)
        }
    }

    private func artist(for rawName: String?, store: LibraryStore) async throws -> Artist? {
        guard let rawName, let name = ArtistNamePolicy.normalize(rawName) else { return nil }
        return try await store.findOrCreateArtist(name: name, sortName: ArtistNamePolicy.sortName(for: name))
    }

    private func identifier(for parsed: IAResolvedURL) -> String? {
        switch parsed {
        case .item(let id, _): return id
        case .collection(let id): return id
        case .favorites(let s): return "fav-\(s)"
        case .list(_, let listId, _): return listId
        }
    }

}
