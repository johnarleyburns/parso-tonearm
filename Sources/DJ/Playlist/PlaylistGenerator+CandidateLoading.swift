import Foundation
import GRDB
import TonearmCore

/// Candidate loading (core catalog): the retrieved id set's raw attributes,
/// batch-loaded from `track`/`asset`/`discovery_track_analysis`/
/// `discovery_embedding` — the SAME core tables `VibeSearchModel`/
/// `SmartCrateRepository` read. Split out of `PlaylistGenerator.swift`;
/// `loadCandidates`/`loadSeedFeatures` are called from
/// `PlaylistGenerator+Resolution.swift`, so they stay `internal` (not
/// `private`) — `CoreTrackData`/`loadCoreTrackData` are used only within
/// this file and stay `private`.
extension PlaylistGenerator {
    private struct CoreTrackData {
        var durationSec: Double
        var artistId: Int64?
        var albumId: Int64?
        var genre: String?
        var bpm: Double?
        var camelot: String?
        var energy: Double?
        var embedding: [Float]?
        var isFullyCached = false
    }

    private func loadCoreTrackData(for ids: [Int64]) async throws -> [Int64: CoreTrackData] {
        guard !ids.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        return try await library.dbQueue.read { db -> [Int64: CoreTrackData] in
            var result: [Int64: CoreTrackData] = [:]
            let rows = try Row.fetchAll(db, sql: """
                SELECT t.id AS id, t.durationSec AS durationSec, t.artistId AS artistId,
                       t.albumId AS albumId, t.genre AS genre,
                       a.bpm AS bpm, a.key AS camelot, a.energy AS energy
                FROM track t LEFT JOIN discovery_track_analysis a ON a.trackId = t.id
                WHERE t.id IN (\(placeholders))
                """, arguments: StatementArguments(ids))
            for row in rows {
                let id: Int64 = row["id"]
                result[id] = CoreTrackData(durationSec: row["durationSec"] ?? 0,
                                           artistId: row["artistId"],
                                           albumId: row["albumId"],
                                           genre: row["genre"],
                                           bpm: row["bpm"],
                                           camelot: row["camelot"],
                                           energy: row["energy"],
                                           embedding: nil)
            }
            let embeddingRows = try Row.fetchAll(db, sql: """
                SELECT trackId, quantizedVector, scale FROM discovery_embedding
                WHERE trackId IN (\(placeholders))
                """, arguments: StatementArguments(ids))
            for row in embeddingRows {
                let id: Int64 = row["trackId"]
                let data: Data = row["quantizedVector"]
                let scale: Double = row["scale"]
                let int8 = data.map { Int8(bitPattern: $0) }
                result[id]?.embedding = VectorQuantization.dequantize(int8, scale: Float(scale))
            }
            let cachedRows = try Row.fetchAll(db, sql: """
                SELECT DISTINCT trackId FROM asset WHERE trackId IN (\(placeholders))
                """, arguments: StatementArguments(ids))
            for row in cachedRows {
                let id: Int64 = row["trackId"]
                result[id]?.isFullyCached = true
            }
            return result
        }
    }

    /// The retrieved pool's candidate features, with the two constraints the
    /// unified engine doesn't natively cover (genre exclusion, cache
    /// requirement — DJ-preparation-specific, not part of the shared
    /// scope/BPM/key contract) applied as a post-filter, same as before.
    func loadCandidates(ids: [Int64], constraints: SequencingConstraints) async throws
        -> [TrackFeatures] {
        guard !ids.isEmpty else { return [] }
        let data = try await loadCoreTrackData(for: ids)
        var out: [TrackFeatures] = []
        out.reserveCapacity(ids.count)
        for id in ids {
            guard let info = data[id] else { continue }
            if constraints.requireCached && !info.isFullyCached { continue }
            if !constraints.excludeGenres.isEmpty, let genre = info.genre,
               constraints.excludeGenres.contains(genre) {
                continue
            }
            out.append(TrackFeatures(trackID: id,
                                     durationSec: info.durationSec,
                                     bpm: info.bpm,
                                     camelot: info.camelot.flatMap(CamelotKey.init(code:)),
                                     energy: info.energy,
                                     embedding: info.embedding,
                                     artistIDs: info.artistId.map { [$0] } ?? [],
                                     albumID: info.albumId,
                                     isExplicit: false,
                                     isFullyCached: info.isFullyCached))
        }
        return out
    }

    /// The audio-seed track's own features — always included regardless of
    /// constraints (it is forced into the locked slot 0, mirroring the old
    /// pipeline's unconditional append).
    func loadSeedFeatures(_ trackID: Int64) async throws -> TrackFeatures? {
        let data = try await loadCoreTrackData(for: [trackID])
        guard let info = data[trackID] else { return nil }
        return TrackFeatures(trackID: trackID,
                             durationSec: info.durationSec,
                             bpm: info.bpm,
                             camelot: info.camelot.flatMap(CamelotKey.init(code:)),
                             energy: info.energy,
                             embedding: info.embedding,
                             artistIDs: info.artistId.map { [$0] } ?? [],
                             albumID: info.albumId,
                             isExplicit: false,
                             isFullyCached: info.isFullyCached)
    }
}
