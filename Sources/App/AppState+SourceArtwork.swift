import Foundation
import ParsoAudioStreaming
import SwiftUI
import TonearmCore

extension AppState {
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
        var image: PlatformImage? = nil
    }

    func resolvedArtwork(for source: Source) async -> ResolvedSourceArtwork {
        let icon = source.fallbackIcon
        guard let id = source.id else {
            return ResolvedSourceArtwork(identifier: nil, trackRow: nil, fallbackIcon: icon)
        }

        // Source-level custom artwork (highest priority for the source tile/hero).
        if let customId = try? await store.sourceCustomArtworkId(for: id),
           !customId.isEmpty,
           let image = await ArtworkStore.shared.image(id: customId) {
            return ResolvedSourceArtwork(identifier: nil, trackRow: nil, fallbackIcon: icon, image: image)
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

}
