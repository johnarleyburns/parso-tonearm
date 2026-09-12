import Foundation
import GRDB
import TonearmCore

/// The read model the Track Prep surface renders (§41.8 `PreparationModel ▸
/// GridCorrectionRepository`): the track's identity, the **free** analysis
/// readout (FR-PREP-4 — energy, phrases, loudness, key), the stored correction
/// log, and the authoritative `DeckGrid` a deck would load (§23.3).
public struct TrackPrepSnapshot: Sendable, Equatable {
    public var trackID: Int64
    public var title: String
    public var artistNames: String
    public var codec: String?
    public var durationSec: Double?
    /// The authoritative BPM — the corrected grid's BPM when a grid exists,
    /// else the track's denormalized value.
    public var bpm: Double?
    /// The **detected** grid's BPM — never mutated by corrections (§23.3).
    public var detectedBPM: Double?
    public var camelot: String?
    public var musicalKey: String?
    /// The track's 0…10 energy summary (FR-PREP-4).
    public var energy: Double?
    /// Integrated LUFS (FR-PREP-4 readout, mockup `ipad/06`).
    public var lufs: Double?
    /// EBU dynamic-range / DR value (FR-PREP-4 readout).
    public var dynamicRangeDB: Double?
    /// The detected grid's confidence (0…1).
    public var gridConfidence: Double?
    /// The detected grid's beat-0 sample (mockup's "First downbeat at …").
    public var firstBeatSample: Int64?
    public var phraseCount: Int
    /// The longest phrase, in beats (mockup's "longest 32 bars").
    public var longestPhraseBeats: Int?
    /// The stored correction log, in replay order (§23.3).
    public var corrections: [GridCorrection]
    /// The authoritative grid — detected + corrections replayed — that a deck
    /// loads. `nil` when the track has no detected grid yet: the surface then
    /// reports the honest "not analyzed" state, and correction is meaningless.
    public var grid: DeckGrid?

    public init(trackID: Int64,
                title: String,
                artistNames: String,
                codec: String? = nil,
                durationSec: Double? = nil,
                bpm: Double? = nil,
                detectedBPM: Double? = nil,
                camelot: String? = nil,
                musicalKey: String? = nil,
                energy: Double? = nil,
                lufs: Double? = nil,
                dynamicRangeDB: Double? = nil,
                gridConfidence: Double? = nil,
                firstBeatSample: Int64? = nil,
                phraseCount: Int = 0,
                longestPhraseBeats: Int? = nil,
                corrections: [GridCorrection] = [],
                grid: DeckGrid? = nil) {
        self.trackID = trackID
        self.title = title
        self.artistNames = artistNames
        self.codec = codec
        self.durationSec = durationSec
        self.bpm = bpm
        self.detectedBPM = detectedBPM
        self.camelot = camelot
        self.musicalKey = musicalKey
        self.energy = energy
        self.lufs = lufs
        self.dynamicRangeDB = dynamicRangeDB
        self.gridConfidence = gridConfidence
        self.firstBeatSample = firstBeatSample
        self.phraseCount = phraseCount
        self.longestPhraseBeats = longestPhraseBeats
        self.corrections = corrections
        self.grid = grid
    }

    /// Whether the track has a detected grid — the honest "analysis not ready"
    /// state for the grid tools (FR-PREP-4's readout still shows).
    public var isAnalyzed: Bool { grid != nil }
}

/// The data seam the Track Prep view model talks to (§41.8 View ▸ VM ▸ data).
/// `GridCorrectionRepository` conforms; tests inject a fake so the model's
/// gate, states and forwarding are exercised deterministically (§47.2).
public protocol TrackPrepRepositing: Sendable {
    func snapshot(trackID: Int64) async throws -> TrackPrepSnapshot
    func apply(_ op: GridCorrectionOp, trackID: Int64,
               valueDouble: Double?, valueInt: Int64?) async throws
    func undoLast(trackID: Int64) async throws
}

public enum PrepError: LocalizedError, Sendable {
    case trackNotFound

    public var errorDescription: String? {
        switch self {
        case .trackNotFound: return "This track is no longer in the library"
        }
    }
}

/// The read/write seam over the DJ database for the Track Prep surface
/// (§41.8). Reads go straight through the pool; grid-correction **writes** go
/// through the `DJLibraryStore` actor, the single writer to DJ-local
/// supplementary data (§10.1) — an append is one GRDB transaction and a crash
/// leaves the log either with the whole correction or none (NFR-REL-1).
///
/// `trackID` is always a **core** `LibraryStore` track id (C02): identity
/// (title/artist/codec/duration/sample rate) is read from core `LibraryStore`,
/// not from a DJ-local `DJTrack` row (deleted in dj_v12). Has no production
/// construction site today (confirmed by `rg`, same as `StemService`) — the
/// Track Prep surface is not yet wired into any navigation destination.
public struct GridCorrectionRepository: Sendable {
    public let pool: DatabasePool
    public let store: DJLibraryStore
    public let library: LibraryStore

    public init(pool: DatabasePool, store: DJLibraryStore, library: LibraryStore = .shared) {
        self.pool = pool
        self.store = store
        self.library = library
    }

    // MARK: - TrackPrepRepositing

    /// The prep read model for a track: identity + the free analysis readout +
    /// the stored correction log + the authoritative grid (detected + replay).
    public func snapshot(trackID: Int64) async throws -> TrackPrepSnapshot {
        guard let row = try await library.trackRow(id: trackID) else {
            throw PrepError.trackNotFound
        }
        let corrections = try await store.gridCorrections(trackID: trackID)
        return try await pool.read { db in
            let gridRow = try Row.fetchOne(db, sql: """
                SELECT bpm, firstBeatSample, confidence
                FROM beat_grid WHERE trackID = ?
                """, arguments: [trackID])
            let loudness = try Row.fetchOne(db, sql: """
                SELECT integratedLUFS, dynamicRangeDB
                FROM loudness WHERE trackID = ?
                """, arguments: [trackID])
            let phrase = try Row.fetchOne(db, sql: """
                SELECT COUNT(*) AS count, MAX(lengthBeats) AS maxBeats
                FROM phrase WHERE trackID = ?
                """, arguments: [trackID])
            let key = try Row.fetchOne(db, sql: """
                SELECT camelot, tonic, mode
                FROM key_estimate WHERE trackID = ? AND scope = 'global'
                """, arguments: [trackID])

            let sampleRate = Double(row.track.sampleRate ?? 48_000)
            var detectedBPM: Double?
            var firstBeat: Int64?
            var confidence: Double?
            if let gridRow {
                detectedBPM = gridRow["bpm"] as? Double
                firstBeat = gridRow["firstBeatSample"] as? Int64
                confidence = gridRow["confidence"] as? Double
            }
            let base: DeckGrid?
            if let detectedBPM {
                base = DeckGrid(referenceSample: Double(firstBeat ?? 0),
                                bpm: detectedBPM,
                                beatsPerBar: 4,
                                sampleRate: sampleRate)
            } else {
                base = nil
            }
            let grid = GridReplay.authoritativeGridIfAnalyzed(base: base,
                                                              corrections: corrections)

            let lufs = loudness?["integratedLUFS"] as? Double
            let dynamicRange = loudness?["dynamicRangeDB"] as? Double
            let phraseCount = (phrase?["count"] as? Int64).map { Int($0) } ?? 0
            let longestPhrase = (phrase?["maxBeats"] as? Int64).map { Int($0) }
            let camelot = key?["camelot"] as? String
            let musicalKey: String? = {
                guard let tonic = key?["tonic"] as? Int64, let mode = key?["mode"] as? String else { return nil }
                return "\(tonic) \(mode)"
            }()

            return TrackPrepSnapshot(
                trackID: trackID,
                title: row.track.title,
                artistNames: row.artist?.name ?? row.album?.artist ?? "",
                codec: row.track.codec,
                durationSec: row.track.durationSec,
                bpm: grid?.bpm,
                detectedBPM: detectedBPM,
                camelot: camelot,
                musicalKey: musicalKey,
                energy: nil,
                lufs: lufs,
                dynamicRangeDB: dynamicRange,
                gridConfidence: confidence,
                firstBeatSample: firstBeat,
                phraseCount: phraseCount,
                longestPhraseBeats: longestPhrase,
                corrections: corrections,
                grid: grid)
        }
    }

    /// Append one correction to the authoritative override log (FR-ANL-5).
    public func apply(_ op: GridCorrectionOp, trackID: Int64,
                      valueDouble: Double?, valueInt: Int64?) async throws {
        try await store.appendGridCorrection(trackID: trackID, op: op,
                                             valueDouble: valueDouble,
                                             valueInt: valueInt)
    }

    /// Pop the newest correction — the prep surface's undo (FR-PREP-5).
    public func undoLast(trackID: Int64) async throws {
        try await store.undoLastGridCorrection(trackID: trackID)
    }
}
