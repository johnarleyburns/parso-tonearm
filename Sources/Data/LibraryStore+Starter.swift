import Foundation
import GRDB

/// Versions stamped on merged starter rows so they read exactly like on-device indexing results.
public struct StarterMergeVersions: Sendable {
    public var pipeline: Int
    public var model: Int
    public var preprocessing: Int
    public var sampling: Int
    public var musicalAnalysis: Int

    public init(pipeline: Int, model: Int, preprocessing: Int, sampling: Int, musicalAnalysis: Int) {
        self.pipeline = pipeline
        self.model = model
        self.preprocessing = preprocessing
        self.sampling = sampling
        self.musicalAnalysis = musicalAnalysis
    }
}

public struct StarterMergeResult: Equatable, Sendable {
    public var sourceID: Int64
    public var tracksAdded: Int
    public var analysesAdded: Int
    public var artworkFilled: Int
}

/// A starter track's upstream catalog identity — the merge key `mergeStarterLibrary` matches
/// existing rows against, never `asset.remoteURL` (mutable, shard-pipeline-reissuable metadata).
struct StarterIdentity: Hashable {
    let provider: String
    let providerTrackID: String
}

extension LibraryStore {
    /// Merges the starter DB's tracks into the library in one transaction: the Mood Starter source,
    /// one album per genre, artists, tracks, remote assets, the CLAP embedding (+ a completed index
    /// job) and tempo/key/energy — the rows on-device indexing would have produced. An existing
    /// track is matched by its stable upstream identity (`starter_identity`, provider +
    /// providerTrackID) — never by URL, which the shard pipeline can reissue for the same track
    /// across content versions; a matched track's URL is refreshed in place rather than treated as
    /// a new track. Only what's missing (analysis, artwork, a changed URL) is written for an
    /// already-present track. It replaces ~4,000 per-row inserts, each its own transaction, after
    /// decoding a 5 MB JSON.
    ///
    /// Throws without writing anything for the first entry whose own
    /// `embeddingSpaceFingerprint`/`dimensions` don't match `expecting` — a starter catalog from a
    /// retired model/projection generation is never partially merged.
    @discardableResult
    public func mergeStarterLibrary(_ tracks: [BuiltInMoodTrack], sourceTitle: String,
                                    licenseText: String, versions: StarterMergeVersions,
                                    expecting contract: StarterEmbeddingContract,
                                    at date: Date = Date()) throws -> StarterMergeResult {
        try dbQueue.write { db in
            let sourceID: Int64
            if let existing = try Source.filter(Column("title") == sourceTitle && Column("kind") == SourceKind.local.rawValue)
                .fetchOne(db), let id = existing.id {
                sourceID = id
            } else {
                var source = Source(id: nil, kind: .local, iaIdentifier: nil, originalURL: nil, title: sourceTitle,
                                    addedAt: date, lastResolvedAt: nil, followUpdates: false,
                                    licenseText: licenseText, memberCapHit: false)
                try source.insert(db)
                sourceID = source.id!
            }

            struct ExistingStarterTrack { let trackID: Int64; let assetID: Int64; let artwork: String? }
            var existing: [StarterIdentity: ExistingStarterTrack] = [:]
            for row in try Row.fetchAll(db, sql: """
                SELECT si.provider AS provider, si.providerTrackID AS providerTrackID,
                       si.trackId AS trackId, si.assetId AS assetId, asset.persistedArtworkURL AS artwork
                FROM starter_identity si JOIN asset ON asset.id = si.assetId
                """) {
                let key = StarterIdentity(provider: row["provider"], providerTrackID: row["providerTrackID"])
                existing[key] = ExistingStarterTrack(trackID: row["trackId"], assetID: row["assetId"],
                                                     artwork: row["artwork"])
            }
            let analysed = Set(try Int64.fetchAll(db, sql: """
                SELECT a.trackId FROM discovery_track_analysis a JOIN track t ON t.id = a.trackId
                WHERE t.sourceId = ?
                """, arguments: [sourceID]))
            var albumByGenre: [String: Int64] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT id, title FROM album WHERE sourceId = ?", arguments: [sourceID]) {
                if let title: String = row["title"], let id: Int64 = row["id"] { albumByGenre[title] = id }
            }
            var artistByName: [String: Int64] = [:]

            var result = StarterMergeResult(sourceID: sourceID, tracksAdded: 0, analysesAdded: 0, artworkFilled: 0)
            for entry in tracks {
                guard entry.embeddingSpaceFingerprint == contract.fingerprint,
                      entry.dimensions == contract.dimensions else {
                    throw StarterLibraryError.embeddingSpaceMismatch(
                        expected: contract.fingerprint, found: entry.embeddingSpaceFingerprint)
                }
                let identity = StarterIdentity(provider: entry.provider, providerTrackID: entry.providerTrackID)
                if let present = existing[identity] {
                    // The shard pipeline can reissue this track's stream URL across content
                    // versions; refresh it in place rather than ever inserting a duplicate.
                    try db.execute(sql: "UPDATE asset SET remoteURL = ? WHERE id = ?",
                                   arguments: [entry.streamURL, present.assetID])
                    if present.artwork == nil, let artwork = entry.artworkURL {
                        try db.execute(sql: "UPDATE asset SET persistedArtworkURL = ? WHERE id = ?",
                                       arguments: [artwork, present.assetID])
                        result.artworkFilled += 1
                    }
                    if !analysed.contains(present.trackID), entry.hasMusicalAnalysis {
                        try Self.writeStarterAnalysis(entry, trackID: present.trackID, assetID: present.assetID,
                                                      versions: versions, date: date, db: db)
                        result.analysesAdded += 1
                    }
                    continue
                }

                let albumID: Int64
                if let id = albumByGenre[entry.genre] {
                    albumID = id
                } else {
                    var album = Album(id: nil, sourceId: sourceID, title: entry.genre, artist: nil, year: nil, artworkId: nil)
                    try album.insert(db)
                    albumID = album.id!
                    albumByGenre[entry.genre] = albumID
                }
                let artistID: Int64
                if let id = artistByName[entry.artist.lowercased()] {
                    artistID = id
                } else if let found = try Artist.fetchOne(db, sql: "SELECT * FROM artist WHERE name = ? COLLATE NOCASE",
                                                          arguments: [entry.artist]), let id = found.id {
                    artistID = id
                    artistByName[entry.artist.lowercased()] = id
                } else {
                    var artist = Artist(id: nil, name: entry.artist, sortName: entry.artist.lowercased(),
                                        syncID: UUID().uuidString)
                    try artist.insert(db)
                    artistID = artist.id!
                    artistByName[entry.artist.lowercased()] = artistID
                }

                var track = Track(id: nil, albumId: albumID, sourceId: sourceID, title: entry.title, trackNo: nil,
                                  discNo: nil, durationSec: entry.durationSec, codec: "MP3", sampleRate: nil,
                                  bitDepthOrBitrate: nil, sortKey: entry.title.lowercased(), genre: entry.genre,
                                  composer: nil, artistId: artistID)
                try track.insert(db)
                let trackID = track.id!
                try TrackIdentityStore.rebuild(trackId: trackID, db: db)
                var asset = Asset(id: nil, trackId: trackID, kind: .remote, bookmark: nil, relPath: nil,
                                  remoteURL: entry.streamURL, altRemoteURL: nil, sizeBytes: nil,
                                  unsupportedReason: nil, persistedArtworkURL: entry.artworkURL)
                try asset.insert(db)
                let assetID = asset.id!
                try refreshSearchIndex(trackID: trackID, db: db)
                try db.execute(sql: """
                    INSERT INTO starter_identity (provider, providerTrackID, trackId, assetId)
                    VALUES (?, ?, ?, ?)
                    """, arguments: [entry.provider, entry.providerTrackID, trackID, assetID])
                // Guards a duplicate identity appearing twice within this same `tracks` batch
                // (e.g. two providers legitimately sharing a numeric providerTrackID, already
                // distinguished by `StarterIdentity` including `provider` — or a genuinely
                // duplicated input row) from inserting a second track for it later in this loop.
                existing[identity] = ExistingStarterTrack(trackID: trackID, assetID: assetID, artwork: entry.artworkURL)

                var embedding = DiscoveryEmbedding(
                    trackId: trackID, assetId: assetID, assetRevision: 1, modelVersion: versions.model,
                    preprocessingVersion: versions.preprocessing, samplingVersion: versions.sampling,
                    dimensions: entry.dimensions, quantizedVector: entry.quantizedVector, scale: entry.scale,
                    completedAt: date)
                try embedding.upsert(db)
                var job = DiscoveryIndexJob(
                    trackId: trackID, selectedAssetId: assetID, assetRevision: 1, pipelineVersion: versions.pipeline,
                    state: .complete, createdAt: date, updatedAt: date, completedWindows: 0, totalWindows: 0,
                    embeddingStageState: .complete,
                    musicalAnalysisStageState: entry.hasMusicalAnalysis ? .complete : .unsupported)
                try job.upsert(db)
                if entry.hasMusicalAnalysis {
                    try Self.writeStarterAnalysis(entry, trackID: trackID, assetID: assetID,
                                                  versions: versions, date: date, db: db)
                }
                result.tracksAdded += 1
            }
            return result
        }
    }

    private static func writeStarterAnalysis(_ entry: BuiltInMoodTrack, trackID: Int64, assetID: Int64,
                                             versions: StarterMergeVersions, date: Date, db: Database) throws {
        var analysis = DiscoveryTrackAnalysis(
            trackId: trackID, assetId: assetID, assetRevision: 1, analysisVersion: versions.musicalAnalysis,
            bpm: entry.bpm, key: entry.key, energy: entry.energy, phraseSummary: nil,
            analysisScopeSeconds: entry.analysisScopeSeconds ?? min(60, entry.durationSec), completedAt: date)
        try analysis.upsert(db)
        try db.execute(sql: "UPDATE discovery_index_job SET musicalAnalysisStageState = ? WHERE trackId = ?",
                       arguments: [DiscoveryStageState.complete.rawValue, trackID])
    }
}
