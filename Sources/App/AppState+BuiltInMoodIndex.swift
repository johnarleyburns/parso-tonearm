import Foundation
import GRDB
import TonearmCore
import TonearmDiscovery

extension AppState {
    /// Seeds the bundled Jamendo/archive.org mood-starter tracks
    /// (docs/plans/builtin-mood-starter-index-plan.md expansion): real
    /// track/album/source/asset rows for each `BuiltInMoodTrack`, PLUS a
    /// completed `discovery_embedding` row seeded directly from its bundled
    /// precomputed vector — bypassing on-device CLAP inference entirely for
    /// these tracks. A matching `.complete` `discovery_index_job` row is
    /// seeded too, at the current pipeline version, so
    /// `DiscoveryReconciler.bootstrapAllTracks()` (which only creates a job
    /// for a track that doesn't already have one at the current pipeline
    /// version — see `pageOfTracksNeedingJobs`) never queues live remote
    /// indexing for them. Each track's asset is `.remote` with the real
    /// Jamendo/archive.org stream URL, so playback works normally and
    /// on-device network use only ever happens when the user actually
    /// presses play — never in the background (CLAUDE.md "no silent/magic
    /// background work").
    ///
    /// Idempotent — checks for the "Mood Starter" source first, same
    /// pattern as `seedBuiltInLibraryContentIfNeeded()`.
    func seedBuiltInMoodIndexIfNeeded() async {
        if let existing = try? await store.firstSource(title: Self.moodIndexSourceTitle, kind: .local),
           let sourceId = existing.id {
            await backfillMoodIndexArtworkIfNeeded()
            await backfillNewMoodIndexTracksIfNeeded(sourceId: sourceId)
            return
        }
        let bundled = BuiltInMoodIndexProvider.tracks
        guard !bundled.isEmpty else { return }
        do {
            let source = try await store.insertSource(Source(
                id: nil, kind: .local, iaIdentifier: nil, originalURL: nil,
                title: Self.moodIndexSourceTitle, addedAt: Date(), lastResolvedAt: nil,
                followUpdates: false, licenseText: "Creative Commons — attribution kept",
                memberCapHit: false))
            guard let sourceId = source.id else { return }

            var albumsByGenre: [String: Int64] = [:]
            let now = Date()

            for entry in bundled {
                let albumId: Int64
                if let existing = albumsByGenre[entry.genre] {
                    albumId = existing
                } else {
                    let album = try await store.insertAlbum(Album(
                        id: nil, sourceId: sourceId, title: entry.genre,
                        artist: nil, year: nil, artworkId: nil))
                    guard let newId = album.id else { continue }
                    albumsByGenre[entry.genre] = newId
                    albumId = newId
                }
                let artist = try await store.findOrCreateArtist(
                    name: entry.artist, sortName: entry.artist.lowercased())

                let track = try await store.insertTrack(Track(
                    id: nil, albumId: albumId, sourceId: sourceId,
                    title: entry.title, trackNo: nil, discNo: nil,
                    durationSec: entry.durationSec, codec: "MP3", sampleRate: nil,
                    bitDepthOrBitrate: nil, sortKey: entry.title.lowercased(),
                    genre: entry.genre, composer: nil, artistId: artist.id))
                guard let trackId = track.id else { continue }

                let asset = try await store.insertAsset(Asset(
                    id: nil, trackId: trackId, kind: .remote, bookmark: nil,
                    relPath: nil, remoteURL: entry.streamURL, altRemoteURL: nil,
                    sizeBytes: nil, unsupportedReason: nil,
                    persistedArtworkURL: entry.artworkURL))
                guard let assetId = asset.id else { continue }

                guard let vectorData = Data(base64Encoded: entry.quantizedVectorBase64) else { continue }
                try await store.seedBuiltInEmbedding(
                    trackId: trackId, assetId: assetId,
                    pipelineVersion: DiscoveryPipelineVersion.pipeline,
                    modelVersion: DiscoveryPipelineVersion.model,
                    preprocessingVersion: DiscoveryPipelineVersion.preprocessing,
                    samplingVersion: DiscoveryPipelineVersion.sampling,
                    dimensions: entry.dimensions, quantizedVector: vectorData,
                    scale: entry.scale, completedAt: now)
            }
            await reload()
        } catch {
            print("seedBuiltInMoodIndexIfNeeded error: \(error)")
        }
    }

    private static let moodIndexSourceTitle = "Mood Starter"

    /// One-time backfill for a device that already seeded the mood-starter
    /// index before this bundle carried `artworkURL` — real report: "none
    /// of the Jamendo artwork is loading." Seeding itself is idempotent
    /// (checks the source exists first), so those rows would otherwise stay
    /// stuck at `persistedArtworkURL == nil` forever on an already-seeded
    /// device. Matches each bundled entry to its real asset by the stream
    /// URL (the one value both sides share) rather than by title/artist,
    /// which aren't guaranteed unique. Cheap and safe to run every launch —
    /// a single indexed lookup per bundled entry with an artwork URL, and a
    /// no-op once every row already has one.
    private func backfillMoodIndexArtworkIfNeeded() async {
        let bundled = BuiltInMoodIndexProvider.tracks
        guard !bundled.isEmpty else { return }
        do {
            try await store.dbQueue.write { db in
                for entry in bundled {
                    guard let artworkURL = entry.artworkURL else { continue }
                    try db.execute(
                        sql: """
                            UPDATE asset SET persistedArtworkURL = ?
                            WHERE remoteURL = ? AND persistedArtworkURL IS NULL
                            """,
                        arguments: [artworkURL, entry.streamURL])
                }
            }
        } catch {
            print("backfillMoodIndexArtworkIfNeeded error: \(error)")
        }
    }

    /// One-time backfill for a device that already seeded the mood-starter
    /// index before the bundled taxonomy was rebuilt/expanded (the 155-tag
    /// Jamendo genre taxonomy, shared with the onboarding picker) — without
    /// this, a device that seeded the OLD, smaller bundle would stay stuck
    /// at its original track count forever, since `seedBuiltInMoodIndexIfNeeded`
    /// only runs its full insert path when the "Mood Starter" source doesn't
    /// exist yet at all. Matches by `remoteURL` (same strategy as the
    /// artwork backfill above) so already-present tracks are never
    /// duplicated — only bundled entries with no matching asset get
    /// inserted. Cheap and safe to run every launch: one indexed read per
    /// call, a no-op once every bundled entry already has a row.
    private func backfillNewMoodIndexTracksIfNeeded(sourceId: Int64) async {
        let bundled = BuiltInMoodIndexProvider.tracks
        guard !bundled.isEmpty else { return }
        do {
            let existingRemoteURLs: Set<String> = try await store.dbQueue.read { db in
                let rows = try Row.fetchAll(db, sql: """
                    SELECT asset.remoteURL FROM asset
                    JOIN track ON track.id = asset.trackId
                    WHERE track.sourceId = ? AND asset.remoteURL IS NOT NULL
                    """, arguments: [sourceId])
                return Set(rows.compactMap { $0["remoteURL"] as String? })
            }
            let missing = bundled.filter { !existingRemoteURLs.contains($0.streamURL) }
            guard !missing.isEmpty else { return }

            var albumsByGenre: [String: Int64] = try await store.dbQueue.read { db in
                let rows = try Row.fetchAll(
                    db, sql: "SELECT id, title FROM album WHERE sourceId = ?", arguments: [sourceId])
                var map: [String: Int64] = [:]
                for row in rows {
                    if let title: String = row["title"], let id: Int64 = row["id"] {
                        map[title] = id
                    }
                }
                return map
            }
            let now = Date()

            for entry in missing {
                let albumId: Int64
                if let existing = albumsByGenre[entry.genre] {
                    albumId = existing
                } else {
                    let album = try await store.insertAlbum(Album(
                        id: nil, sourceId: sourceId, title: entry.genre,
                        artist: nil, year: nil, artworkId: nil))
                    guard let newId = album.id else { continue }
                    albumsByGenre[entry.genre] = newId
                    albumId = newId
                }
                let artist = try await store.findOrCreateArtist(
                    name: entry.artist, sortName: entry.artist.lowercased())

                let track = try await store.insertTrack(Track(
                    id: nil, albumId: albumId, sourceId: sourceId,
                    title: entry.title, trackNo: nil, discNo: nil,
                    durationSec: entry.durationSec, codec: "MP3", sampleRate: nil,
                    bitDepthOrBitrate: nil, sortKey: entry.title.lowercased(),
                    genre: entry.genre, composer: nil, artistId: artist.id))
                guard let trackId = track.id else { continue }

                let asset = try await store.insertAsset(Asset(
                    id: nil, trackId: trackId, kind: .remote, bookmark: nil,
                    relPath: nil, remoteURL: entry.streamURL, altRemoteURL: nil,
                    sizeBytes: nil, unsupportedReason: nil,
                    persistedArtworkURL: entry.artworkURL))
                guard let assetId = asset.id else { continue }

                guard let vectorData = Data(base64Encoded: entry.quantizedVectorBase64) else { continue }
                try await store.seedBuiltInEmbedding(
                    trackId: trackId, assetId: assetId,
                    pipelineVersion: DiscoveryPipelineVersion.pipeline,
                    modelVersion: DiscoveryPipelineVersion.model,
                    preprocessingVersion: DiscoveryPipelineVersion.preprocessing,
                    samplingVersion: DiscoveryPipelineVersion.sampling,
                    dimensions: entry.dimensions, quantizedVector: vectorData,
                    scale: entry.scale, completedAt: now)
            }
            await reload()
        } catch {
            print("backfillNewMoodIndexTracksIfNeeded error: \(error)")
        }
    }
}
