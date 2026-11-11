#if !os(watchOS)
import Foundation

/// Resolves a catalog-backed Jamendo row for ordinary AVPlayer playback.  It performs only
/// locator work; AVFoundation/cache loading remains in AudioPlayer+Loading.
struct CatalogPlaybackURLResolver: Sendable {
    var lookup: @Sendable (String) async -> BlendCatalogTrack?
    var resolver: JamendoLocatorResolver
    var persist: @Sendable (String, URL, Date?) async -> Void

    static func live() -> Self {
        .init(lookup: { try? await LibraryStore.shared.blendCatalogTrack(key: $0) },
              resolver: .configured(),
              persist: { key, url, expiry in
                  try? await LibraryStore.shared.updateCachedLocator(key: key, url: url, expiry: expiry)
              })
    }

    func resolve(row: TrackRow) async throws -> (catalogKey: String, url: URL)? {
        guard let id = Self.jamendoTrackID(for: row) else { return nil }
        // Browse/search rows deliberately have no persistent Source/Asset/catalog entry. Their
        // provider node ID is still durable for this in-memory queue and must be refreshed.
        if row.source?.kind != .jamendoGenre || row.source?.id == nil {
            let fresh = try await resolver.refreshOnly(.jamendo(trackID: id, cachedURL: nil, expiry: nil))
            return (BlendCatalogTrack.jamendoKey(trackID: id), fresh.url)
        }
        let key = BlendCatalogTrack.jamendoKey(trackID: id)
        guard let catalog = await lookup(key), let locator = catalog.audioLocator(),
              case .jamendo = locator else { throw JamendoResolveError.permanent }
        let fresh = try await resolver.refreshOnly(locator)
        await persist(key, fresh.url, fresh.expiry)
        return (key, fresh.url)
    }

    /// The bundled Mood Starter catalog is deliberately a `.local` source so
    /// it does not impersonate a user-added Jamendo genre library. Its audio
    /// locator is nevertheless a durable `jamendo://track/<numeric-id>`
    /// provider reference, which must be resolved before handing anything to
    /// AVFoundation. A custom `jamendo` scheme is not itself playable.
    static func jamendoTrackID(for row: TrackRow) -> String? {
        let candidate: String?
        if row.source?.kind == .jamendoGenre {
            candidate = row.asset?.remoteNodeID
        } else if let raw = row.asset?.remoteURL,
                  let url = URL(string: raw),
                  url.scheme?.caseInsensitiveCompare("jamendo") == .orderedSame,
                  url.host?.caseInsensitiveCompare("track") == .orderedSame {
            candidate = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        } else {
            candidate = nil
        }
        guard let id = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
              !id.isEmpty, Int64(id) != nil else { return nil }
        return id
    }
}
#endif
