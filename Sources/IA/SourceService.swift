import Foundation

struct SourcePreview {
    var kind: SourceKind
    var title: String
    var subtitle: String
    var licenseText: String?
    var licensePermitsStreaming: Bool
    var memberCount: Int?
    var totalCount: Int?
    var capHit: Bool
    var parsed: IAResolvedURL
    var originalURL: String
    var resolvedItem: ResolvedItem?
    var members: [IAMember]
}

/// Orchestrates URLGrammar + resolvers. All IA network calls originate here and
/// in the resolvers under IA/ (Invariant checks reference this boundary).
struct SourceService {
    var preferFLAC: Bool = true

    func preview(from raw: String) async throws -> SourcePreview {
        let parsed = try URLGrammar.parse(raw).get()
        switch parsed {
        case .item(let identifier, _):
            let item = try await ItemResolver(preferFLAC: preferFLAC).resolve(identifier: identifier)
            if item.mediatype == "collection" {
                return try await collectionPreview(identifier: identifier, raw: raw)
            }
            let permits = licensePermits(item.licenseText)
            return SourcePreview(
                kind: .iaItem, title: item.title,
                subtitle: "\(item.tracks.count) tracks · audio",
                licenseText: prettyLicense(item.licenseText),
                licensePermitsStreaming: permits,
                memberCount: item.tracks.count, totalCount: item.tracks.count,
                capHit: false, parsed: parsed, originalURL: raw,
                resolvedItem: item, members: [])

        case .collection(let identifier):
            return try await collectionPreview(identifier: identifier, raw: raw)

        case .favorites(let screenname):
            let (members, total, capHit) = try await CollectionResolver().resolveFavorites(screenname: screenname)
            return SourcePreview(
                kind: .iaFavorites, title: "Favorites of @\(screenname)",
                subtitle: "\(members.count) items · audio",
                licenseText: nil, licensePermitsStreaming: true,
                memberCount: members.count, totalCount: total, capHit: capHit,
                parsed: parsed, originalURL: raw, resolvedItem: nil, members: members)

        case .list(let screenname, let listId):
            let members = try await ListResolver().resolve(screenname: screenname, listId: listId)
            return SourcePreview(
                kind: .iaList, title: "List by @\(screenname)",
                subtitle: "\(members.count) items · audio",
                licenseText: nil, licensePermitsStreaming: true,
                memberCount: members.count, totalCount: members.count, capHit: false,
                parsed: parsed, originalURL: raw, resolvedItem: nil, members: members)
        }
    }

    private func collectionPreview(identifier: String, raw: String) async throws -> SourcePreview {
        let (members, total, capHit) = try await CollectionResolver().resolve(collection: identifier)
        return SourcePreview(
            kind: .iaCollection, title: identifier,
            subtitle: "\(members.count) of \(total) items",
            licenseText: nil, licensePermitsStreaming: true,
            memberCount: members.count, totalCount: total, capHit: capHit,
            parsed: IAResolvedURL.collection(identifier: identifier),
            originalURL: raw, resolvedItem: nil, members: members)
    }

    /// Persists the source and, for items, its tracks. Members resolve lazily elsewhere.
    @discardableResult
    func add(preview: SourcePreview, followUpdates: Bool, store: LibraryStore) async throws -> Source {
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
        var album = Album(id: nil, sourceId: sourceId, title: item.title,
                          artist: item.artist, year: item.year, artworkId: nil)
        album = try await store.insertAlbum(album)
        guard let albumId = album.id else { return }
        for rt in item.tracks {
            var track = Track(id: nil, albumId: albumId, sourceId: sourceId, title: rt.title,
                              trackNo: rt.trackNo, discNo: nil, durationSec: rt.durationSec,
                              codec: rt.codec, sampleRate: rt.sampleRate,
                              bitDepthOrBitrate: rt.bitDepthOrBitrate, sortKey: rt.sortKey)
            track = try await store.insertTrack(track)
            guard let trackId = track.id else { continue }
            let asset = Asset(id: nil, trackId: trackId, kind: .remote, bookmark: nil,
                              relPath: nil, remoteURL: rt.remoteURL.absoluteString,
                              sizeBytes: rt.sizeBytes, unsupportedReason: rt.unsupportedReason)
            try await store.insertAsset(asset)
        }
    }

    private func identifier(for parsed: IAResolvedURL) -> String? {
        switch parsed {
        case .item(let id, _): return id
        case .collection(let id): return id
        case .favorites(let s): return "fav-\(s)"
        case .list(_, let listId): return listId
        }
    }

    private func licensePermits(_ text: String?) -> Bool {
        guard let text = text?.lowercased() else { return true }
        return !text.contains("noderivatives") || true
    }

    private func prettyLicense(_ url: String?) -> String? {
        guard let url = url?.lowercased() else { return nil }
        if url.contains("publicdomain") || url.contains("cc0") { return "CC0 Public Domain" }
        if url.contains("by-sa") { return "CC BY-SA" }
        if url.contains("by-nc") { return "CC BY-NC" }
        if url.contains("by") { return "CC BY" }
        return "See license"
    }
}
