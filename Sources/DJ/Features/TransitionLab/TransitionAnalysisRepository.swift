import Foundation
import GRDB
import ParsoAudioAnalysis
import ParsoDJEngine
import TonearmCore

/// One cached full-song `PortableAnalysisV1` per track (`transition_full_analysis`).
/// Deliberately separate from Discovery's `discovery_track_analysis` (a bounded,
/// up-to-60-second-midpoint window) — this is the whole song, a different
/// schema/algorithm entirely (see
/// docs/plans/UNIFIED_TONEARM_MY_MUSIC_TRANSITION_LAB_HANDOFF.md §15).
struct TransitionFullAnalysisRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "transition_full_analysis"

    var id: Int64?
    var trackId: Int64
    var assetId: Int64
    var assetRevision: Int64
    var schemaVersion: Int
    var algorithmID: String
    var payload: Data
    var completedAt: Date

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// One row per playlist edge (adjacent-track pair) the user has prepared or
/// attempted to prepare a transition for (`transition_playlist_edge`).
public struct TransitionPlaylistEdgeRow: Codable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "transition_playlist_edge"

    public enum Status: String, Codable {
        case prepared
        case needsWork
    }

    public var id: Int64?
    public var playlistId: Int64
    public var outgoingTrackId: Int64
    public var incomingTrackId: Int64
    public var outgoingRevision: Int64
    public var incomingRevision: Int64
    public var proposalPayload: Data?
    public var status: String
    public var updatedAt: Date

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// Persistence for Transition Lab's two tables. Pure data access — no
/// analysis/planning here (that's `TransitionLabModel`).
public struct TransitionAnalysisRepository: Sendable {
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    /// The cached full-song analysis for `trackId`, decoded and validated —
    /// `PortableAnalysisV1.init(from:)` itself rejects a schema/algorithm-ID
    /// mismatch or an out-of-range value, so a decode failure here is
    /// legitimately "stale, re-analyze", not a bug to work around.
    public func cachedAnalysis(trackId: Int64) throws -> PortableAnalysisV1? {
        guard
            let row = try writer.read({ db in
                try TransitionFullAnalysisRow
                    .filter(Column("trackId") == trackId)
                    .fetchOne(db)
            })
        else { return nil }
        return try? JSONDecoder().decode(PortableAnalysisV1.self, from: row.payload)
    }

    /// Upserts the analysis for `trackId` (one row per track — a re-analysis
    /// replaces the prior one outright, there is no history to keep).
    public func saveAnalysis(
        trackId: Int64, assetId: Int64, assetRevision: Int64, analysis: PortableAnalysisV1
    ) throws {
        let payload = try JSONEncoder().encode(analysis)
        try writer.write { db in
            let existingID = try Int64.fetchOne(
                db,
                sql: "SELECT id FROM transition_full_analysis WHERE trackId = ?",
                arguments: [trackId])
            var row = TransitionFullAnalysisRow(
                id: existingID, trackId: trackId, assetId: assetId, assetRevision: assetRevision,
                schemaVersion: analysis.schemaVersion, algorithmID: analysis.algorithmID,
                payload: payload, completedAt: Date())
            try row.save(db)
        }
    }

    /// The prepared/needs-work edge for this exact adjacent pair within
    /// `playlistId`, if one has ever been saved.
    public func edge(playlistId: Int64, outgoingTrackId: Int64, incomingTrackId: Int64) throws
        -> TransitionPlaylistEdgeRow?
    {
        try writer.read { db in
            try TransitionPlaylistEdgeRow
                .filter(Column("playlistId") == playlistId)
                .filter(Column("outgoingTrackId") == outgoingTrackId)
                .filter(Column("incomingTrackId") == incomingTrackId)
                .fetchOne(db)
        }
    }

    /// Persists the user's chosen proposal for this edge as "prepared", or
    /// (`proposal == nil`) records that this pair was attempted but no good
    /// transition was found ("needs work").
    public func saveEdge(
        playlistId: Int64, outgoingTrackId: Int64, incomingTrackId: Int64,
        outgoingRevision: Int64, incomingRevision: Int64, proposal: AudioTransitionProposal?
    ) throws {
        let payload = proposal.flatMap { try? JSONEncoder().encode($0) }
        try writer.write { db in
            let existingID = try Int64.fetchOne(
                db,
                sql: """
                    SELECT id FROM transition_playlist_edge
                    WHERE playlistId = ? AND outgoingTrackId = ? AND incomingTrackId = ?
                    """,
                arguments: [playlistId, outgoingTrackId, incomingTrackId])
            var row = TransitionPlaylistEdgeRow(
                id: existingID, playlistId: playlistId, outgoingTrackId: outgoingTrackId,
                incomingTrackId: incomingTrackId, outgoingRevision: outgoingRevision,
                incomingRevision: incomingRevision, proposalPayload: payload,
                status: payload != nil ? Status.prepared.rawValue : Status.needsWork.rawValue,
                updatedAt: Date())
            try row.save(db)
        }
    }
}

private typealias Status = TransitionPlaylistEdgeRow.Status
